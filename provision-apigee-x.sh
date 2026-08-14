#!/usr/bin/env bash
#
# provision-apigee-x.sh
# ---------------------------------------------------------------------------
# Provision Apigee X (org + instance + environment + environment group) on
# Google Cloud using **service account impersonation** — no SA key files.
#
#   • Networking: non-VPC-peering ("modern") by default; classic VPC peering
#     is also supported via the NETWORKING variable.
#   • Org type:   eval or paid, selected with ORG_TYPE.
#   • Exposure:   NOT configured. This script stops after the runtime is up.
#                 Wire up your (external/internal) load balancer afterwards.
#
# EDIT THE "USER CONFIG" BLOCK BELOW, then:  bash provision-apigee-x.sh
#
# ---------------------------------------------------------------------------
# Prerequisites
#   - gcloud, curl, jq installed and on PATH.
#   - You (the caller running gcloud) are authenticated:  gcloud auth login
#   - You hold  roles/iam.serviceAccountTokenCreator  on SA_EMAIL so you can
#     impersonate it.
#   - SA_EMAIL (the impersonated service account) holds, at minimum:
#         roles/apigee.admin
#         roles/serviceusage.serviceUsageAdmin   (to enable APIs)
#         roles/cloudkms.admin                   (if PROVISION_KMS=true)
#         roles/compute.networkAdmin             (only if NETWORKING=peering)
#     …on PROJECT_ID.
#   - For ORG_TYPE=paid the project must be linked to an active billing account.
# ---------------------------------------------------------------------------

# This script uses bash features (arrays, [[ ]], ${...}). If it was launched
# with sh/dash/zsh (e.g. `sh provision-apigee-x.sh`), re-exec it under bash.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
# Guard against ancient/odd bash; 3.2 (macOS default) and up are fine.
if [ "${BASH_VERSINFO:-0}" -lt 3 ]; then
  echo "This script needs bash 3.2+ (found: ${BASH_VERSION:-unknown})." >&2
  exit 1
fi

set -euo pipefail

# ===========================================================================
# ============================  USER CONFIG  ================================
# ===========================================================================
# Every value below may also be overridden by an environment variable of the
# same name (e.g.  PROJECT_ID=my-proj bash provision-apigee-x.sh).

# --- Required -------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:-}"                       # GCP project id (== Apigee org id)
SA_EMAIL="${SA_EMAIL:-}"                            # service account to IMPERSONATE

# --- Org type -------------------------------------------------------------
ORG_TYPE="${ORG_TYPE:-eval}"                        # eval | paid
PAID_BILLING_TYPE="${PAID_BILLING_TYPE:-PAYG}"      # PAYG | SUBSCRIPTION  (only when ORG_TYPE=paid)

# --- Regions --------------------------------------------------------------
ANALYTICS_REGION="${ANALYTICS_REGION:-us-west1}"    # Apigee analytics region
RUNTIME_LOCATION="${RUNTIME_LOCATION:-us-west1}"    # runtime instance region

# --- Names ----------------------------------------------------------------
INSTANCE_NAME="${INSTANCE_NAME:-instance-1}"
ENV_NAME="${ENV_NAME:-eval-env}"
ENVGROUP_NAME="${ENVGROUP_NAME:-eval-group}"
ENVGROUP_HOSTNAME="${ENVGROUP_HOSTNAME:-api.example.com}"

# --- Networking -----------------------------------------------------------
NETWORKING="${NETWORKING:-nopeering}"               # nopeering | peering
AUTHORIZED_NETWORK="${AUTHORIZED_NETWORK:-default}" # (peering only) VPC network name
PEERING_RANGE_NAME="${PEERING_RANGE_NAME:-apigee-range}" # (peering only) reserved range name

# --- Encryption (runtime database key) ------------------------------------
# Required for paid orgs; optional for eval. Set PROVISION_KMS=true to have the
# script create the key ring/key and grant the Apigee service agent access.
PROVISION_KMS="${PROVISION_KMS:-true}"              # true | false
KMS_LOCATION="${KMS_LOCATION:-us-west1}"            # region for the key ring (or "global")
KMS_KEYRING="${KMS_KEYRING:-apigee-keyring}"
KMS_KEY="${KMS_KEY:-apigee-db-key}"
DISK_KMS_KEY="${DISK_KMS_KEY:-}"                    # optional full CMEK path for instance disk; blank = Google-managed

