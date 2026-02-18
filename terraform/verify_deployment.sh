#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
TFVARS_FILE="${TFVARS_FILE:-terraform.tfvars}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

tfvars_val() {
  local key="$1"
  local file="${2:-${TFVARS_FILE}}"
  [[ -f "${file}" ]] || return 0
  awk -F'=' -v key="${key}" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      val=$2
      gsub(/^[ \t"]+|[ \t"]+$/, "", val)
      print val
      exit
    }
  ' "${file}"
}

retry_curl() {
  local url="$1"
  local attempts="${2:-20}"
  local sleep_seconds="${3:-10}"
  local i
  for i in $(seq 1 "${attempts}"); do
    if curl -sS -m 6 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done
  return 1
}

oci_state_with_retry() {
  local cmd="$1"
  local attempts="${2:-2}"
  local sleep_seconds="${3:-5}"
  local i state

  for i in $(seq 1 "${attempts}"); do
    state="$(bash -lc "${cmd}" 2>/dev/null || true)"

    if [[ "${state}" == "ACTIVE" ]]; then
      echo "${state}"
      return 0
    fi
    sleep "${sleep_seconds}"
  done

  echo "${state:-unknown}"
  return 1
}

need_cmd terraform
need_cmd jq
need_cmd curl

SPLUNK_IP="$(terraform output -raw splunk_instance_public_ip 2>/dev/null || true)"
SPLUNK_WEB_URL="$(terraform output -raw splunk_web_url 2>/dev/null || true)"
SPLUNK_HEC_ENDPOINT="$(terraform output -raw splunk_hec_endpoint 2>/dev/null || true)"
STREAM_ID="$(terraform output -raw stream_id 2>/dev/null || true)"
STREAM_POOL_ID="$(terraform output -raw stream_pool_id 2>/dev/null || true)"
SC_OCID="$(terraform output -raw logs_to_stream_connector_id 2>/dev/null || true)"

HEC_TOKEN="${SPLUNK_HEC_TOKEN_OVERRIDE:-$(tfvars_val splunk_hec_token "${TFVARS_FILE}" || true)}"
REQUIRE_STREAM_CONNECTOR="$(tfvars_val create_logs_to_stream_connector "${TFVARS_FILE}" || true)"
if [[ -z "${REQUIRE_STREAM_CONNECTOR}" ]]; then
  REQUIRE_STREAM_CONNECTOR="true"
fi

echo
echo "Post-deploy verification"
echo "- splunk_ip=${SPLUNK_IP:-n/a}"
echo "- stream_id=${STREAM_ID:-n/a}"
echo "- stream_pool_id=${STREAM_POOL_ID:-n/a}"
echo "- logs_to_stream_connector_id=${SC_OCID:-n/a}"

if [[ "${REQUIRE_STREAM_CONNECTOR}" == "true" && -z "${SC_OCID}" ]]; then
  echo "ERROR: logs_to_stream_connector_id is empty while create_logs_to_stream_connector=true." >&2
  exit 1
fi

if [[ -n "${SC_OCID}" ]]; then
  if command -v oci >/dev/null 2>&1; then
    SC_STATE="$(oci_state_with_retry "oci sch service-connector get --service-connector-id '${SC_OCID}' --connection-timeout 20 --read-timeout 30 --max-retries 1 --query 'data.\"lifecycle-state\"' --raw-output" 2 5 || true)"
    echo "- service_connector_state=${SC_STATE:-unknown}"
    if [[ "${SC_STATE}" == "unknown" || -z "${SC_STATE}" ]]; then
      echo "- service_connector_state_check=warning (OCI CLI timeout; continuing)"
    elif [[ "${SC_STATE}" != "ACTIVE" ]]; then
      echo "ERROR: Service connector is not ACTIVE." >&2
      exit 1
    fi
  fi
fi

if [[ -n "${STREAM_ID}" ]] && command -v oci >/dev/null 2>&1; then
  STREAM_STATE="$(oci_state_with_retry "oci streaming admin stream get --stream-id '${STREAM_ID}' --connection-timeout 20 --read-timeout 30 --max-retries 1 --query 'data.\"lifecycle-state\"' --raw-output" 2 5 || true)"
  echo "- stream_state=${STREAM_STATE:-unknown}"
  if [[ "${STREAM_STATE}" == "unknown" || -z "${STREAM_STATE}" ]]; then
    echo "- stream_state_check=warning (OCI CLI timeout; continuing)"
  elif [[ "${STREAM_STATE}" != "ACTIVE" ]]; then
    echo "ERROR: Stream is not ACTIVE." >&2
    exit 1
  fi
fi

if [[ -n "${SPLUNK_WEB_URL}" ]]; then
  if retry_curl "${SPLUNK_WEB_URL}" 24 10; then
    echo "- splunk_web_reachable=yes"
  else
    echo "ERROR: Splunk Web not reachable at ${SPLUNK_WEB_URL}" >&2
    exit 1
  fi
fi

if [[ -n "${SPLUNK_HEC_ENDPOINT}" ]]; then
  HEC_HEALTH_URL="${SPLUNK_HEC_ENDPOINT%/event}/health"
  if retry_curl "${HEC_HEALTH_URL}" 24 10; then
    echo "- hec_health_reachable=yes"
  else
    echo "ERROR: Splunk HEC health endpoint not reachable at ${HEC_HEALTH_URL}" >&2
    exit 1
  fi

  if [[ -n "${HEC_TOKEN}" && "${HEC_TOKEN}" != "TEMP_HEC_TOKEN_TO_REPLACE" ]]; then
    HEC_RESP="$(curl -sS -m 8 -H "Authorization: Splunk ${HEC_TOKEN}" -H "Content-Type: application/json" \
      -d "{\"event\":\"oci-splunk-post-deploy-test\",\"source\":\"oci-splunk/verify_deployment.sh\"}" \
      "${SPLUNK_HEC_ENDPOINT}" || true)"
    HEC_CODE="$(printf '%s' "${HEC_RESP}" | jq -r '.code // empty' 2>/dev/null || true)"
    if [[ "${HEC_CODE}" == "0" ]]; then
      echo "- hec_test_event_ingest=ok"
    else
      echo "ERROR: HEC test event failed. response=${HEC_RESP}" >&2
      exit 1
    fi
  else
    echo "- hec_test_event_ingest=skipped (splunk_hec_token not set to a real token)"
  fi
fi

echo "Verification passed."
