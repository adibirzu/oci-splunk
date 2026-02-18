#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

if [[ -f "${SCRIPT_DIR}/.env.local" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env.local"
elif [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
fi

OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
DEFAULT_COMPARTMENT_OCID="${DEFAULT_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaagy3yddkkampnhj3cqm5ar7w2p7tuq5twbojyycvol6wugfav3ckq}"
SSH_KEY_SELECTION="${SSH_KEY_SELECTION:-}"
SELECTED_SSH_PRIVATE_KEY_PATH="${SELECTED_SSH_PRIVATE_KEY_PATH:-}"

oci_cfg_value() {
  local key="$1"
  awk -F'=' -v profile="${OCI_PROFILE}" -v key="${key}" '
    /^\[.*\]$/ { section=substr($0,2,length($0)-2); next }
    section == profile {
      gsub(/^[ \t]+|[ \t]+$/, "", $1)
      if ($1 == key) {
        val=$2
        gsub(/^[ \t]+|[ \t]+$/, "", val)
        print val
        exit
      }
    }
  ' "${OCI_CONFIG_FILE}"
}

detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${ip}" ]]; then
      ip="$(curl -fsS --connect-timeout 3 https://ifconfig.me 2>/dev/null || true)"
    fi
  fi
  if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "${ip}"
  fi
}

prompt_ssh_key_mode() {
  if [[ -n "${SSH_KEY_SELECTION}" ]]; then
    return
  fi
  if [[ -t 0 ]]; then
    local choice=""
    read -r -p "SSH key mode [generate/use] (default: generate): " choice
    case "${choice}" in
      ""|g|G|generate|Generate) SSH_KEY_SELECTION="generate" ;;
      u|U|use|Use|existing|Existing) SSH_KEY_SELECTION="use" ;;
      *)
        echo "Invalid selection '${choice}', defaulting to generate."
        SSH_KEY_SELECTION="generate"
        ;;
    esac
  else
    SSH_KEY_SELECTION="generate"
  fi
}

prepare_ssh_key_material() {
  prompt_ssh_key_mode

  if [[ "${SSH_KEY_SELECTION}" == "generate" ]]; then
    need_cmd ssh-keygen
    local key_base
    key_base="${HOME}/.ssh/oci_splunk_ed25519"
    if [[ ! -f "${key_base}" || ! -f "${key_base}.pub" ]]; then
      ssh-keygen -t ed25519 -N "" -C "oci-splunk" -f "${key_base}" >/dev/null
      log "Generated SSH key pair: ${key_base}(.pub)"
    else
      log "Reusing generated SSH key pair: ${key_base}(.pub)"
    fi
    SELECTED_SSH_PRIVATE_KEY_PATH="${key_base}"
    SPLUNK_SSH_PUBLIC_KEY_PATH="${key_base}.pub"
  else
    if [[ -z "${SPLUNK_SSH_PUBLIC_KEY_PATH}" ]]; then
      if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
        SPLUNK_SSH_PUBLIC_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"
      elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
        SPLUNK_SSH_PUBLIC_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
      fi
    fi
    if [[ -t 0 ]]; then
      local prompt_default="${SPLUNK_SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
      local input_path=""
      read -r -p "Path to existing SSH public key [${prompt_default}]: " input_path
      SPLUNK_SSH_PUBLIC_KEY_PATH="${input_path:-${prompt_default}}"
    fi
    [[ -n "${SPLUNK_SSH_PUBLIC_KEY_PATH}" ]] || fail "SPLUNK_SSH_PUBLIC_KEY_PATH is required when SSH_KEY_SELECTION=use"
    [[ -f "${SPLUNK_SSH_PUBLIC_KEY_PATH}" ]] || fail "SSH public key not found: ${SPLUNK_SSH_PUBLIC_KEY_PATH}"
    local private_candidate="${SPLUNK_SSH_PUBLIC_KEY_PATH%.pub}"
    if [[ -f "${private_candidate}" ]]; then
      SELECTED_SSH_PRIVATE_KEY_PATH="${private_candidate}"
    fi
  fi
}

hec_base_uri_from_url() {
  local url="$1"
  local base="${url%%/services/collector*}"
  base="${base%/}"
  echo "${base}"
}

hec_health_url_from_url() {
  local url="$1"
  local base
  base="$(hec_base_uri_from_url "${url}")"
  if [[ -n "${base}" ]]; then
    echo "${base}/services/collector/health"
  else
    echo "${url%/event}/health"
  fi
}

autodetect_oci_profile() {
  if [[ -f "${OCI_CONFIG_FILE}" ]]; then
    export OCI_CLI_PROFILE="${OCI_PROFILE}"
    export OCI_CLI_CONFIG_FILE="${OCI_CONFIG_FILE}"

    REGION="${REGION:-$(oci_cfg_value region || true)}"
    TENANCY_OCID="${TENANCY_OCID:-$(oci_cfg_value tenancy || true)}"
    OCI_USER_OCID="${OCI_USER_OCID:-$(oci_cfg_value user || true)}"
    OCI_FINGERPRINT="${OCI_FINGERPRINT:-$(oci_cfg_value fingerprint || true)}"
    OCI_KEY_FILE="${OCI_KEY_FILE:-$(oci_cfg_value key_file || true)}"

    if [[ -z "${COMPARTMENT_OCID:-}" ]]; then
      COMPARTMENT_OCID="${DEFAULT_COMPARTMENT_OCID}"
      printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "COMPARTMENT_OCID not set; defaulting to ${COMPARTMENT_OCID} (Adrian_Birzu)"
    fi
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "Detected OCI CLI profile ${OCI_PROFILE} in ${OCI_CONFIG_FILE}"
  fi
}

autodetect_oci_profile

MODE="${MODE:-kafka}"                         # kafka | functions | both
CREATE_SPLUNK_INSTANCE="${CREATE_SPLUNK_INSTANCE:-true}"
CREATE_STREAMING="${CREATE_STREAMING:-true}"
CREATE_CONNECTOR_LOGS_TO_STREAM="${CREATE_CONNECTOR_LOGS_TO_STREAM:-true}"
CREATE_CONNECTOR_LOGS_TO_FUNCTIONS="${CREATE_CONNECTOR_LOGS_TO_FUNCTIONS:-false}"
CREATE_KAFKA_CONNECT_FILES="${CREATE_KAFKA_CONNECT_FILES:-true}"
AUTO_CONFIGURE_KAFKA_CONNECT_ON_VM="${AUTO_CONFIGURE_KAFKA_CONNECT_ON_VM:-true}"
CREATE_FN_APP="${CREATE_FN_APP:-true}"
DEPLOY_FUNCTION_CODE="${DEPLOY_FUNCTION_CODE:-false}"
CREATE_AUTH_TOKEN="${CREATE_AUTH_TOKEN:-false}"
REUSE_EXISTING_STREAMING="${REUSE_EXISTING_STREAMING:-true}"
USE_EXISTING_SPLUNK="${USE_EXISTING_SPLUNK:-false}"

