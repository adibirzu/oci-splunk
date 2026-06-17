# OCI Logs to Splunk (Managed or Existing Splunk)

This project deploys and validates an OCI logging pipeline to Splunk, with two supported targets:

- Managed Splunk on OCI compute (created by this project)
- Existing Splunk instance (you provide HEC endpoint/token)

## What gets deployed

- OCI Logging -> Service Connector -> OCI Streaming stream (Kafka compatibility)
- One stream consumer runtime:
  - `legacy_kafka_connect` (default): Kafka Connect standalone + Splunk sink connector
  - `soc4kafka` (opt-in): Splunk OTel Collector/SOC4Kafka consuming OCI Streaming directly
- Optional managed Splunk VM bootstrap (Splunk + HEC + selected stream consumer auto-configured)
- Consumer defaults tuned for stability (`splunk.hec.ack.enabled=false` for legacy, bounded queues for SOC4Kafka)
- Post-deploy verification (connectivity + HEC ingest test)
- Optimized stream usage: single OCI stream by default (`create_kafka_connect_internal_streams=false`)

## Deploy paths

- Local Terraform path: `terraform/deploy_local.sh`
- Local Terraform destroy wrapper: `terraform/destroy_local.sh`
- Local Terraform recreate wrapper: `terraform/recreate_local.sh`
- OCI CLI path: `deploy_oci_splunk.sh`
- OCI CLI destroy path: `destroy_oci_splunk.sh`

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

- `STREAM_CONSUMER_MODEL=legacy_kafka_connect` keeps the current Kafka Connect standalone behavior.
- `STREAM_CONSUMER_MODEL=soc4kafka` installs `soc4kafka.service` with Splunk OTel Collector on managed Splunk.
- SOC4Kafka receives `/services/collector`; legacy Kafka Connect receives the base HEC URI.

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
- Selected stream consumer service active on managed Splunk VM when SSH key is available

## SOC4Kafka on OCI Streaming

SOC4Kafka (Splunk OTel Collector) was validated end-to-end against OCI Streaming
(OCI Stream -> SOC4Kafka -> Splunk HEC, indexed as `index=main` /
`sourcetype=oci:log`). Enable it with `STREAM_CONSUMER_MODEL=soc4kafka` or
`stream_consumer_model = "soc4kafka"`.

OCI Streaming exposes only the **Kafka 1.0** protocol, so the consumer needs
specific settings. These are now baked into the Terraform templates, but note
them if you customize the config:

| Requirement | Why |
|-------------|-----|
| `protocol_version: "1.0.0"` on the kafka receiver | OCI Streaming caps Metadata at v5 / Fetch at v6. The franz-go client otherwise demands v7+ and loops on `max version 5 below the user defined min of 7`, never joining the consumer group. |
| Bootstrap = stream pool `endpoint-fqdn` (`cell-N.streaming.<region>.oci.oraclecloud.com:9092`) | The generic regional endpoint answers metadata but does not host the pool's group coordinator, so the consumer hangs. Terraform derives this automatically via `data.oci_streaming_stream_pool`. |
| `splunk_hec` exporter `sending_queue.batch.flush_timeout: 5s` | Without it the exporter waits for `min_size: 1000` items and low/idle volume never reaches HEC. |
| HEC token written directly to `inputs.conf` in cloud-init | The Splunk 10.x `http-event-collector` CLI is unreliable on first boot; writing the stanza declaratively avoids it. |

SASL is PLAIN over TLS; the username is `<tenancy_name>/<user_name>/<stream_pool_OCID>`
and the password is an OCI auth token for that user. See `KB.md` (KB-001..004) for
the failure modes behind each requirement.

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
