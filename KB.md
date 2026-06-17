# OCI-Splunk Knowledge Base

Troubleshooting reference. Consult **only when an error occurs**. Add a new entry
after fixing any non-obvious error.

---

## KB-001 — SOC4Kafka collector loops on metadata, never joins the consumer group

**Component:** `soc4kafka.service` (splunk-otel-collector `otelcol` v0.154.1, `kafkareceiver` / franz-go) against OCI Streaming.

**Symptom:** Service is `active`, SASL succeeds, but the journal repeats
`metadata update triggered` every ~5s and never logs `joining group` / `fetch`.
Debug logs show:
`re-updating metadata due to err: request key 3 version returned has max version 5 below the user defined min of 7`
(request key 3 = Metadata API; later key 1 = Fetch API).

**Root cause:** OCI Streaming implements the **Kafka 1.0 protocol** — Metadata API
max v5, Fetch API max v6. franz-go defaults to (or, with `protocol_version: "2.1.0"`,
demands) v7+, so it refuses every metadata/fetch response and never joins.

**Fix:** Pin the receiver to Kafka 1.0 in the collector config:
```yaml
receivers:
  kafka:
    protocol_version: "1.0.0"
```
Applied in `terraform/templates/soc4kafka-config.yaml.tftpl`.

---

## KB-002 — SASL auth works for produce but consumer group coordination hangs

**Component:** Same as KB-001.

**Symptom:** SASL handshake/auth succeed, but consumer group join never completes
(pairs with KB-001's metadata loop).

**Root cause:** The Kafka **bootstrap server** was the generic regional endpoint
`streaming.<region>.oci.oraclecloud.com:9092`. That endpoint answers metadata but
does **not** host a specific stream pool's group coordinator. The coordinator lives
on the pool's own cell endpoint, e.g. `cell-1.streaming.<region>.oci.oraclecloud.com:9092`.

**Fix:** Derive the bootstrap from the stream pool's `endpoint-fqdn`
(`oci streaming admin stream-pool get … --query 'data."endpoint-fqdn"'`). In
Terraform, `data.oci_streaming_stream_pool.effective.endpoint_fqdn` feeds
`local.kafka_bootstrap_servers` (`terraform/main.tf`).

---

## KB-003 — Splunk events consumed from Kafka never appear in the index

**Component:** `splunk_hec` exporter in the SOC4Kafka collector config.

**Symptom:** Journal shows `processing fetched records … count: N`, but the events
never show up in Splunk search; no errors logged.

**Root cause:** `exporters.splunk_hec.sending_queue.batch.min_size: 1000` with no
flush timeout — the exporter waits to accumulate 1000 items before sending, so
low/idle volume sits in the queue indefinitely.

**Fix:** Add `flush_timeout: 5s` under `sending_queue.batch`
(`terraform/templates/soc4kafka-config.yaml.tftpl`). For test traffic, also note
the kafkareceiver defaults to `initial_offset: latest`, so publish test messages
**after** the consumer has joined the group.

---

## KB-004 — cloud-init aborts before HEC token / soc4kafka setup on Splunk 10.x

**Component:** `terraform/templates/splunk-cloud-init.tftpl`, managed-Splunk first boot.

**Symptom:** `cloud-init status` = `error`; Splunk core runs and web is up, but
`/opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf`, `runtime.env`, the
otelcol binary, and `soc4kafka.service` are all missing.
`/tmp/hec-create.log` shows `Data could not be written: /nobody/splunk_httpinput/...`.

**Root cause:** Splunk 10.x's `http-event-collector enable|create` CLI
intermittently fails to persist on first boot. The script then ran
`sed … local/inputs.conf` on the file the CLI never wrote; under
`set -euo pipefail` that non-zero `sed` aborted the entire user-data script before
the SOC4Kafka steps ran.

**Fix:** Skip the flaky CLI. Generate a UUID token when none is supplied and write
the HEC stanza directly to `local/inputs.conf` (Splunk enables HEC from it on the
next restart). No `sed`-over-missing-file remains. See `splunk-cloud-init.tftpl`.

**Prevention:** Keep HEC bootstrap declarative (write `inputs.conf`), not via the
runtime CLI, on first boot.