REGION="${REGION:-}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"

PROJECT_PREFIX="${PROJECT_PREFIX:-oci-splunk}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

VCN_CIDR="${VCN_CIDR:-10.60.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.60.1.0/24}"

VCN_NAME="${VCN_NAME:-${PROJECT_PREFIX}-vcn}"
SUBNET_NAME="${SUBNET_NAME:-${PROJECT_PREFIX}-public-subnet}"
NSG_NAME="${NSG_NAME:-${PROJECT_PREFIX}-nsg}"
IGW_NAME="${IGW_NAME:-${PROJECT_PREFIX}-igw}"
RT_NAME="${RT_NAME:-${PROJECT_PREFIX}-rt}"

SPLUNK_INSTANCE_NAME="${SPLUNK_INSTANCE_NAME:-${PROJECT_PREFIX}-splunk}"
SPLUNK_SHAPE="${SPLUNK_SHAPE:-VM.Standard.E4.Flex}"
SPLUNK_OCPUS="${SPLUNK_OCPUS:-2}"
SPLUNK_MEMORY_GBS="${SPLUNK_MEMORY_GBS:-16}"
SPLUNK_BOOT_VOLUME_GBS="${SPLUNK_BOOT_VOLUME_GBS:-100}"
SPLUNK_IMAGE_OCID="${SPLUNK_IMAGE_OCID:-}"
SPLUNK_SSH_PUBLIC_KEY_PATH="${SPLUNK_SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-ChangeMe123!}"
ALLOW_INGRESS_CIDR="${ALLOW_INGRESS_CIDR:-}"
if [[ -z "${ALLOW_INGRESS_CIDR}" ]]; then
  DETECTED_PUBLIC_IP="$(detect_public_ip || true)"
  if [[ -n "${DETECTED_PUBLIC_IP}" ]]; then
    ALLOW_INGRESS_CIDR="${DETECTED_PUBLIC_IP}/32"
  fi
fi
if [[ -z "${ALLOW_INGRESS_CIDR}" ]]; then
  echo "ERROR: Unable to detect public IP. Set ALLOW_INGRESS_CIDR explicitly (for example x.x.x.x/32)." >&2
  exit 1
fi

STREAM_POOL_NAME="${STREAM_POOL_NAME:-${PROJECT_PREFIX}-pool}"
STREAM_NAME="${STREAM_NAME:-${PROJECT_PREFIX}-stream}"
STREAM_PARTITIONS="${STREAM_PARTITIONS:-1}"
STREAM_RETENTION_HOURS="${STREAM_RETENTION_HOURS:-24}"

SERVICE_CONNECTOR_STREAM_NAME="${SERVICE_CONNECTOR_STREAM_NAME:-${PROJECT_PREFIX}-logs-to-stream}"
SERVICE_CONNECTOR_FN_NAME="${SERVICE_CONNECTOR_FN_NAME:-${PROJECT_PREFIX}-logs-to-functions}"

LOG_GROUP_OCID="${LOG_GROUP_OCID:-}"
LOG_OCID="${LOG_OCID:-}"

KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-}"
TENANCY_NAME="${TENANCY_NAME:-}"
STREAMING_USER_NAME="${STREAMING_USER_NAME:-}"
STREAMING_USER_OCID="${STREAMING_USER_OCID:-}"
STREAMING_AUTH_TOKEN="${STREAMING_AUTH_TOKEN:-}"

SPLUNK_HEC_URL="${SPLUNK_HEC_URL:-https://splunk.example.com:8088/services/collector/event}"
SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN:-replace-with-hec-token}"
SPLUNK_HEC_INDEX="${SPLUNK_HEC_INDEX:-main}"
EXISTING_SPLUNK_WEB_URL="${EXISTING_SPLUNK_WEB_URL:-}"

FN_APP_NAME="${FN_APP_NAME:-${PROJECT_PREFIX}-fn-app}"
FN_NAME="${FN_NAME:-splunk-hec-forwarder}"
FN_IMAGE="${FN_IMAGE:-}"
FN_SUBNET_OCID="${FN_SUBNET_OCID:-}"
FUNCTION_OCID="${FUNCTION_OCID:-}"

STATE_FILE="${OUTPUT_DIR}/deployment-state.env"

# Track only resources created by this script so destroy can be safe.
CREATED_VCN="${CREATED_VCN:-false}"
CREATED_IGW="${CREATED_IGW:-false}"
CREATED_ROUTE_TABLE="${CREATED_ROUTE_TABLE:-false}"
CREATED_NSG="${CREATED_NSG:-false}"
CREATED_SUBNET="${CREATED_SUBNET:-false}"
CREATED_SPLUNK_INSTANCE="${CREATED_SPLUNK_INSTANCE:-false}"
CREATED_STREAM_POOL="${CREATED_STREAM_POOL:-false}"
CREATED_STREAM="${CREATED_STREAM:-false}"
CREATED_SERVICE_CONNECTOR_STREAM="${CREATED_SERVICE_CONNECTOR_STREAM:-false}"
CREATED_SERVICE_CONNECTOR_FN="${CREATED_SERVICE_CONNECTOR_FN:-false}"
CREATED_FN_APP="${CREATED_FN_APP:-false}"
CREATED_FUNCTION="${CREATED_FUNCTION:-false}"

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

json_val() {
  jq -r "$1"
}

save_state() {
  cat >"${STATE_FILE}" <<STATE
REGION=${REGION}
COMPARTMENT_OCID=${COMPARTMENT_OCID}
VCN_OCID=${VCN_OCID:-}
IGW_OCID=${IGW_OCID:-}
RT_OCID=${RT_OCID:-}
SUBNET_OCID=${SUBNET_OCID:-}
NSG_OCID=${NSG_OCID:-}
SPLUNK_INSTANCE_OCID=${SPLUNK_INSTANCE_OCID:-}
SPLUNK_INSTANCE_PUBLIC_IP=${SPLUNK_INSTANCE_PUBLIC_IP:-}
STREAM_POOL_OCID=${STREAM_POOL_OCID:-}
STREAM_OCID=${STREAM_OCID:-}
SERVICE_CONNECTOR_STREAM_OCID=${SERVICE_CONNECTOR_STREAM_OCID:-}
SERVICE_CONNECTOR_FN_OCID=${SERVICE_CONNECTOR_FN_OCID:-}
FN_APP_OCID=${FN_APP_OCID:-}
FUNCTION_OCID=${FUNCTION_OCID:-}
CREATED_VCN=${CREATED_VCN}
CREATED_IGW=${CREATED_IGW}
CREATED_ROUTE_TABLE=${CREATED_ROUTE_TABLE}
CREATED_NSG=${CREATED_NSG}
CREATED_SUBNET=${CREATED_SUBNET}
CREATED_SPLUNK_INSTANCE=${CREATED_SPLUNK_INSTANCE}
CREATED_STREAM_POOL=${CREATED_STREAM_POOL}
CREATED_STREAM=${CREATED_STREAM}
CREATED_SERVICE_CONNECTOR_STREAM=${CREATED_SERVICE_CONNECTOR_STREAM}
CREATED_SERVICE_CONNECTOR_FN=${CREATED_SERVICE_CONNECTOR_FN}
CREATED_FN_APP=${CREATED_FN_APP}
CREATED_FUNCTION=${CREATED_FUNCTION}
STATE
}

