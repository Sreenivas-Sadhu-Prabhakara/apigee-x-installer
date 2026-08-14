# Apigee X installer (service-account impersonation)

Provision **Apigee X** — organization, runtime instance, environment, and
environment group — on Google Cloud using **service-account impersonation**
(no exported key files).

- **Interactive config generator:** fill in your variables in the browser and
  download a ready-to-run script → **see the GitHub Pages site for this repo.**
- **Or** edit the `USER CONFIG` block at the top of
  [`provision-apigee-x.sh`](./provision-apigee-x.sh) and run it directly.

## What it does

1. Enables the required Google APIs.
2. Ensures the Apigee service agent exists.
3. (Optional) Creates a Cloud KMS key ring + key for runtime DB encryption and
   grants the Apigee service agent access.
4. (peering mode only) Reserves an IP range and creates the service-networking
   VPC peering.
5. Creates the Apigee **organization** (`eval` or `paid`, `nopeering` by default).
6. Creates the **runtime instance** (20–45 min).
7. Creates the **environment** and attaches it to the instance.
8. Creates the **environment group** and attaches the environment.

> **Exposure is intentionally not configured.** No load balancer / DNS is
> created — wire that up afterwards to reach the runtime.

## Requirements

- `gcloud`, `curl`, and `jq` on your PATH.
- You are logged in: `gcloud auth login`.
- You hold **`roles/iam.serviceAccountTokenCreator`** on the service account you
  impersonate (`SA_EMAIL`).
- That service account holds, on the target project, at least:
  `roles/apigee.admin`, `roles/serviceusage.serviceUsageAdmin`,
  `roles/cloudkms.admin` (if creating a KMS key), and
  `roles/compute.networkAdmin` (only for `NETWORKING=peering`).
- For `ORG_TYPE=paid`, the project must be linked to an active billing account.

## Usage

```bash
# 1. Edit the USER CONFIG block (or download a filled-in copy from the Pages site)
# 2. Preview without changing anything:
DRY_RUN=true ./provision-apigee-x.sh

# 3. Provision for real:
./provision-apigee-x.sh
```

Every variable in the config block is also overridable via an environment
variable of the same name, e.g.:

```bash
PROJECT_ID=my-proj SA_EMAIL=sa@my-proj.iam.gserviceaccount.com \
ORG_TYPE=eval NETWORKING=nopeering ./provision-apigee-x.sh
```

## Notes

- **Idempotent:** re-running skips resources that already exist, so it's safe to
  resume after an interruption.
- **Impersonation everywhere:** every `gcloud` call passes
  `--impersonate-service-account`, and each REST call mints a fresh short-lived
  token via impersonation (so long-running instance creation never hits an
  expired token).
- `AUTO_APPROVE=true` skips the confirmation prompt (useful in CI).

The config generator (`index.html`) emits the exact same
`provision-apigee-x.sh`, with your values baked in as defaults.
