# Oracle Cloud App for Splunk (adapted)

Dashboards for OCI logs ingested by the **oci-splunk** project via SOC4Kafka into
`index=main`, `sourcetype=oci:log` (OCI CloudEvents JSON).

## Attribution & license

Derived, modified copy of the *Oracle Cloud App for Splunk* (`splunk_app_oci`,
original author: Vivian Richards). **Not** the official app and **not affiliated
with or supported by Oracle or Splunk.** Provided as-is. Review the original
app's license before redistributing. You are responsible for maintaining this
copy and complying with all applicable terms.

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
