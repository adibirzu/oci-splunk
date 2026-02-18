# Architecture

## Managed Splunk mode

1. OCI Logging writes events into selected log.
2. OCI Service Connector moves events from Logging to OCI Streaming stream.
3. Kafka Connect worker consumes the stream via OCI Streaming Kafka compatibility endpoint.
4. Splunk Sink Connector posts events to Splunk HEC.
5. Splunk indexes and exposes events in Splunk UI.
6. If HEC token is placeholder, bootstrap generates token post-provisioning and persists it in `/opt/oci-splunk/runtime.env`.

## Existing Splunk mode

1. OCI Logging -> Service Connector -> OCI Streaming is unchanged.
2. Kafka Connect worker posts to existing Splunk HEC URL/token you provide.
3. Splunk instance is not created by this stack.

## Security model

- Ingress restricted to operator public `/32` (SSH, 8000, 8088)
- Kafka auth uses OCI Streaming SASL/PLAIN over TLS
- Splunk HEC token required for ingestion tests and connector sink
- SSH access key is chosen at deployment time: generated key (default) or user-provided key
