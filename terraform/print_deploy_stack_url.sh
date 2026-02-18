#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <github-zip-url>"
  echo "Example: $0 https://github.com/<owner>/<repo>/archive/refs/heads/main.zip"
  exit 1
fi

ZIP_URL="$1"
ENCODED_URL="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${ZIP_URL}")"

echo "https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=${ENCODED_URL}"