# --- Behavior -------------------------------------------------------------
POLL_INTERVAL="${POLL_INTERVAL:-15}"               # seconds between long-running-op polls
AUTO_APPROVE="${AUTO_APPROVE:-false}"              # true = don't prompt before provisioning
DRY_RUN="${DRY_RUN:-false}"                        # true = print planned calls, change nothing

# ===========================================================================
# =====================  END USER CONFIG (edit above)  ======================
# ===========================================================================


# ---------------------------- internals ------------------------------------
readonly APIGEE_API="https://apigee.googleapis.com/v1"
API_OUT="$(mktemp)"; readonly API_OUT
HTTP_CODE=""
trap 'rm -f "$API_OUT"' EXIT

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[36m'; c_off=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$c_grn" "$c_off" "$*"; }
info() { printf '%s[i]%s %s\n' "$c_blu" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Case helpers (bash 3.2 on macOS lacks ${var,,} / ${var^^}).
lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
uc() { printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]'; }

is_true() { case "$(lc "${1:-}")" in true|1|yes|y) return 0 ;; *) return 1 ;; esac; }

confirm() {
  is_true "$AUTO_APPROVE" && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  case "$(lc "$reply")" in y|yes) return 0 ;; *) return 1 ;; esac
}

# Fresh, short-lived impersonated token for every REST call (survives long ops).
get_token() {
  gcloud auth print-access-token --impersonate-service-account="$SA_EMAIL" 2>/dev/null \
    || die "Could not mint an access token by impersonating ${SA_EMAIL}. Check that:
    1. 'gcloud auth login' has been completed (an active account exists);
    2. your active account has roles/iam.serviceAccountTokenCreator on ${SA_EMAIL};
    3. the IAM Service Account Credentials API is enabled:
         gcloud services enable iamcredentials.googleapis.com --project=${PROJECT_ID}"
}

# api METHOD URL [BODY] -> writes response body to $API_OUT, sets $HTTP_CODE.
api() {
  local method="$1" url="$2" body="${3:-}" token
  token="$(get_token)"
  local args=(-sS -o "$API_OUT" -w '%{http_code}' -X "$method" "$url"
              -H "Authorization: Bearer ${token}")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
  HTTP_CODE="$(curl "${args[@]}")"
}

resource_exists() { api GET "$1"; [[ "$HTTP_CODE" == "200" ]]; }

api_ok() { [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; }

show_response_error() { jq . "$API_OUT" 2>/dev/null >&2 || cat "$API_OUT" >&2; }

# Poll an Apigee long-running operation until done.  wait_for_op OP_NAME DESC
wait_for_op() {
  local op_name="$1" desc="$2"
  [[ -z "$op_name" || "$op_name" == "null" ]] && { warn "No operation name returned for '${desc}'; skipping wait."; return 0; }
  info "Waiting for: ${desc}"
  info "  operation: ${op_name}"
  while true; do
    api GET "${APIGEE_API}/${op_name}"
    if [[ "$HTTP_CODE" == "200" ]]; then
      if [[ "$(jq -r '.done // false' "$API_OUT")" == "true" ]]; then
        if jq -e 'has("error")' "$API_OUT" >/dev/null 2>&1; then
          err "Operation FAILED: ${desc}"; jq '.error' "$API_OUT" >&2; exit 1
        fi
        printf '\n'; log "Done: ${desc}"; return 0
      fi
    else
      warn "poll HTTP ${HTTP_CODE} (will retry)"
    fi
    printf '.'; sleep "$POLL_INTERVAL"
  done
}

gc() { # gcloud wrapper honoring DRY_RUN
  if is_true "$DRY_RUN"; then info "[dry-run] gcloud $*"; return 0; fi
  gcloud "$@"
}

# --------------------------- derived values --------------------------------
ORG_TYPE="$(lc "$ORG_TYPE")"
NETWORKING="$(lc "$NETWORKING")"

case "$ORG_TYPE" in
  eval) BILLING_TYPE="EVALUATION" ;;
  paid) BILLING_TYPE="$(uc "$PAID_BILLING_TYPE")" ;;
  *)    die "ORG_TYPE must be 'eval' or 'paid' (got: ${ORG_TYPE})" ;;
esac

case "$NETWORKING" in
  nopeering|peering) : ;;
  *) die "NETWORKING must be 'nopeering' or 'peering' (got: ${NETWORKING})" ;;