get_oracle_linux_8_image() {
  oci compute image list \
    --compartment-id "${COMPARTMENT_OCID}" \
    --operating-system "Oracle Linux" \
    --operating-system-version "8" \
    --shape "${SPLUNK_SHAPE}" \
    --all \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --query 'data[0].id' \
    --raw-output
}

create_network() {
  log "Creating VCN/Subnet/NSG for Splunk"

  VCN_OCID="$(oci network vcn create \
    --compartment-id "${COMPARTMENT_OCID}" \
    --cidr-block "${VCN_CIDR}" \
    --display-name "${VCN_NAME}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"
  CREATED_VCN="true"

  IGW_OCID="$(oci network ig create \
    --compartment-id "${COMPARTMENT_OCID}" \
    --vcn-id "${VCN_OCID}" \
    --display-name "${IGW_NAME}" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"
  CREATED_IGW="true"

  RT_OCID="$(oci network route-table create \
    --compartment-id "${COMPARTMENT_OCID}" \
    --vcn-id "${VCN_OCID}" \
    --display-name "${RT_NAME}" \
    --route-rules "[{\"networkEntityId\":\"${IGW_OCID}\",\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\"}]" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"
  CREATED_ROUTE_TABLE="true"

  NSG_OCID="$(oci network nsg create \
    --compartment-id "${COMPARTMENT_OCID}" \
    --vcn-id "${VCN_OCID}" \
    --display-name "${NSG_NAME}" \
    --query 'data.id' --raw-output)"
  CREATED_NSG="true"

  # SSH
  oci network nsg rules add \
    --nsg-id "${NSG_OCID}" \
    --security-rules "[{\"direction\":\"INGRESS\",\"protocol\":\"6\",\"source\":\"${ALLOW_INGRESS_CIDR}\",\"sourceType\":\"CIDR_BLOCK\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}}]" >/dev/null

  # Splunk Web
  oci network nsg rules add \
    --nsg-id "${NSG_OCID}" \
    --security-rules "[{\"direction\":\"INGRESS\",\"protocol\":\"6\",\"source\":\"${ALLOW_INGRESS_CIDR}\",\"sourceType\":\"CIDR_BLOCK\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":8000,\"max\":8000}}}]" >/dev/null

  # HEC
  oci network nsg rules add \
    --nsg-id "${NSG_OCID}" \
    --security-rules "[{\"direction\":\"INGRESS\",\"protocol\":\"6\",\"source\":\"${ALLOW_INGRESS_CIDR}\",\"sourceType\":\"CIDR_BLOCK\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":8088,\"max\":8088}}}]" >/dev/null

  SUBNET_OCID="$(oci network subnet create \
    --compartment-id "${COMPARTMENT_OCID}" \
    --vcn-id "${VCN_OCID}" \
    --cidr-block "${SUBNET_CIDR}" \
    --display-name "${SUBNET_NAME}" \
    --route-table-id "${RT_OCID}" \
    --prohibit-public-ip-on-vnic false \
    --security-list-ids '[]' \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)"
  CREATED_SUBNET="true"

  oci network subnet update \
    --subnet-id "${SUBNET_OCID}" \
    --nsg-ids "[\"${NSG_OCID}\"]" >/dev/null

  save_state
}

create_splunk_cloud_init() {
  local cloud_init_file="${OUTPUT_DIR}/splunk-cloud-init.yaml"
  cat >"${cloud_init_file}" <<CLOUD
#cloud-config
package_update: true
package_upgrade: false
runcmd:
  - dnf install -y wget tar curl
  - systemctl disable --now firewalld || true
  - wget -O /tmp/splunk-10.2.0-d749cb17ea65.x86_64.rpm "https://download.splunk.com/products/splunk/releases/10.2.0/linux/splunk-10.2.0-d749cb17ea65.x86_64.rpm"
  - dnf install -y /tmp/splunk-10.2.0-d749cb17ea65.x86_64.rpm
  - useradd --system --create-home --home-dir /opt/splunk --shell /sbin/nologin splunk || true
  - chown -R splunk:splunk /opt/splunk
  - mkdir -p /opt/splunk/etc/system/local
  - printf '[user_info]\nUSERNAME = admin\nPASSWORD = ${SPLUNK_ADMIN_PASSWORD}\n' >/opt/splunk/etc/system/local/user-seed.conf
  - chown splunk:splunk /opt/splunk/etc/system/local/user-seed.conf
  - sudo -u splunk /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt
  - /opt/splunk/bin/splunk enable boot-start -user splunk --accept-license --answer-yes
  - /bin/bash -lc 'set -euo pipefail; TOKEN="${SPLUNK_HEC_TOKEN}"; if [[ "\${TOKEN}" == "replace-with-hec-token" || "\${TOKEN}" == "TEMP_HEC_TOKEN_TO_REPLACE" ]]; then TOKEN=""; fi; sudo -u splunk /opt/splunk/bin/splunk http-event-collector enable -uri https://127.0.0.1:8089 -port 8088 -enable-ssl 0 -auth "admin:${SPLUNK_ADMIN_PASSWORD}" >/tmp/hec-enable.log 2>&1 || true; if [[ -z "\${TOKEN}" ]]; then sudo -u splunk /opt/splunk/bin/splunk http-event-collector create oci-kafka-hec -uri https://127.0.0.1:8089 -description "OCI Kafka HEC token" -index "${SPLUNK_HEC_INDEX}" -sourcetype "oci:log" -auth "admin:${SPLUNK_ADMIN_PASSWORD}" -disabled 0 >/tmp/hec-create.log 2>&1 || true; TOKEN="$(sed -n "/^\\[http:\\/\\/oci-kafka-hec\\]/,/^\\[/ s/^token = //p" /opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf | head -n1 | tr -d "[:space:]")"; fi; if [[ -z "\${TOKEN}" ]]; then TOKEN="$(cat /proc/sys/kernel/random/uuid)"; fi; mkdir -p /opt/splunk/etc/apps/splunk_httpinput/local; printf "[http]\ndisabled = 0\nenableSSL = 0\nport = 8088\n\n[http://oci-kafka-hec]\ndisabled = 0\ntoken = %s\nindex = ${SPLUNK_HEC_INDEX}\nsourcetype = oci:log\n" "\${TOKEN}" >/opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf; chown -R splunk:splunk /opt/splunk/etc/apps/splunk_httpinput/local; mkdir -p /opt/oci-splunk; printf "SPLUNK_HEC_TOKEN=%s\nSPLUNK_HEC_URL=http://127.0.0.1:8088/services/collector/event\n" "\${TOKEN}" >/opt/oci-splunk/runtime.env; chmod 600 /opt/oci-splunk/runtime.env'
  - sudo -u splunk /opt/splunk/bin/splunk restart --answer-yes --no-prompt
CLOUD
  echo "${cloud_init_file}"
}

create_splunk_instance() {
  [[ -f "${SPLUNK_SSH_PUBLIC_KEY_PATH}" ]] || fail "SSH public key not found: ${SPLUNK_SSH_PUBLIC_KEY_PATH}"

  if [[ -z "${SUBNET_OCID:-}" ]]; then
    fail "SUBNET_OCID is missing. Either set SUBNET_OCID in .env or run network creation first."
  fi

  if [[ -z "${SPLUNK_IMAGE_OCID}" ]]; then
    log "Resolving latest Oracle Linux 8 image OCID for shape ${SPLUNK_SHAPE}"
    SPLUNK_IMAGE_OCID="$(get_oracle_linux_8_image)"
    [[ -n "${SPLUNK_IMAGE_OCID}" && "${SPLUNK_IMAGE_OCID}" != "null" ]] || fail "Could not resolve Oracle Linux 8 image"
  fi

  local cloud_init_file
  cloud_init_file="$(create_splunk_cloud_init)"

  log "Launching Splunk compute instance"
  SPLUNK_INSTANCE_OCID="$(oci compute instance launch \
    --compartment-id "${COMPARTMENT_OCID}" \
    --availability-domain "$(oci iam availability-domain list --compartment-id "${COMPARTMENT_OCID}" --query 'data[0].name' --raw-output)" \
    --display-name "${SPLUNK_INSTANCE_NAME}" \
    --shape "${SPLUNK_SHAPE}" \
    --shape-config "{\"ocpus\": ${SPLUNK_OCPUS}, \"memoryInGBs\": ${SPLUNK_MEMORY_GBS}}" \
    --image-id "${SPLUNK_IMAGE_OCID}" \
    --subnet-id "${SUBNET_OCID}" \
    --metadata "{\"ssh_authorized_keys\":\"$(cat "${SPLUNK_SSH_PUBLIC_KEY_PATH}")\",\"user_data\":\"$(base64 < "${cloud_init_file}" | tr -d '\n')\"}" \
    --boot-volume-size-in-gbs "${SPLUNK_BOOT_VOLUME_GBS}" \
    --wait-for-state RUNNING \
    --query 'data.id' --raw-output)"
  CREATED_SPLUNK_INSTANCE="true"

  local vnic_ocid
  vnic_ocid="$(oci compute instance list-vnics --instance-id "${SPLUNK_INSTANCE_OCID}" --query 'data[0].id' --raw-output)"
  SPLUNK_INSTANCE_PUBLIC_IP="$(oci network vnic get --vnic-id "${vnic_ocid}" --query 'data."public-ip"' --raw-output)"

  log "Splunk instance created: ${SPLUNK_INSTANCE_OCID}"
  log "Splunk web URL: http://${SPLUNK_INSTANCE_PUBLIC_IP}:8000"
  save_state
}

discover_managed_hec_token() {
  if [[ "${CREATE_SPLUNK_INSTANCE}" != "true" || "${USE_EXISTING_SPLUNK}" == "true" ]]; then
    return
  fi
  [[ -n "${SPLUNK_INSTANCE_PUBLIC_IP:-}" ]] || return

  local ssh_key_path="${SELECTED_SSH_PRIVATE_KEY_PATH:-${SPLUNK_SSH_PUBLIC_KEY_PATH%.pub}}"
  [[ -n "${ssh_key_path}" && -f "${ssh_key_path}" ]] || return

  local token=""
  local attempt
  for attempt in $(seq 1 20); do
    token="$(
      ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -i "${ssh_key_path}" "opc@${SPLUNK_INSTANCE_PUBLIC_IP}" \
        "sudo awk -F= '/^SPLUNK_HEC_TOKEN=/{gsub(/^[ \\t\\\"]+|[ \\t\\\"]+$/, \"\", \$2); print \$2}' /opt/oci-splunk/runtime.env 2>/dev/null | head -n1" 2>/dev/null || true
    )"
    if [[ -n "${token}" ]]; then
      SPLUNK_HEC_TOKEN="${token}"
      if [[ "${SPLUNK_HEC_URL}" == "https://splunk.example.com:8088/services/collector/event" || "${SPLUNK_HEC_URL}" == "http://127.0.0.1:8088/services/collector/event" ]]; then
        SPLUNK_HEC_URL="http://${SPLUNK_INSTANCE_PUBLIC_IP}:8088/services/collector/event"
      fi
      printf 'SPLUNK_HEC_TOKEN=%s\nSPLUNK_HEC_URL=%s\n' "${SPLUNK_HEC_TOKEN}" "${SPLUNK_HEC_URL}" >"${OUTPUT_DIR}/generated-hec-token.env"
      log "Generated/fetched Splunk HEC token and wrote ${OUTPUT_DIR}/generated-hec-token.env"
      return
    fi
    sleep 10
  done
  log "Could not fetch generated HEC token from managed Splunk yet; continuing."
}

create_streaming() {
  if [[ -z "${STREAM_POOL_OCID:-}" ]]; then
    log "Creating OCI Streaming pool ${STREAM_POOL_NAME}"
    STREAM_POOL_OCID="$(oci streaming admin stream-pool create \
      --compartment-id "${COMPARTMENT_OCID}" \
      --name "${STREAM_POOL_NAME}" \
      --wait-for-state ACTIVE \
      --query 'data.id' --raw-output)"
    CREATED_STREAM_POOL="true"
  fi

  if [[ -z "${STREAM_OCID:-}" ]]; then
    log "Creating OCI stream ${STREAM_NAME}"
    STREAM_OCID="$(oci streaming admin stream create \
      --name "${STREAM_NAME}" \
      --partitions "${STREAM_PARTITIONS}" \
      --retention-in-hours "${STREAM_RETENTION_HOURS}" \
      --stream-pool-id "${STREAM_POOL_OCID}" \
      --wait-for-state ACTIVE \
      --query 'data.id' --raw-output)"
    CREATED_STREAM="true"
  fi

  save_state
}

discover_existing_streaming() {
  if [[ "${REUSE_EXISTING_STREAMING}" != "true" ]]; then
    return
  fi

  if [[ -z "${STREAM_OCID:-}" ]]; then
    STREAM_OCID="$(
      oci streaming admin stream list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --all \
        --output json | jq -r --arg stream_name "${STREAM_NAME}" '.data[] | select(.name == $stream_name and ."lifecycle-state" == "ACTIVE") | .id' | head -n1
    )"
  fi

  if [[ -n "${STREAM_OCID:-}" && -z "${STREAM_POOL_OCID:-}" ]]; then
    STREAM_POOL_OCID="$(oci streaming admin stream get --stream-id "${STREAM_OCID}" --output json | jq -r '.data["stream-pool-id"]')"
  fi

  if [[ -n "${STREAM_OCID:-}" ]]; then
    CREATED_STREAM="false"
    CREATED_STREAM_POOL="false"
    log "Reusing existing stream ${STREAM_NAME}: ${STREAM_OCID}"
    log "Reusing existing stream pool: ${STREAM_POOL_OCID}"
    save_state
    return
  fi

  if [[ -z "${STREAM_POOL_OCID:-}" ]]; then
    STREAM_POOL_OCID="$(
      oci streaming admin stream-pool list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --all \
        --output json | jq -r --arg pool_name "${STREAM_POOL_NAME}" '.data[] | select(.name == $pool_name and ."lifecycle-state" == "ACTIVE") | .id' | head -n1
    )"
    if [[ -n "${STREAM_POOL_OCID}" ]]; then
      CREATED_STREAM_POOL="false"
      log "Reusing existing stream pool ${STREAM_POOL_NAME}: ${STREAM_POOL_OCID}"
      save_state
    fi
  fi
}

