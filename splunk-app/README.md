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

On the **managed Splunk VM** it's installed automatically by cloud-init on first
deploy. For a **standalone Splunk** (or any instance), install it manually one of
three ways:

**A. Download the packaged `.spl` and install via Splunk Web (easiest)**

Download [`releases/splunk_app_oci-2.1.4.spl`](releases/splunk_app_oci-2.1.4.spl)
(verify with [`.sha256`](releases/splunk_app_oci-2.1.4.spl.sha256)), then in Splunk:
*Apps → Manage Apps → Install app from file → choose the `.spl` → Upload*, and
restart when prompted.

**B. Install the `.spl` from the CLI**

```bash
$SPLUNK_HOME/bin/splunk install app splunk_app_oci-2.1.4.spl -update 1
$SPLUNK_HOME/bin/splunk restart
```

**C. Copy the source directory**

```bash
cp -r splunk_app_oci "$SPLUNK_HOME/etc/apps/"
chown -R splunk:splunk "$SPLUNK_HOME/etc/apps/splunk_app_oci"
$SPLUNK_HOME/bin/splunk restart
```

> Requirement for all paths: your OCI logs must be indexed as
> `sourcetype=oci:log` (what this project's SOC4Kafka exporter does). On a
> standalone instance not fed by this project, point your own ingest at that
> sourcetype, or change the `oci_index` macro to match your index/sourcetype.

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