esac

ORG="$PROJECT_ID"
DB_KEY_NAME=""   # set later if PROVISION_KMS

# ------------------------------ preflight ----------------------------------
preflight() {
  for c in gcloud curl jq; do command -v "$c" >/dev/null 2>&1 || die "Missing dependency: $c"; done
  [[ -n "$PROJECT_ID" ]] || die "PROJECT_ID is empty — set it in the USER CONFIG block."
  [[ -n "$SA_EMAIL"   ]] || die "SA_EMAIL is empty — set it in the USER CONFIG block."
  if [[ "$ORG_TYPE" == "paid" ]]; then
    is_true "$PROVISION_KMS" || warn "Paid orgs require a runtime DB encryption key; PROVISION_KMS is false."
  fi

  # The impersonated token is minted FROM the active caller's credentials.
  local caller
  caller="$(gcloud config get-value account 2>/dev/null || true)"
  [[ -n "$caller" && "$caller" != "(unset)" ]] || die "No active gcloud account. Run: gcloud auth login"
  info "Active caller: ${caller}"

  # Impersonation goes through the IAM Service Account Credentials API, which
  # must be enabled on the project. Enable it as the caller (best-effort).
  if ! service_enabled iamcredentials.googleapis.com ""; then
    info "Enabling iamcredentials.googleapis.com (required for impersonation)..."
    is_true "$DRY_RUN" || gcloud services enable iamcredentials.googleapis.com --project="$PROJECT_ID" 2>/dev/null \
      || warn "Could not enable iamcredentials.googleapis.com as ${caller}; if impersonation fails, enable it manually."
  fi

  # Impersonation must actually work before we start creating things.
  log "Verifying impersonation of ${SA_EMAIL} ..."
  get_token >/dev/null
  log "Impersonation OK."

  # Project number: try the caller first, then the impersonated SA (a minimal
  # SA with only apigee.admin cannot read the project — don't require it to).
  PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)"
  if [[ -z "$PROJECT_NUMBER" ]]; then
    PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" \
        --impersonate-service-account="$SA_EMAIL" --format='value(projectNumber)' 2>/dev/null || true)"
  fi
  [[ -n "$PROJECT_NUMBER" ]] || die "Could not read the project number for '${PROJECT_ID}'.
    Grant roles/resourcemanager.projects.get (e.g. roles/viewer) to ${caller} or ${SA_EMAIL},
    or confirm the project id is correct and billing/permissions are set."
  APIGEE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"
}