create_connector_logs_to_stream() {
  [[ -n "${LOG_GROUP_OCID}" ]] || fail "LOG_GROUP_OCID is required for Logs -> Stream connector"
  [[ -n "${LOG_OCID}" ]] || fail "LOG_OCID is required for Logs -> Stream connector"
  [[ -n "${STREAM_OCID:-}" ]] || fail "STREAM_OCID is missing"

  local source_json target_json
  source_json="${OUTPUT_DIR}/source-logging.json"
  target_json="${OUTPUT_DIR}/target-streaming.json"

  cat >"${source_json}" <<JSON
{
  "kind": "logging",
  "logSources": [
    {
      "compartmentId": "${COMPARTMENT_OCID}",
      "logGroupId": "${LOG_GROUP_OCID}",
      "logId": "${LOG_OCID}"
    }
  ]
}
JSON

  cat >"${target_json}" <<JSON
{
  "kind": "streaming",
  "streamId": "${STREAM_OCID}"
}
JSON

  SERVICE_CONNECTOR_STREAM_OCID="$(oci sch service-connector create \
    --compartment-id "${COMPARTMENT_OCID}" \
    --display-name "${SERVICE_CONNECTOR_STREAM_NAME}" \
    --source "file://${source_json}" \
    --target "file://${target_json}" \
    --wait-for-state ACTIVE \
    --query 'data.id' --raw-output)"
  CREATED_SERVICE_CONNECTOR_STREAM="true"

  save_state
}

