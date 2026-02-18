# OCI Logs to Splunk (Managed or Existing Splunk)

This project deploys and validates an OCI logging pipeline to Splunk, with two supported targets:

- Managed Splunk on OCI compute (created by this project)
- Existing Splunk instance (you provide HEC endpoint/token)

## What gets deployed

- OCI Logging -> Service Connector -> OCI Streaming stream (Kafka compatibility)
- Kafka Connect worker configuration + Splunk sink connector config
- Optional managed Splunk VM bootstrap (Splunk + HEC + Kafka Connect worker auto-configured)
- Connector defaults tuned for stability (`splunk.hec.ack.enabled=false`, bounded outstanding events, JVM heap options)
- Post-deploy verification (connectivity + HEC ingest test)
- Optimized stream usage: single OCI stream by default (`create_kafka_connect_internal_streams=false`)

## Deploy paths

- Local Terraform path: `terraform/deploy_local.sh`
- Local Terraform destroy wrapper: `terraform/destroy_local.sh`
- Local Terraform recreate wrapper: `terraform/recreate_local.sh`
- OCI CLI path: `deploy_oci_splunk.sh`
- OCI CLI destroy path: `destroy_oci_splunk.sh`
- OCI Resource Manager stack path (from GitHub ZIP)

## Stack Deploy Button (GitHub)

Replace `<owner>` and `<repo>`:

[![Deploy to Oracle Cloud](https://img.shields.io/badge/Deploy%20to-Oracle%20Cloud-red)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https%3A%2F%2Fgithub.com%2F%3Cowner%3E%2F%3Crepo%3E%2Farchive%2Frefs%2Fheads%2Fmain.zip)

Stack working directory:

- `oci-splunk/terraform`

Main stack fields to set:

- `compartment_ocid`
- `region`
- `allowed_ingress_cidr`
- `use_existing_splunk`
- `existing_splunk_web_url` (optional, when reusing existing Splunk)
- `ssh_public_key` (managed Splunk mode)
- `splunk_admin_password` (managed Splunk mode)
- `log_group_ocid`
- `log_ocid`
- `stream_name`
- `existing_stream_id` / `existing_stream_pool_id` (reuse mode)
- `create_logs_to_stream_connector` (keep enabled)
- `create_kafka_connect_internal_streams` (keep disabled unless using distributed Kafka Connect worker topics)
- `streaming_tenancy_name`
- `streaming_user_name`
- `streaming_auth_token`
- `splunk_hec_url`
- `splunk_hec_token`
- `splunk_hec_index`

## Quick start (local Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
./deploy_local.sh apply
# or full cycle:
./recreate_local.sh
```

`deploy_local.sh` now:

- asks whether to generate a new SSH key or use an existing one (default: generate)
- auto-detects OCI profile config
- auto-detects your public IP and restricts ingress to `/32`
- runs IAM preflight checks for required deployment permissions
- supports policy reconciliation flow (create/update `oci-splunk-deployer-access`) after approval
- reuses existing stream/pool when found
- auto-generates Splunk HEC token after managed Splunk provisioning (when placeholder is used)
- prints connection credentials at the end
- runs `verify_deployment.sh` automatically after apply

## Existing Splunk mode

Use existing Splunk and keep OCI logs delivery by pointing connector/HEC to your instance.

For OCI CLI path (`deploy_oci_splunk.sh`):

- `AUTO_CONFIGURE_KAFKA_CONNECT_ON_VM=true` (default) installs Kafka Connect standalone and registers Splunk sink connector automatically on managed Splunk VM.

- set `USE_EXISTING_SPLUNK=true`
- set `SPLUNK_HEC_URL`
- set `SPLUNK_HEC_TOKEN`
- optionally set `EXISTING_SPLUNK_WEB_URL`

Example in `.env.local`:

```bash
USE_EXISTING_SPLUNK=true
SPLUNK_HEC_URL="https://your-splunk:8088/services/collector/event"
SPLUNK_HEC_TOKEN="<hec-token>"
EXISTING_SPLUNK_WEB_URL="https://your-splunk:8000"
```

## Managed Splunk token behavior

- Set `SPLUNK_HEC_TOKEN=TEMP_HEC_TOKEN_TO_REPLACE` (or `replace-with-hec-token`) to auto-generate a new token.
- The generated token is written on the VM at `/opt/oci-splunk/runtime.env`.
- `deploy_oci_splunk.sh` also writes it locally to `output/generated-hec-token.env`.

## User creation script

Create/update Splunk users locally or remotely:

```bash
./scripts/create_splunk_user.sh \
  --host <splunk-ip> \
  --ssh-user opc \
  --ssh-key ~/.ssh/id_ed25519 \
  --admin-user admin \
  --admin-password '<admin-pass>' \
  --new-user ingest_user \
  --new-password '<new-pass>' \
  --new-role user
```

## Verification script

Run manually anytime:

```bash
cd terraform
./verify_deployment.sh
```

Checks include:

- Service Connector state is `ACTIVE`
- Stream state is `ACTIVE`
- Splunk Web reachable
- Splunk HEC health reachable
- HEC test event ingest (when real token is set)
- Kafka Connect service active on managed Splunk VM (kafka/both modes)

## Safe destroy script

`destroy_oci_splunk.sh` deletes only resources marked as created by `deploy_oci_splunk.sh`.

- It reads `output/deployment-state.env`.
- Resources discovered as reused/pre-existing are not deleted.
- Use `--dry-run` first.

```bash
./destroy_oci_splunk.sh --dry-run
./destroy_oci_splunk.sh
```

## Environment files

- Use `.env.local` (preferred) for local deployment variables
- Template: `.env.local.example`
- Legacy `.env` and `.env.example` are still supported

## Documentation

- Architecture: `docs/ARCHITECTURE.md`
- Deployment guide: `docs/DEPLOYMENT.md`
- References and blogs used: `docs/REFERENCES.md`
- TODO list: `docs/TODO.md`
