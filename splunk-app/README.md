# Splunk app — `splunk_app_oci` (adapted)

Dashboards for OCI logs that this project ingests into Splunk via SOC4Kafka
(`index=main`, `sourcetype=oci:log`, OCI CloudEvents JSON).

## Origin & attribution

This is a **derived, modified copy** of the *Oracle Cloud App for Splunk*
(`splunk_app_oci`, original author: Vivian Richards). It is **not** the official
app and is **not affiliated with or supported by Oracle or Splunk**. It is bundled
here only to make this project usable out of the box. You are responsible for
reviewing the original app's license and terms before using or redistributing it.

## What was changed

- `macros.conf` — `oci_index` now points at `index=main sourcetype="oci:log"`
  (this project's ingestion target) instead of `index=oci`.
- `props.conf` — added an `[oci:log]` stanza: JSON auto-extraction (`KV_MODE=json`),
  timestamping from the CloudEvents `time` field, and field aliases so VCN
  src/dest/ports and common audit fields resolve on this sourcetype.
- `oci_vcn_flow_overview.xml` — a new VCN flow dashboard that reads **raw** events
  (no summary index needed), set as the default Networking view. The original
  summary-index dashboards are retained but require you to enable summary indexing.
- `app.conf` — version bump + description noting the adaptation.

## Install

Automatically installed on the managed Splunk VM by cloud-init on first deploy.
To install manually on any Splunk:

```bash
cp -r splunk_app_oci "$SPLUNK_HOME/etc/apps/"
chown -R splunk:splunk "$SPLUNK_HOME/etc/apps/splunk_app_oci"
$SPLUNK_HOME/bin/splunk restart
```

Then open **Oracle Cloud App for Splunk → Security → OCI Audit** and
**Networking → VCN Flow Logs - Overview (OOTB)**.

## Build a Splunkbase package (.spl)

The app ships in Splunkbase format — `app.manifest`, icons (`static/appIcon*.png`),
`metadata/default.meta`, and an in-app `README.md`. Build a distributable `.spl`:

```bash
cd splunk-app
./build.sh                 # -> dist/splunk_app_oci-<version>.spl
```

Before submitting to Splunkbase, validate with AppInspect:

```bash
pip install splunk-appinspect
splunk-appinspect inspect dist/splunk_app_oci-<version>.spl --mode precert
```

Install the `.spl` directly: Splunk Web → *Apps → Install app from file*, or
`$SPLUNK_HOME/bin/splunk install app dist/splunk_app_oci-<version>.spl`.