maybe_create_auth_token() {
  if [[ "${CREATE_AUTH_TOKEN}" != "true" ]]; then
    return
  fi

  [[ -n "${STREAMING_USER_OCID}" ]] || fail "STREAMING_USER_OCID is required when CREATE_AUTH_TOKEN=true"

  STREAMING_AUTH_TOKEN="$(oci iam auth-token create \
    --user-id "${STREAMING_USER_OCID}" \
    --description "${PROJECT_PREFIX}-${TIMESTAMP}" \
    --query 'data.token' --raw-output)"

  log "Generated auth token for Kafka SASL. Store it securely now; OCI only displays it once."
  echo "STREAMING_AUTH_TOKEN=${STREAMING_AUTH_TOKEN}" > "${OUTPUT_DIR}/generated-auth-token.env"
}

create_kafka_connect_files() {
  [[ -n "${STREAM_POOL_OCID:-}" ]] || fail "STREAM_POOL_OCID is missing"
  [[ -n "${STREAM_OCID:-}" ]] || fail "STREAM_OCID is missing"
  [[ -n "${TENANCY_NAME}" ]] || fail "TENANCY_NAME is required for Kafka SASL username"
  [[ -n "${STREAMING_USER_NAME}" ]] || fail "STREAMING_USER_NAME is required for Kafka SASL username"
  [[ -n "${STREAMING_AUTH_TOKEN}" ]] || fail "STREAMING_AUTH_TOKEN is required for Kafka SASL password"

  if [[ -z "${KAFKA_BOOTSTRAP_SERVERS}" ]]; then
    KAFKA_BOOTSTRAP_SERVERS="cell-1.streaming.${REGION}.oci.oraclecloud.com:9092"
  fi

  local sasl_username splunk_hec_uri
  sasl_username="${TENANCY_NAME}/${STREAMING_USER_NAME}/${STREAM_POOL_OCID}"
  splunk_hec_uri="$(hec_base_uri_from_url "${SPLUNK_HEC_URL}")"
  [[ -n "${splunk_hec_uri}" ]] || splunk_hec_uri="${SPLUNK_HEC_URL}"

  cat >"${OUTPUT_DIR}/connect-distributed.properties" <<CFG
bootstrap.servers=${KAFKA_BOOTSTRAP_SERVERS}
group.id=splunk-kafka-connect
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.storage.StringConverter
offset.storage.topic=connect-offsets
config.storage.topic=connect-configs
status.storage.topic=connect-status
offset.storage.replication.factor=1
config.storage.replication.factor=1
status.storage.replication.factor=1
plugin.path=/usr/share/java,/usr/share/confluent-hub-components
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${sasl_username}" password="${STREAMING_AUTH_TOKEN}";
consumer.security.protocol=SASL_SSL
consumer.sasl.mechanism=PLAIN
consumer.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${sasl_username}" password="${STREAMING_AUTH_TOKEN}";
producer.security.protocol=SASL_SSL
producer.sasl.mechanism=PLAIN
producer.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${sasl_username}" password="${STREAMING_AUTH_TOKEN}";
CFG

  cat >"${OUTPUT_DIR}/splunk-sink-connector.json" <<JSON
{
  "name": "oci-stream-to-splunk",
  "config": {
    "connector.class": "com.splunk.kafka.connect.SplunkSinkConnector",
    "tasks.max": "1",
    "topics": "${STREAM_NAME}",
    "splunk.hec.uri": "${splunk_hec_uri}",
    "splunk.hec.token": "${SPLUNK_HEC_TOKEN}",
    "splunk.indexes": "${SPLUNK_HEC_INDEX}",
    "splunk.hec.ssl.validate.certs": "false",
    "splunk.hec.raw": "false",
    "splunk.hec.ack.enabled": "false",
    "splunk.hec.max.outstanding.events": "10000",
    "value.converter": "org.apache.kafka.connect.storage.StringConverter",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}
JSON

  cat >"${OUTPUT_DIR}/kafka-connect-runbook.txt" <<TXT
1) Install Apache Kafka Connect (or Confluent Platform) and the Splunk Sink Connector plugin.
2) Place connect-distributed.properties in your Kafka Connect config dir.
3) Start Kafka Connect distributed worker:
   connect-distributed.sh connect-distributed.properties
