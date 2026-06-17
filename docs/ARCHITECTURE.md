# Architecture

## Common pipeline

1. OCI Logging writes events into selected log.
2. OCI Service Connector moves events from Logging to OCI Streaming stream.
3. A Kafka-compatible consumer reads the stream and posts events to Splunk HEC.
4. Splunk indexes and exposes events in Splunk UI.
5. If HEC token is placeholder, bootstrap generates token post-provisioning and persists it in `/opt/oci-splunk/runtime.env`.

## Consumer models

- `legacy_kafka_connect` (default): Kafka Connect standalone consumes OCI Streaming through the Kafka compatibility endpoint, then the Splunk Sink Connector posts to the base HEC URI.
- `soc4kafka` (opt-in): Splunk OTel Collector/SOC4Kafka consumes OCI Streaming through the Kafka compatibility endpoint, then the `splunk_hec` exporter posts to `/services/collector`. Validated end-to-end (OCI Stream -> SOC4Kafka -> HEC, `index=main` / `sourcetype=oci:log`).
- OCI Streaming speaks the **Kafka 1.0** protocol only (Metadata API v5, Fetch API v6). The SOC4Kafka collector must therefore set `protocol_version: "1.0.0"` on the kafka receiver, and use the stream pool's own `endpoint-fqdn` (`cell-N.streaming.<region>.oci.oraclecloud.com:9092`) as the bootstrap server so it reaches the pool's group coordinator. Both are handled by the Terraform templates. See `KB.md` (KB-001/KB-002).

## Existing Splunk mode

1. OCI Logging -> Service Connector -> OCI Streaming is unchanged.
2. The selected stream consumer posts to existing Splunk HEC URL/token you provide.
3. Splunk instance is not created by this stack.

## Security model

- Ingress restricted to operator public `/32` (SSH, 8000, 8088)
- Kafka auth uses OCI Streaming SASL/PLAIN over TLS
- Splunk HEC token required for ingestion tests and connector sink
- SSH access key is chosen at deployment time: generated key (default) or user-provided key
