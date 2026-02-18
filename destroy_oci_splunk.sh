#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
STATE_FILE="${STATE_FILE:-${OUTPUT_DIR}/deployment-state.env}"
DRY_RUN="false"

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="true"
fi

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

bool_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

run_or_echo() {
  local cmd="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: ${cmd}"
  else
    eval "${cmd}" || {
      echo "WARN: command failed (continuing): ${cmd}" >&2
      return 0
    }
  fi
}

delete_if_created() {
  local created_flag="$1"
  local resource_id="$2"
  local resource_label="$3"
  local delete_cmd="$4"

  if ! bool_true "${created_flag}"; then
    echo "skip ${resource_label}: not created by script"
    return 0
  fi
  if [[ -z "${resource_id}" || "${resource_id}" == "null" ]]; then
    echo "skip ${resource_label}: missing id"
    return 0
  fi

  log "Deleting ${resource_label}: ${resource_id}"
  run_or_echo "${delete_cmd}"
}

need_cmd oci

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "No state file found at ${STATE_FILE}. Nothing to destroy."
  exit 0
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

log "Using state file: ${STATE_FILE}"

# Reverse dependency order

delete_if_created "${CREATED_SERVICE_CONNECTOR_FN:-false}" "${SERVICE_CONNECTOR_FN_OCID:-}" \
  "service connector (logs->functions)" \
  "oci sch service-connector delete --service-connector-id '${SERVICE_CONNECTOR_FN_OCID}' --force --wait-for-state DELETED"

delete_if_created "${CREATED_SERVICE_CONNECTOR_STREAM:-false}" "${SERVICE_CONNECTOR_STREAM_OCID:-}" \
  "service connector (logs->stream)" \
  "oci sch service-connector delete --service-connector-id '${SERVICE_CONNECTOR_STREAM_OCID}' --force --wait-for-state DELETED"

delete_if_created "${CREATED_FUNCTION:-false}" "${FUNCTION_OCID:-}" \
  "function" \
  "oci fn function delete --function-id '${FUNCTION_OCID}' --force"

delete_if_created "${CREATED_FN_APP:-false}" "${FN_APP_OCID:-}" \
  "function app" \
  "oci fn application delete --application-id '${FN_APP_OCID}' --force"

delete_if_created "${CREATED_STREAM:-false}" "${STREAM_OCID:-}" \
  "stream" \
  "oci streaming admin stream delete --stream-id '${STREAM_OCID}' --force --wait-for-state DELETED"

delete_if_created "${CREATED_STREAM_POOL:-false}" "${STREAM_POOL_OCID:-}" \
  "stream pool" \
  "oci streaming admin stream-pool delete --stream-pool-id '${STREAM_POOL_OCID}' --force --wait-for-state DELETED"

delete_if_created "${CREATED_SPLUNK_INSTANCE:-false}" "${SPLUNK_INSTANCE_OCID:-}" \
  "splunk instance" \
  "oci compute instance terminate --instance-id '${SPLUNK_INSTANCE_OCID}' --preserve-boot-volume false --force --wait-for-state TERMINATED"

delete_if_created "${CREATED_SUBNET:-false}" "${SUBNET_OCID:-}" \
  "subnet" \
  "oci network subnet delete --subnet-id '${SUBNET_OCID}' --force"

delete_if_created "${CREATED_NSG:-false}" "${NSG_OCID:-}" \
  "network security group" \
  "oci network nsg delete --nsg-id '${NSG_OCID}' --force"

delete_if_created "${CREATED_ROUTE_TABLE:-false}" "${RT_OCID:-}" \
  "route table" \
  "oci network route-table delete --rt-id '${RT_OCID}' --force"

delete_if_created "${CREATED_IGW:-false}" "${IGW_OCID:-}" \
  "internet gateway" \
  "oci network ig delete --ig-id '${IGW_OCID}' --force"

delete_if_created "${CREATED_VCN:-false}" "${VCN_OCID:-}" \
  "vcn" \
  "oci network vcn delete --vcn-id '${VCN_OCID}' --force"

if [[ "${DRY_RUN}" == "false" ]]; then
  rm -f "${STATE_FILE}"
  log "Destroy complete. Removed state file ${STATE_FILE}"
else
  log "Dry run complete."
fi