4) Create connector:
   curl -X POST http://<connect-host>:8083/connectors \\
     -H 'Content-Type: application/json' \\
     --data @splunk-sink-connector.json
TXT

  log "Generated Kafka Connect files under ${OUTPUT_DIR}"
}

configure_kafka_connect_on_managed_splunk() {
  if [[ "${MODE}" != "kafka" && "${MODE}" != "both" ]]; then
    return
  fi
  if [[ "${AUTO_CONFIGURE_KAFKA_CONNECT_ON_VM}" != "true" ]]; then
    return
  fi
  if [[ "${CREATE_SPLUNK_INSTANCE}" != "true" || "${USE_EXISTING_SPLUNK}" == "true" ]]; then
    return
  fi
  [[ -n "${SPLUNK_INSTANCE_PUBLIC_IP:-}" ]] || fail "SPLUNK_INSTANCE_PUBLIC_IP is missing for Kafka Connect auto-configuration"
  [[ -n "${STREAM_POOL_OCID:-}" ]] || fail "STREAM_POOL_OCID is missing for Kafka Connect auto-configuration"
  [[ -n "${STREAM_OCID:-}" ]] || fail "STREAM_OCID is missing for Kafka Connect auto-configuration"
  [[ -n "${TENANCY_NAME}" ]] || fail "TENANCY_NAME is required for Kafka Connect auto-configuration"
  [[ -n "${STREAMING_USER_NAME}" ]] || fail "STREAMING_USER_NAME is required for Kafka Connect auto-configuration"
  [[ -n "${STREAMING_AUTH_TOKEN}" ]] || fail "STREAMING_AUTH_TOKEN is required for Kafka Connect auto-configuration"
  [[ -n "${SPLUNK_HEC_TOKEN}" ]] || fail "SPLUNK_HEC_TOKEN is required for Kafka Connect auto-configuration"

  local ssh_key_path="${SELECTED_SSH_PRIVATE_KEY_PATH:-${SPLUNK_SSH_PUBLIC_KEY_PATH%.pub}}"
  [[ -n "${ssh_key_path}" && -f "${ssh_key_path}" ]] || fail "SSH private key not found for managed Splunk VM"

  if [[ -z "${KAFKA_BOOTSTRAP_SERVERS}" ]]; then
    KAFKA_BOOTSTRAP_SERVERS="cell-1.streaming.${REGION}.oci.oraclecloud.com:9092"
  fi

  local splunk_hec_uri
  splunk_hec_uri="$(hec_base_uri_from_url "${SPLUNK_HEC_URL}")"
  [[ -n "${splunk_hec_uri}" ]] || splunk_hec_uri="${SPLUNK_HEC_URL}"

  log "Configuring Kafka Connect + Splunk sink connector on managed Splunk VM"

  local remote_cmd
  remote_cmd="$(cat <<EOF
set -euo pipefail
sudo bash -lc '
set -euo pipefail
KAFKA_VERSION=3.9.1
KAFKA_SCALA=2.13
KAFKA_HOME=/opt/kafka
KAFKA_ARCHIVE=/tmp/kafka_\${KAFKA_SCALA}-\${KAFKA_VERSION}.tgz
PLUGIN_DIR=\${KAFKA_HOME}/plugins
SPLUNK_CONNECTOR_JAR=\${PLUGIN_DIR}/splunk-kafka-connect-v2.2.4.jar
SPLUNK_CONNECTOR_URL=https://github.com/splunk/kafka-connect-splunk/releases/download/v2.2.4/splunk-kafka-connect-v2.2.4.jar
SASL_USERNAME="${TENANCY_NAME}/${STREAMING_USER_NAME}/${STREAM_POOL_OCID}"
BOOTSTRAP="${KAFKA_BOOTSTRAP_SERVERS}"
STREAMING_AUTH_TOKEN="${STREAMING_AUTH_TOKEN}"
STREAM_NAME="${STREAM_NAME}"
SPLUNK_HEC_URI="${splunk_hec_uri}"
SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN}"
SPLUNK_HEC_INDEX="${SPLUNK_HEC_INDEX}"

dnf install -y wget tar gzip java-17-openjdk-headless curl >/dev/null

if [[ ! -x "\${KAFKA_HOME}/bin/connect-standalone.sh" ]]; then
  wget -q -O "\${KAFKA_ARCHIVE}" "https://downloads.apache.org/kafka/\${KAFKA_VERSION}/kafka_\${KAFKA_SCALA}-\${KAFKA_VERSION}.tgz"
  tar -xzf "\${KAFKA_ARCHIVE}" -C /opt
  rm -rf "\${KAFKA_HOME}"
  mv "/opt/kafka_\${KAFKA_SCALA}-\${KAFKA_VERSION}" "\${KAFKA_HOME}"
fi

mkdir -p "\${PLUGIN_DIR}"
wget -q -O "\${SPLUNK_CONNECTOR_JAR}" "\${SPLUNK_CONNECTOR_URL}"

cat >"\${KAFKA_HOME}/config/connect-standalone-oci.properties" <<CONFIG
bootstrap.servers=\${BOOTSTRAP}
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.storage.StringConverter
offset.storage.file.filename=/var/lib/kafka-connect-standalone.offsets
plugin.path=\${PLUGIN_DIR}
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="\${SASL_USERNAME}" password="\${STREAMING_AUTH_TOKEN}";
producer.security.protocol=SASL_SSL
producer.sasl.mechanism=PLAIN
producer.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="\${SASL_USERNAME}" password="\${STREAMING_AUTH_TOKEN}";
consumer.security.protocol=SASL_SSL
consumer.sasl.mechanism=PLAIN
consumer.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="\${SASL_USERNAME}" password="\${STREAMING_AUTH_TOKEN}";
CONFIG

cat >"\${KAFKA_HOME}/config/splunk-sink-connector.properties" <<CONNECTOR
name=kafka-connect-splunk
connector.class=com.splunk.kafka.connect.SplunkSinkConnector
tasks.max=1
topics=\${STREAM_NAME}
splunk.hec.uri=\${SPLUNK_HEC_URI}
splunk.hec.token=\${SPLUNK_HEC_TOKEN}
splunk.indexes=\${SPLUNK_HEC_INDEX}
splunk.hec.ssl.validate.certs=false
splunk.hec.ack.enabled=false
splunk.hec.max.outstanding.events=10000
value.converter=org.apache.kafka.connect.storage.StringConverter
key.converter=org.apache.kafka.connect.storage.StringConverter
errors.tolerance=all
errors.log.enable=true
errors.log.include.messages=true
CONNECTOR