print_plan() {
  cat <<PLAN

${c_blu}==================== Apigee X provisioning plan ====================${c_off}
  Project            : ${PROJECT_ID}  (#${PROJECT_NUMBER})
  Impersonating SA   : ${SA_EMAIL}
  Org type / billing : ${ORG_TYPE}  ->  ${BILLING_TYPE}
  Analytics region   : ${ANALYTICS_REGION}
  Runtime location   : ${RUNTIME_LOCATION}
  Instance           : ${INSTANCE_NAME}
  Environment        : ${ENV_NAME}
  Env group          : ${ENVGROUP_NAME}  (host: ${ENVGROUP_HOSTNAME})
  Networking         : ${NETWORKING}$( [[ "$NETWORKING" == peering ]] && printf '  (network=%s, range=%s)' "$AUTHORIZED_NETWORK" "$PEERING_RANGE_NAME" )
  Provision KMS key  : ${PROVISION_KMS}$( is_true "$PROVISION_KMS" && printf '  (%s/%s/%s @ %s)' "$KMS_KEYRING" "$KMS_KEY" "" "$KMS_LOCATION" )
  Dry run            : ${DRY_RUN}
${c_blu}====================================================================${c_off}

  NOTE: no load balancer / external exposure is configured by this script.
PLAN
}

# service_enabled API [SA_EMAIL]  -> 0 if API already enabled.
# Pass an SA email as $2 to check via impersonation; omit to check as the caller.
service_enabled() {
  local api="$1" as="${2:-}"
  if [[ -n "$as" ]]; then
    gcloud services list --enabled --project="$PROJECT_ID" --impersonate-service-account="$as" \
      --format='value(config.name)' 2>/dev/null | grep -Fxq "$api"
  else
    gcloud services list --enabled --project="$PROJECT_ID" \
      --format='value(config.name)' 2>/dev/null | grep -Fxq "$api"
  fi
}

enable_apis() {
  local apis=(apigee.googleapis.com serviceusage.googleapis.com compute.googleapis.com iamcredentials.googleapis.com)
  is_true "$PROVISION_KMS" && apis+=(cloudkms.googleapis.com)
  [[ "$NETWORKING" == peering ]] && apis+=(servicenetworking.googleapis.com)

  # Fetch already-enabled APIs once. If the SA can't list them we get an empty
  # string and fall back to attempting enable (tolerating "already enabled").
  local enabled
  enabled="$(gcloud services list --enabled --project="$PROJECT_ID" \
      --impersonate-service-account="$SA_EMAIL" --format='value(config.name)' 2>/dev/null || true)"

  local missing=() a
  for a in "${apis[@]}"; do
    if printf '%s\n' "$enabled" | grep -Fxq "$a"; then
      info "API already enabled: $a"
    else
      missing+=("$a")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "All required APIs already enabled — nothing to enable."
    return 0
  fi

  log "Enabling APIs: ${missing[*]}"
  is_true "$DRY_RUN" && { info "[dry-run] gcloud services enable ${missing[*]}"; return 0; }

  # Non-fatal: already-enabled APIs (or an admin enabling them out-of-band)
  # must not abort the whole run.
  if ! gcloud services enable "${missing[@]}" --project="$PROJECT_ID" \
        --impersonate-service-account="$SA_EMAIL"; then
    warn "Could not enable one or more APIs: ${missing[*]}"
    warn "  - If they are in fact already enabled, this is safe to ignore."
    warn "  - Otherwise grant roles/serviceusage.serviceUsageAdmin to ${SA_EMAIL}, or run:"
    warn "      gcloud services enable ${missing[*]} --project=${PROJECT_ID}"
  fi
}

ensure_service_agent() {
  log "Ensuring the Apigee service agent exists (${APIGEE_AGENT})"
  gc beta services identity create --service=apigee.googleapis.com --quiet \
     --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL" || true
}

setup_kms() {
  is_true "$PROVISION_KMS" || { info "PROVISION_KMS=false — skipping KMS setup."; return 0; }
  log "Setting up Cloud KMS runtime database encryption key"
  if ! gcloud kms keyrings describe "$KMS_KEYRING" --location="$KMS_LOCATION" \
        --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL" >/dev/null 2>&1; then
    gc kms keyrings create "$KMS_KEYRING" --location="$KMS_LOCATION" \
       --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL"
  else info "  key ring ${KMS_KEYRING} already exists"; fi

  if ! gcloud kms keys describe "$KMS_KEY" --keyring="$KMS_KEYRING" --location="$KMS_LOCATION" \
        --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL" >/dev/null 2>&1; then
    gc kms keys create "$KMS_KEY" --keyring="$KMS_KEYRING" --location="$KMS_LOCATION" \
       --purpose=encryption --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL"
  else info "  key ${KMS_KEY} already exists"; fi

  log "Granting the Apigee service agent encrypt/decrypt on the key"
  gc kms keys add-iam-policy-binding "$KMS_KEY" --keyring="$KMS_KEYRING" --location="$KMS_LOCATION" \
     --member="serviceAccount:${APIGEE_AGENT}" \
     --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
     --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL"

  DB_KEY_NAME="projects/${PROJECT_ID}/locations/${KMS_LOCATION}/keyRings/${KMS_KEYRING}/cryptoKeys/${KMS_KEY}"
}

setup_peering() {
  [[ "$NETWORKING" == peering ]] || return 0
  log "Configuring VPC peering (network=${AUTHORIZED_NETWORK}, range=${PEERING_RANGE_NAME})"
  if ! gcloud compute addresses describe "$PEERING_RANGE_NAME" --global \
        --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL" >/dev/null 2>&1; then
    gc compute addresses create "$PEERING_RANGE_NAME" --global --prefix-length=22 \
       --description="Apigee runtime peering range" --network="$AUTHORIZED_NETWORK" \
       --purpose=VPC_PEERING --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL"
  else info "  reserved range ${PEERING_RANGE_NAME} already exists"; fi
  gc services vpc-peerings connect --service=servicenetworking.googleapis.com \
     --network="$AUTHORIZED_NETWORK" --ranges="$PEERING_RANGE_NAME" \
     --project="$PROJECT_ID" --impersonate-service-account="$SA_EMAIL"
}

create_org() {
  if resource_exists "${APIGEE_API}/organizations/${ORG}"; then
    info "Organization ${ORG} already exists — skipping create."
    return 0
  fi
  local body
  if [[ "$NETWORKING" == nopeering ]]; then
    body="$(jq -n --arg name "$ORG" --arg region "$ANALYTICS_REGION" --arg billing "$BILLING_TYPE" --arg key "$DB_KEY_NAME" \
      '{name:$name, displayName:$name, analyticsRegion:$region, runtimeType:"CLOUD", billingType:$billing, disableVpcPeering:true}
       + (if $key=="" then {} else {runtimeDatabaseEncryptionKeyName:$key} end)')"
  else
    body="$(jq -n --arg name "$ORG" --arg region "$ANALYTICS_REGION" --arg billing "$BILLING_TYPE" --arg net "$AUTHORIZED_NETWORK" --arg key "$DB_KEY_NAME" \
      '{name:$name, displayName:$name, analyticsRegion:$region, runtimeType:"CLOUD", billingType:$billing, authorizedNetwork:$net}
       + (if $key=="" then {} else {runtimeDatabaseEncryptionKeyName:$key} end)')"
  fi
  log "Creating Apigee organization ${ORG}"
  if is_true "$DRY_RUN"; then info "[dry-run] POST /organizations  body:"; echo "$body" | jq .; return 0; fi
  api POST "${APIGEE_API}/organizations?parent=projects/${PROJECT_ID}" "$body"
  api_ok || { err "Org create failed (HTTP ${HTTP_CODE})"; show_response_error; exit 1; }
  wait_for_op "$(jq -r '.name' "$API_OUT")" "organization ${ORG} creation"
}

create_instance() {
  if resource_exists "${APIGEE_API}/organizations/${ORG}/instances/${INSTANCE_NAME}"; then
    info "Instance ${INSTANCE_NAME} already exists — skipping create."
    return 0
  fi
  local body
  body="$(jq -n --arg name "$INSTANCE_NAME" --arg loc "$RUNTIME_LOCATION" --arg dk "$DISK_KMS_KEY" \
    '{name:$name, location:$loc} + (if $dk=="" then {} else {diskEncryptionKeyName:$dk} end)')"
  log "Creating runtime instance ${INSTANCE_NAME} in ${RUNTIME_LOCATION} (this can take 20-45 min)"
  if is_true "$DRY_RUN"; then info "[dry-run] POST /instances  body:"; echo "$body" | jq .; return 0; fi
  api POST "${APIGEE_API}/organizations/${ORG}/instances" "$body"
  api_ok || { err "Instance create failed (HTTP ${HTTP_CODE})"; show_response_error; exit 1; }
  wait_for_op "$(jq -r '.name' "$API_OUT")" "instance ${INSTANCE_NAME} creation"
}

create_environment() {
  if resource_exists "${APIGEE_API}/organizations/${ORG}/environments/${ENV_NAME}"; then
    info "Environment ${ENV_NAME} already exists — skipping create."
  else
    log "Creating environment ${ENV_NAME}"
    if is_true "$DRY_RUN"; then info "[dry-run] POST /environments {name:${ENV_NAME}}";
    else
      api POST "${APIGEE_API}/organizations/${ORG}/environments" "$(jq -n --arg n "$ENV_NAME" '{name:$n}')"
      api_ok || { err "Environment create failed (HTTP ${HTTP_CODE})"; show_response_error; exit 1; }
      wait_for_op "$(jq -r '.name' "$API_OUT")" "environment ${ENV_NAME} creation"
    fi
  fi
}

attach_env_to_instance() {
  if api GET "${APIGEE_API}/organizations/${ORG}/instances/${INSTANCE_NAME}/attachments" \
     && jq -e --arg e "$ENV_NAME" '.attachments[]? | select(.environment==$e)' "$API_OUT" >/dev/null 2>&1; then
    info "Environment ${ENV_NAME} already attached to instance — skipping."
    return 0
  fi
  log "Attaching environment ${ENV_NAME} to instance ${INSTANCE_NAME}"
  if is_true "$DRY_RUN"; then info "[dry-run] POST instance attachment {environment:${ENV_NAME}}"; return 0; fi
  api POST "${APIGEE_API}/organizations/${ORG}/instances/${INSTANCE_NAME}/attachments" \
      "$(jq -n --arg e "$ENV_NAME" '{environment:$e}')"
  api_ok || { err "Instance attachment failed (HTTP ${HTTP_CODE})"; show_response_error; exit 1; }
  wait_for_op "$(jq -r '.name' "$API_OUT")" "attach ${ENV_NAME} to ${INSTANCE_NAME}"
}

create_envgroup() {
  if resource_exists "${APIGEE_API}/organizations/${ORG}/envgroups/${ENVGROUP_NAME}"; then
    info "Env group ${ENVGROUP_NAME} already exists — skipping create."
  else
    log "Creating environment group ${ENVGROUP_NAME} (host: ${ENVGROUP_HOSTNAME})"
    if is_true "$DRY_RUN"; then info "[dry-run] POST /envgroups {name:${ENVGROUP_NAME}, hostnames:[${ENVGROUP_HOSTNAME}]}";
    else
      api POST "${APIGEE_API}/organizations/${ORG}/envgroups" \
          "$(jq -n --arg n "$ENVGROUP_NAME" --arg h "$ENVGROUP_HOSTNAME" '{name:$n, hostnames:[$h]}')"
      api_ok || { err "Env group create failed (HTTP ${HTTP_CODE})"; show_response_error; exit 1; }
      wait_for_op "$(jq -r '.name' "$API_OUT")" "env group ${ENVGROUP_NAME} creation"
    fi
  fi
}

attach_env_to_group() {
  if api GET "${APIGEE_API}/organizations/${ORG}/envgroups/${ENVGROUP_NAME}/attachments" \
     && jq -e --arg e "$ENV_NAME" '.environmentGroupAttachments[]? | select(.environment==$e)' "$API_OUT" >/dev/null 2>&1; then
    info "Environment ${ENV_NAME} already attached to env group — skipping."
    return 0
  fi
  log "Attaching environment ${ENV_NAME} to env group ${ENVGROUP_NAME}"
  if is_true "$DRY_RUN"; then info "[dry-run] POST envgroup attachment {environment:${ENV_NAME}}"; return 0; fi
  api POST "${APIGEE_API}/organizations/${ORG}/envgroups/${ENVGROUP_NAME}/attachments" \
      "$(jq -n --arg e "$ENV_NAME" '{environment:$e}')"
  api_ok || { err "Env group attachment failed (HTTP ${HTTP_CODE})"; show_response_error; exit 1; }
  wait_for_op "$(jq -r '.name' "$API_OUT")" "attach ${ENV_NAME} to ${ENVGROUP_NAME}"
}

summary() {
  is_true "$DRY_RUN" && { info "Dry run complete — nothing was changed."; return 0; }
  local host="(pending)" sa="(n/a)"
  if api GET "${APIGEE_API}/organizations/${ORG}/instances/${INSTANCE_NAME}"; [[ "$HTTP_CODE" == "200" ]]; then
    host="$(jq -r '.host // "(pending)"' "$API_OUT")"
    sa="$(jq -r '.serviceAttachment // "(n/a)"' "$API_OUT")"
  fi
  cat <<DONE

${c_grn}==================== Provisioning complete ====================${c_off}
  Organization        : ${ORG}
  Instance            : ${INSTANCE_NAME}  (${RUNTIME_LOCATION})
  Instance host (IP)  : ${host}
  PSC serviceAttachment: ${sa}
  Environment         : ${ENV_NAME}
  Env group / host    : ${ENVGROUP_NAME} / ${ENVGROUP_HOSTNAME}

  NEXT STEPS (exposure was intentionally skipped):
    • Create a load balancer / PSC NEG pointing at the instance above.
    • Point DNS for ${ENVGROUP_HOSTNAME} at the load balancer front end.
    • Deploy an API proxy and test:  https://${ENVGROUP_HOSTNAME}/<basepath>
  Docs: https://cloud.google.com/apigee/docs/api-platform/get-started/install-cli
${c_grn}==============================================================${c_off}
DONE
}

main() {
  preflight
  print_plan
  confirm "Proceed with provisioning?" || die "Aborted by user."
  enable_apis
  ensure_service_agent
  setup_kms
  setup_peering
  create_org
  create_instance
  create_environment
  attach_env_to_instance
  create_envgroup
  attach_env_to_group
  summary
}

main "$@"
