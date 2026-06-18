# Oracle Cloud App for Splunk (adapted)

Dashboards for OCI logs ingested by the **oci-splunk** project via SOC4Kafka into
`index=main`, `sourcetype=oci:log` (OCI CloudEvents JSON).

## Attribution & license

Derived, modified copy of the *Oracle Cloud App for Splunk* (`splunk_app_oci`,
original author: Vivian Richards). **Not** the official app and **not affiliated
with or supported by Oracle or Splunk.** Provided as-is. Review the original
app's license before redistributing. You are responsible for maintaining this
copy and complying with all applicable terms.

## Release notes — 2.2.0

- **Live filter dropdowns** — Tenant/Compartment/Log-source filters on the audit,
  cloudguard, and object-storage dashboards now populate from live data instead of
  the (initially empty) `oci_services` lookup.
- **VCN Security & Traffic Analysis dashboards** rewritten to read raw events (no
  summary index needed) — rejected-traffic focus and volume/talkers focus.
- **OCI Overview** landing dashboard (audit + network + object storage at a glance),
  set as the app's default view.
- **Out-of-the-box alerts** (scheduled, tracked): VCN rejected-traffic spike, audit
  failures, IAM/policy changes, new external source IP to object storage.
- **CIM mapping** — `eventtypes.conf` + `tags.conf` tag VCN flow logs for the
  Network Traffic model (with `src`/`dest`/`ports`/`action`/`bytes`/`transport`
  field normalization); audit/object-storage tagged for change/audit.

## Release notes — 2.1.5

- Fixed the **VCN Flow Logs - Overview (OOTB)** dashboard: address/action filters
  now use an explicit `| search` after the `oci_trim` macro (previously they were
  parsed as arguments to `oci_trim`'s trailing `fields` command).

## Release notes — 2.1.4

- `oci_index` base macro now targets `index=main sourcetype="oci:log"` (this
  project's ingestion target).
- `[oci:log]` sourcetype props: JSON KV extraction, CloudEvents `time`
  timestamping, and field aliases for VCN (src/dest/ports) and Audit
  (eventName/compartmentName/principalName/src_ip).
- New **VCN Flow Logs - Overview (OOTB)** dashboard reads raw events (no summary
  index required); set as the default Networking view.
- Summary-index dashboards from the original app are retained as-is.

## Install

Auto-installed on the managed Splunk VM by the oci-splunk project. Manual:

```bash
cp -r splunk_app_oci "$SPLUNK_HOME/etc/apps/"
chown -R splunk:splunk "$SPLUNK_HOME/etc/apps/splunk_app_oci"
"$SPLUNK_HOME/bin/splunk" restart
```

## Requirements

Splunk Enterprise 9.x or 10.x. Data must be indexed as `sourcetype=oci:log`
(the project's SOC4Kafka/Splunk OTel Collector exporter does this).