cat >/etc/systemd/system/kafka-connect.service <<SERVICE
[Unit]
Description=Apache Kafka Connect (Standalone)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=KAFKA_HEAP_OPTS=-Xms512m -Xmx2g
ExecStart=\${KAFKA_HOME}/bin/connect-standalone.sh \${KAFKA_HOME}/config/connect-standalone-oci.properties \${KAFKA_HOME}/config/splunk-sink-connector.properties
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable kafka-connect >/dev/null
systemctl restart kafka-connect
sleep 5
systemctl is-active kafka-connect >/dev/null
'
EOF
)"

  ssh -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=no -i "${ssh_key_path}" \
    "opc@${SPLUNK_INSTANCE_PUBLIC_IP}" "${remote_cmd}"

  log "Kafka Connect service configured and started on ${SPLUNK_INSTANCE_PUBLIC_IP}"
}

write_function_template() {
  local fn_dir="${SCRIPT_DIR}/functions/${FN_NAME}"
  mkdir -p "${fn_dir}"

  cat >"${fn_dir}/func.py" <<'PY'
import io
import json
import os
import requests


def handler(ctx, data: io.BytesIO = None):
    hec_url = os.getenv("SPLUNK_HEC_URL")
    hec_token = os.getenv("SPLUNK_HEC_TOKEN")
    hec_index = os.getenv("SPLUNK_HEC_INDEX", "main")

    if not hec_url or not hec_token:
        raise RuntimeError("SPLUNK_HEC_URL and SPLUNK_HEC_TOKEN must be configured")

    body = data.getvalue().decode("utf-8") if data else "{}"
    payload = json.loads(body)

    headers = {
        "Authorization": f"Splunk {hec_token}",
        "Content-Type": "application/json"
    }

    event_body = {
        "index": hec_index,
        "source": "oci-functions",
        "sourcetype": "oci:log",
        "event": payload
    }

    resp = requests.post(hec_url, headers=headers, data=json.dumps(event_body), timeout=15)
    resp.raise_for_status()
    return {"status": "ok", "code": resp.status_code}
PY

  cat >"${fn_dir}/requirements.txt" <<'REQ'
requests==2.32.3
REQ

  cat >"${fn_dir}/func.yaml" <<YAML
schema_version: 20180708
name: ${FN_NAME}
version: 0.0.1
runtime: python
build_image: fnproject/python:3.11-dev
run_image: fnproject/python:3.11
entrypoint: /python/bin/fdk /function/func.py handler
memory: 256
YAML

  cat >"${fn_dir}/README.md" <<TXT
# ${FN_NAME}

Deploy with:

fn -v deploy --app ${FN_APP_NAME}

Set runtime config:

oci fn function config update \\
  --function-id <FUNCTION_OCID> \\
  --config '{"SPLUNK_HEC_URL":"${SPLUNK_HEC_URL}","SPLUNK_HEC_TOKEN":"${SPLUNK_HEC_TOKEN}","SPLUNK_HEC_INDEX":"${SPLUNK_HEC_INDEX}"}'
TXT

  log "Generated OCI Function template at ${fn_dir}"
}

create_function_app_and_optionally_deploy() {
  if [[ -z "${FN_SUBNET_OCID}" ]]; then
    FN_SUBNET_OCID="${SUBNET_OCID:-}"
  fi
  [[ -n "${FN_SUBNET_OCID}" ]] || fail "FN_SUBNET_OCID is required for creating function app"

  if [[ "${CREATE_FN_APP}" == "true" ]]; then
    FN_APP_OCID="$(oci fn application create \
      --compartment-id "${COMPARTMENT_OCID}" \
      --display-name "${FN_APP_NAME}" \
      --subnet-ids "[\"${FN_SUBNET_OCID}\"]" \
      --query 'data.id' --raw-output)"
    CREATED_FN_APP="true"
  fi

  write_function_template

  if [[ "${DEPLOY_FUNCTION_CODE}" == "true" ]]; then
    need_cmd fn
    [[ -n "${FN_IMAGE}" ]] || fail "Set FN_IMAGE (OCIR image path) when DEPLOY_FUNCTION_CODE=true"
    (
      cd "${SCRIPT_DIR}/functions/${FN_NAME}"
      fn -v deploy --app "${FN_APP_NAME}" --image "${FN_IMAGE}"
    )

    if [[ -n "${FN_APP_OCID:-}" ]]; then
      FUNCTION_OCID="$(oci fn function list --application-id "${FN_APP_OCID}" --query "data[?display-name=='${FN_NAME}'][0].id" --raw-output)"
      if [[ -n "${FUNCTION_OCID}" && "${FUNCTION_OCID}" != "null" ]]; then
        CREATED_FUNCTION="true"
      fi
    fi
  fi

  save_state
}

create_connector_logs_to_functions() {
  [[ -n "${LOG_GROUP_OCID}" ]] || fail "LOG_GROUP_OCID is required for Logs -> Functions connector"
  [[ -n "${LOG_OCID}" ]] || fail "LOG_OCID is required for Logs -> Functions connector"
  [[ -n "${FUNCTION_OCID}" ]] || fail "FUNCTION_OCID is required for Logs -> Functions connector"

  local source_json target_json
  source_json="${OUTPUT_DIR}/source-logging-fn.json"
  target_json="${OUTPUT_DIR}/target-functions.json"

  cat >"${source_json}" <<JSON
{
  "kind": "logging",
  "logSources": [
    {
      "compartmentId": "${COMPARTMENT_OCID}",
      "logGroupId": "${LOG_GROUP_OCID}",
      "logId": "${LOG_OCID}"
    }
  ]
}
JSON

  cat >"${target_json}" <<JSON
{
  "kind": "functions",
  "functionId": "${FUNCTION_OCID}"
}
JSON

  SERVICE_CONNECTOR_FN_OCID="$(oci sch service-connector create \
    --compartment-id "${COMPARTMENT_OCID}" \
    --display-name "${SERVICE_CONNECTOR_FN_NAME}" \
    --source "file://${source_json}" \
    --target "file://${target_json}" \
    --wait-for-state ACTIVE \
    --query 'data.id' --raw-output)"
  CREATED_SERVICE_CONNECTOR_FN="true"

  save_state
}

