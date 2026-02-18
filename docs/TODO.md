# TODO

- [x] Default to one OCI stream for this project (`create_kafka_connect_internal_streams=false`).
- [x] Ensure Logs -> Stream connector is created and verified (`create_logs_to_stream_connector=true`).
- [x] Add SSH key selection at deploy time with default `generate` and reusable generated key path.
- [x] Auto-generate/fetch Splunk HEC token for managed Splunk deployments.
- [x] Auto-configure Kafka Connect standalone + Splunk sink connector on managed Splunk VM (`AUTO_CONFIGURE_KAFKA_CONNECT_ON_VM=true`).
- [x] Update docs with HEC CLI references and deployment flow.
- [x] Add safe OCI destroy script (`destroy_oci_splunk.sh`) that only deletes resources marked as script-created.
- [x] Add IAM preflight check at deploy start with optional policy create/update flow.
- [ ] Complete full real-world destroy/recreate in Adrian_Birzu using a principal authorized to create IAM policies.
- [ ] Reconcile Terraform state with manually managed OCI resources after OCI registry connectivity is stable.
- [ ] Add automated post-provision check that confirms events from OCI Logging are visible in Splunk search.
