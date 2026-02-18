# Deployment Guide

## Local (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
./deploy_local.sh apply
# quick wrappers:
./destroy_local.sh
./recreate_local.sh
```

At startup, the script asks:
- generate a new SSH key pair (default)
- or use your existing public key path
- runs IAM preflight checks for the executing user and required services

If IAM permissions are missing, the script:
- prints required policy statements
- asks for approval to create/update policy (`oci-splunk-deployer-access`)
- blocks deployment if policy creation is denied or unauthorized

Required IAM scope (minimum):
- `manage instance-family` in target compartment
- `manage virtual-network-family` in target compartment (when creating network)
- `manage stream-family` in target compartment (when creating stream/pool)
- `manage serviceconnectors` in target compartment (when creating Logging -> Stream connector)

After apply:

- connection summary is printed (web URL, HEC URL, admin password)
- generated HEC token is auto-detected for managed Splunk and printed
- `verify_deployment.sh` runs automatically

## OCI CLI script

```bash
cp .env.local.example .env.local
# edit values
./deploy_oci_splunk.sh
```

At startup, the script asks:
- generate a new SSH key pair (default)
- or use your existing public key path

Existing Splunk mode:

- `USE_EXISTING_SPLUNK=true`
- `SPLUNK_HEC_URL` and `SPLUNK_HEC_TOKEN` required

Managed Splunk mode:
- if `SPLUNK_HEC_TOKEN` is placeholder (`TEMP_HEC_TOKEN_TO_REPLACE`), token is generated post-provisioning from Splunk CLI and stored in `output/generated-hec-token.env`
- `AUTO_CONFIGURE_KAFKA_CONNECT_ON_VM=true` (default) installs Kafka Connect standalone on the VM and auto-wires the Splunk sink connector to the OCI stream
- Kafka connector defaults are compatibility/stability oriented: `splunk.hec.ack.enabled=false`, `splunk.hec.max.outstanding.events=10000`, and `KAFKA_HEAP_OPTS=-Xms512m -Xmx2g`

Destroy only resources created by deploy script:

```bash
./destroy_oci_splunk.sh --dry-run
./destroy_oci_splunk.sh
```

The destroy script reads `output/deployment-state.env` and uses `CREATED_*` flags to avoid deleting pre-existing resources.

## OCI Resource Manager stack

1. Create stack from GitHub ZIP
2. Set working directory: `oci-splunk/terraform`
3. Fill variables in stack form (`schema.yaml`)
4. Run Plan and Apply

Sample API body:
- `docs/OCI_STACK_DEPLOYMENT_BODY.json`

## Post-deploy validation

```bash
cd terraform
./verify_deployment.sh
```

Validation checks:
- Service Connector lifecycle state
- Stream lifecycle state
- Splunk web reachability
- Splunk HEC health endpoint
- Splunk HEC ingest test event
- Kafka Connect service active on managed Splunk VM (kafka/both modes)

## Stream optimization

- `create_kafka_connect_internal_streams=false` is now the default.
- Only one OCI stream is required for this project (`stream_name`, e.g. `Logs2Splunk`).
- Ensure `create_logs_to_stream_connector=true` so OCI Logging events are forwarded to that stream.
- This aligns with OCI-DEMO C3: OCI Logging -> Service Connector Hub -> OCI Streaming -> Kafka Connect -> Splunk HEC.

## Splunk user management

```bash
./scripts/create_splunk_user.sh --help
```