print_summary() {
  cat <<SUMMARY

Deployment complete.

State file: ${STATE_FILE}

Resources:
- VCN: ${VCN_OCID:-not-created}
- Subnet: ${SUBNET_OCID:-not-created}
- Splunk Instance: ${SPLUNK_INSTANCE_OCID:-not-created}
- Splunk Public IP: ${SPLUNK_INSTANCE_PUBLIC_IP:-not-created}
- Stream Pool: ${STREAM_POOL_OCID:-not-created}
- Stream: ${STREAM_OCID:-not-created}
- Service Connector (Logs->Stream): ${SERVICE_CONNECTOR_STREAM_OCID:-not-created}
- Function App: ${FN_APP_OCID:-not-created}
- Function: ${FUNCTION_OCID:-not-created}
- Service Connector (Logs->Functions): ${SERVICE_CONNECTOR_FN_OCID:-not-created}

Generated files:
- ${OUTPUT_DIR}/splunk-cloud-init.yaml
- ${OUTPUT_DIR}/connect-distributed.properties (if Kafka mode)
- ${OUTPUT_DIR}/splunk-sink-connector.json (if Kafka mode)
- ${SCRIPT_DIR}/functions/${FN_NAME} (if Functions mode)

Connection:
- Splunk Web URL: ${EXISTING_SPLUNK_WEB_URL:-http://${SPLUNK_INSTANCE_PUBLIC_IP:-unknown}:8000}
- Splunk HEC URL: ${SPLUNK_HEC_URL}
- Splunk HEC Token: ${SPLUNK_HEC_TOKEN}
- Splunk Username: admin
- Splunk Password: ${SPLUNK_ADMIN_PASSWORD}
- SSH Public Key: ${SPLUNK_SSH_PUBLIC_KEY_PATH}
- SSH Private Key: ${SELECTED_SSH_PRIVATE_KEY_PATH:-${SPLUNK_SSH_PUBLIC_KEY_PATH%.pub}}
SUMMARY
}

verify_deployment() {
  log "Running post-deploy verification"

  if [[ -n "${SERVICE_CONNECTOR_STREAM_OCID:-}" ]]; then
    local sc_state
    sc_state="$(oci sch service-connector get --service-connector-id "${SERVICE_CONNECTOR_STREAM_OCID}" --query 'data."lifecycle-state"' --raw-output)"
    [[ "${sc_state}" == "ACTIVE" ]] || fail "Service connector is not ACTIVE (${sc_state})"
  fi

  if [[ -n "${STREAM_OCID:-}" ]]; then
    local stream_state
    stream_state="$(oci streaming admin stream get --stream-id "${STREAM_OCID}" --query 'data."lifecycle-state"' --raw-output)"
    [[ "${stream_state}" == "ACTIVE" ]] || fail "Stream is not ACTIVE (${stream_state})"
  fi

  if [[ -n "${SPLUNK_HEC_URL}" ]]; then
    local hec_health_url hec_resp hec_code
    hec_health_url="$(hec_health_url_from_url "${SPLUNK_HEC_URL}")"
    if ! curl -fsS -m 8 "${hec_health_url}" >/dev/null; then
      fail "Splunk HEC health endpoint is not reachable: ${hec_health_url}"
    fi
    if [[ -n "${SPLUNK_HEC_TOKEN}" && "${SPLUNK_HEC_TOKEN}" != "replace-with-hec-token" && "${SPLUNK_HEC_TOKEN}" != "TEMP_HEC_TOKEN_TO_REPLACE" ]]; then
      hec_resp="$(curl -sS -m 10 -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" -H "Content-Type: application/json" \
        -d "{\"event\":\"oci-splunk-post-deploy-test\",\"source\":\"deploy_oci_splunk.sh\"}" \
        "${SPLUNK_HEC_URL}")"
      hec_code="$(jq -r '.code // ""' <<<"${hec_resp}")"
      [[ "${hec_code}" == "0" ]] || fail "HEC ingest test failed. Response: ${hec_resp}"
    fi
  fi

  if [[ "${MODE}" == "kafka" || "${MODE}" == "both" ]]; then
    if [[ "${AUTO_CONFIGURE_KAFKA_CONNECT_ON_VM}" == "true" && "${CREATE_SPLUNK_INSTANCE}" == "true" && "${USE_EXISTING_SPLUNK}" != "true" ]]; then
      local ssh_key_path="${SELECTED_SSH_PRIVATE_KEY_PATH:-${SPLUNK_SSH_PUBLIC_KEY_PATH%.pub}}"
      [[ -f "${ssh_key_path}" ]] || fail "SSH private key missing for kafka-connect verification: ${ssh_key_path}"
      ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "${ssh_key_path}" "opc@${SPLUNK_INSTANCE_PUBLIC_IP}" \
        "sudo systemctl is-active kafka-connect >/dev/null" || fail "kafka-connect service is not active on managed Splunk VM"
    fi
  fi
}

main() {
  need_cmd oci
  need_cmd jq
  need_cmd base64
  prepare_ssh_key_material

  [[ -n "${REGION}" ]] || fail "REGION is required. Set it in .env or ~/.oci/config (${OCI_PROFILE})."
  [[ -n "${COMPARTMENT_OCID}" ]] || fail "COMPARTMENT_OCID is required. Set it in .env or ~/.oci/config tenancy."

  if [[ "${USE_EXISTING_SPLUNK}" == "true" ]]; then
    CREATE_SPLUNK_INSTANCE="false"
    [[ -n "${SPLUNK_HEC_URL}" ]] || fail "SPLUNK_HEC_URL is required when USE_EXISTING_SPLUNK=true"
    [[ -n "${SPLUNK_HEC_TOKEN}" ]] || fail "SPLUNK_HEC_TOKEN is required when USE_EXISTING_SPLUNK=true"
    log "USE_EXISTING_SPLUNK=true, skipping managed Splunk VM creation"
  fi

  log "Starting deployment with MODE=${MODE}"

  if [[ "${CREATE_SPLUNK_INSTANCE}" == "true" ]]; then
    create_network
    create_splunk_instance
    discover_managed_hec_token
  elif [[ -n "${SUBNET_OCID:-}" ]]; then
    log "Skipping Splunk instance creation (CREATE_SPLUNK_INSTANCE=false), using provided SUBNET_OCID=${SUBNET_OCID}"
  fi

  if [[ "${CREATE_STREAMING}" == "true" ]]; then
    discover_existing_streaming
    create_streaming
  fi

  if [[ "${MODE}" == "kafka" || "${MODE}" == "both" ]]; then
    if [[ "${CREATE_CONNECTOR_LOGS_TO_STREAM}" == "true" ]]; then
      create_connector_logs_to_stream
    fi
    maybe_create_auth_token
    if [[ "${CREATE_KAFKA_CONNECT_FILES}" == "true" ]]; then
      create_kafka_connect_files
    fi
    configure_kafka_connect_on_managed_splunk
  fi

  if [[ "${MODE}" == "functions" || "${MODE}" == "both" ]]; then
    create_function_app_and_optionally_deploy
    if [[ "${CREATE_CONNECTOR_LOGS_TO_FUNCTIONS}" == "true" ]]; then
      create_connector_logs_to_functions
    fi
  fi

  verify_deployment
  print_summary
}

main "$@"
