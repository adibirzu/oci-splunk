#!/usr/bin/env bash
# Package splunk_app_oci as a Splunkbase-style .spl (gzipped tar with the app
# directory at the root), excluding OS/editor junk and local artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP="splunk_app_oci"
VERSION="$(awk -F'= *' '/^version/{print $2; exit}' "${APP}/default/app.conf" | tr -d ' ')"
OUT="${APP}-${VERSION}.spl"
DIST="dist"
mkdir -p "${DIST}"

# Scrub junk before packaging.
find "${APP}" \( -name '.DS_Store' -o -name '._*' -o -name '*.pyc' -o -name '__pycache__' \) -exec rm -rf {} + 2>/dev/null || true

# COPYFILE_DISABLE keeps macOS from injecting ._ AppleDouble files into the tar.
COPYFILE_DISABLE=1 tar \
  --exclude='.DS_Store' --exclude='._*' --exclude='*.pyc' --exclude='__pycache__' \
  -czf "${DIST}/${OUT}" "${APP}"

echo "Built ${DIST}/${OUT}"
echo "Contents (top level):"
tar tzf "${DIST}/${OUT}" | awk -F/ '{print $1"/"$2}' | sort -u | head -20

cat <<'NOTE'

Next steps:
- Validate with Splunk AppInspect before any Splunkbase submission:
    splunk-appinspect inspect dist/splunk_app_oci-<version>.spl --mode precert
- Install locally: Splunk Web > Apps > Install app from file, or
    $SPLUNK_HOME/bin/splunk install app dist/splunk_app_oci-<version>.spl
NOTE
