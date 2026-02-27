#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ACTION="${1:-apply}" # apply | plan | destroy
OCI_PROFILE="${OCI_PROFILE:-${TF_VAR_oci_profile:-DEFAULT}}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-${TF_VAR_oci_config_file:-$HOME/.oci/config}}"
TFVARS_FILE="${TFVARS_FILE:-}"
AUTO_VARS_FILE="${SCRIPT_DIR}/autodetected.auto.tfvars"
STREAM_REUSE_VARS_FILE="${SCRIPT_DIR}/autodetected_stream_reuse.auto.tfvars"
REUSE_EXISTING_STREAMING="${REUSE_EXISTING_STREAMING:-true}"
DEFAULT_COMPARTMENT_OCID="${DEFAULT_COMPARTMENT_OCID:-}"
SSH_KEY_SELECTION="${SSH_KEY_SELECTION:-}"
SPLUNK_SSH_PUBLIC_KEY_PATH="${SPLUNK_SSH_PUBLIC_KEY_PATH:-}"
SELECTED_SSH_PRIVATE_KEY_PATH="${SELECTED_SSH_PRIVATE_KEY_PATH:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

normalize_bool() {
  local raw="${1:-false}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  case "${raw}" in
    1|true|yes|y|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

cfg_val() {
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

check_iam_policy_coverage() {
  local target_compartment="$1"
  local action="$2"

  # IAM preflight applies before plan/apply. Destroy uses existing state and can continue.
  if [[ "${action}" == "destroy" ]]; then
    return 0
  fi

  command -v oci >/dev/null 2>&1 || {
    echo "WARN: OCI CLI not found; skipping IAM preflight."
    return 0
  }
  need_cmd jq

  local preflight_user_ocid preflight_tenancy_ocid
  preflight_user_ocid="$(tfvars_val user_ocid "${TFVARS_FILE}" || true)"
  preflight_tenancy_ocid="$(tfvars_val tenancy_ocid "${TFVARS_FILE}" || true)"
  [[ -z "${preflight_user_ocid}" ]] && preflight_user_ocid="${USER_OCID}"
  [[ -z "${preflight_tenancy_ocid}" ]] && preflight_tenancy_ocid="${TENANCY_OCID}"

  if [[ -z "${preflight_user_ocid}" || -z "${preflight_tenancy_ocid}" || -z "${target_compartment}" ]]; then
    echo "WARN: Missing tenancy/user/compartment values for IAM preflight; skipping."
    return 0
  fi

  local use_existing_network use_existing_splunk create_logs_to_stream_connector
  local existing_stream_pool_id existing_stream_id
  use_existing_network="$(normalize_bool "$(tfvars_val use_existing_network "${TFVARS_FILE}" || true)")"
  use_existing_splunk="$(normalize_bool "$(tfvars_val use_existing_splunk "${TFVARS_FILE}" || true)")"
  create_logs_to_stream_connector="$(normalize_bool "$(tfvars_val create_logs_to_stream_connector "${TFVARS_FILE}" || true)")"
  existing_stream_pool_id="$(tfvars_val existing_stream_pool_id "${TFVARS_FILE}" || true)"
  existing_stream_id="$(tfvars_val existing_stream_id "${TFVARS_FILE}" || true)"
  [[ -z "${create_logs_to_stream_connector}" || "${create_logs_to_stream_connector}" == "false" ]] && create_logs_to_stream_connector="true"

  local required_services=()
  if [[ "${use_existing_splunk}" != "true" ]]; then
    required_services+=("instance-family")
  fi
  if [[ "${use_existing_network}" != "true" ]]; then
    required_services+=("virtual-network-family")
  fi
  if [[ -z "${existing_stream_pool_id}" || -z "${existing_stream_id}" ]]; then
    required_services+=("stream-family")
  fi
  if [[ "${create_logs_to_stream_connector}" == "true" ]]; then
    required_services+=("serviceconnectors")
  fi

  if [[ ${#required_services[@]} -eq 0 ]]; then
    return 0
  fi

  local group_names_json group_ids policies_json statements_json
  group_ids="$(
    oci iam user group-membership list \
      --user-id "${preflight_user_ocid}" \
      --all \
      --query 'data[]."group-id"' \
      --output json 2>/dev/null || echo "[]"
  )"

  group_names_json="[]"
  if [[ "${group_ids}" != "[]" ]]; then
    local group_names_tmp="[]"
    local gid gname
    while IFS= read -r gid; do
      [[ -z "${gid}" ]] && continue
      gname="$(
        oci iam group get --group-id "${gid}" --query 'data.name' --raw-output 2>/dev/null || true
      )"
      [[ -n "${gname}" && "${gname}" != "null" ]] || continue
      group_names_tmp="$(jq -c --arg v "${gname}" '. + [$v]' <<<"${group_names_tmp}")"
    done < <(jq -r '.[]' <<<"${group_ids}" 2>/dev/null || true)
    group_names_json="${group_names_tmp}"
  fi

  policies_json="$(
    {
      oci iam policy list --compartment-id "${preflight_tenancy_ocid}" --all --output json 2>/dev/null || echo '{"data":[]}'
      if [[ "${target_compartment}" != "${preflight_tenancy_ocid}" ]]; then
        oci iam policy list --compartment-id "${target_compartment}" --all --output json 2>/dev/null || echo '{"data":[]}'
      fi
    } | jq -s '{"data": (map(.data // []) | add)}'
  )"

  statements_json="$(
    jq -c '[.data[]? | select(."lifecycle-state" == "ACTIVE") | .statements[]? | ascii_downcase]' <<<"${policies_json}"
  )"

  local groups_lc_json
  groups_lc_json="$(jq -c '[.[] | ascii_downcase]' <<<"${group_names_json}")"

  local services_json has_policy
  services_json="$(printf '%s\n' "${required_services[@]}" | jq -R . | jq -s .)"

  has_policy="$(
    jq -r \
      --argjson statements "${statements_json}" \
      --argjson groups "${groups_lc_json}" \
      --argjson services "${services_json}" \
      --arg comp "${target_compartment}" '
        def stmt_matches_group($stmt):
          if ($groups|length) == 0 then false
          else any($groups[]; $stmt | contains("allow group " + .))
          end;
        def stmt_matches_scope($stmt):
          ($stmt | test("in tenancy")) or ($stmt | contains("in compartment id " + ($comp | ascii_downcase)));
        def stmt_grants($service):
          any($statements[]; . as $s |
            stmt_matches_group($s) and stmt_matches_scope($s) and (
              ($s | test("to manage all-resources")) or
              ($s | test("to manage " + $service + "\\b")) or
              ($service == "stream-family" and ($s | test("to manage streaming-family\\b")))
            )
          );
        [ $services[] | select(stmt_grants(.) | not) ]
      '
  )"

  local missing_services_json
  missing_services_json="${has_policy}"
  if [[ -z "${missing_services_json}" || "${missing_services_json}" == "null" ]]; then
    missing_services_json="[]"
  fi

  local selected_group group_override
  group_override="${OCI_IAM_GROUP_NAME:-}"
  if [[ -n "${group_override}" ]]; then
    selected_group="${group_override}"
  else
    selected_group="$(jq -r '[.[] | select(ascii_downcase == "administrators")] | .[0] // empty' <<<"${group_names_json}")"
    if [[ -z "${selected_group}" ]]; then
      selected_group="$(jq -r '.[0] // empty' <<<"${group_names_json}")"
    fi
  fi
  if [[ -z "${selected_group}" ]]; then
    selected_group="Administrators"
    echo "WARN: Could not resolve user group memberships; defaulting IAM policy target group to '${selected_group}'."
  fi

  local force_policy_reconcile
  force_policy_reconcile="$(normalize_bool "${FORCE_POLICY_RECONCILE:-false}")"
  if [[ "${AUTO_APPROVE_POLICY_CREATE:-false}" == "true" ]]; then
    force_policy_reconcile="true"
  fi

  if [[ "$(jq -r 'length' <<<"${missing_services_json}")" -eq 0 && "${force_policy_reconcile}" != "true" ]]; then
    echo "IAM preflight passed for compartment ${target_compartment}."
    return 0
  fi

  local services_to_grant_json
  if [[ "${force_policy_reconcile}" == "true" ]]; then
    services_to_grant_json="${services_json}"
  else
    services_to_grant_json="${missing_services_json}"
  fi

  echo "IAM preflight requires policy reconciliation for group '${selected_group}' in compartment '${target_compartment}':"
  jq -r '.[]' <<<"${services_to_grant_json}" | sed 's/^/- /'

  local policy_statements_json stmt svc
  policy_statements_json="[]"
  while IFS= read -r svc; do
    [[ -z "${svc}" ]] && continue
    case "${svc}" in
      stream-family)
        stmt="Allow group ${selected_group} to manage stream-family in compartment id ${target_compartment}"
        ;;
      serviceconnectors)
        stmt="Allow group ${selected_group} to manage serviceconnectors in compartment id ${target_compartment}"
        ;;
      *)
        stmt="Allow group ${selected_group} to manage ${svc} in compartment id ${target_compartment}"
        ;;
    esac
    policy_statements_json="$(jq -c --arg s "${stmt}" '. + [$s]' <<<"${policy_statements_json}")"
  done < <(jq -r '.[]' <<<"${services_to_grant_json}")

  echo "Suggested policy statements:"
  jq -r '.[] | "- " + .' <<<"${policy_statements_json}"

  local should_create="false"
  if [[ "${AUTO_APPROVE_POLICY_CREATE:-false}" == "true" ]]; then
    should_create="true"
  elif [[ -t 0 ]]; then
    local ans=""
    read -r -p "Create or update IAM policy with these statements now? [Y/n]: " ans
    case "${ans}" in
      ""|y|Y|yes|YES) should_create="true" ;;
      *) should_create="false" ;;
    esac
  fi

  if [[ "${should_create}" != "true" ]]; then
    echo "ERROR: Deployment blocked until required IAM policies are approved/created."
    return 1
  fi

  local policy_name policy_desc existing_policy_json existing_policy_id version_date
  local statements_file
  policy_name="${OCI_SPLUNK_POLICY_NAME:-oci-splunk-deployer-access}"
  policy_desc="Auto-managed policy for OCI Splunk deployment in ${target_compartment}"
  statements_file="$(mktemp /tmp/oci-splunk-policy-statements.XXXXXX)"
  printf '%s' "${policy_statements_json}" >"${statements_file}"
  existing_policy_json="$(
    oci iam policy list \
      --compartment-id "${preflight_tenancy_ocid}" \
      --name "${policy_name}" \
      --all \
      --query 'data[0]' \
      --output json 2>/dev/null || echo "null"
  )"
  existing_policy_id="$(jq -r '.id // empty' <<<"${existing_policy_json}")"
  version_date="$(jq -r '."version-date" // empty' <<<"${existing_policy_json}")"

  if [[ -n "${existing_policy_id}" ]]; then
    echo "Updating existing IAM policy: ${policy_name}"
    if [[ -n "${version_date}" ]]; then
      oci iam policy update \
        --policy-id "${existing_policy_id}" \
        --description "${policy_desc}" \
        --statements "file://${statements_file}" \
        --version-date "${version_date}" \
        --force >/dev/null
    else
      oci iam policy update \
        --policy-id "${existing_policy_id}" \
        --description "${policy_desc}" \
        --statements "file://${statements_file}" \
        --force >/dev/null
    fi
  else
    echo "Creating IAM policy: ${policy_name}"
    oci iam policy create \
      --compartment-id "${preflight_tenancy_ocid}" \
      --name "${policy_name}" \
      --description "${policy_desc}" \
      --statements "file://${statements_file}" >/dev/null
  fi

  rm -f "${statements_file}" >/dev/null 2>&1 || true
  echo "IAM policy apply completed. Continuing deployment."
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
      echo "Generated SSH key pair: ${key_base}(.pub)"
    else
      echo "Reusing generated SSH key pair: ${key_base}(.pub)"
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
    [[ -n "${SPLUNK_SSH_PUBLIC_KEY_PATH}" ]] || {
      echo "SPLUNK_SSH_PUBLIC_KEY_PATH is required when SSH_KEY_SELECTION=use" >&2
      exit 1
    }
    [[ -f "${SPLUNK_SSH_PUBLIC_KEY_PATH}" ]] || {
      echo "SSH public key not found: ${SPLUNK_SSH_PUBLIC_KEY_PATH}" >&2
      exit 1
    }
    local private_candidate="${SPLUNK_SSH_PUBLIC_KEY_PATH%.pub}"
    if [[ -f "${private_candidate}" ]]; then
      SELECTED_SSH_PRIVATE_KEY_PATH="${private_candidate}"
    fi
  fi

  SSH_KEY="$(cat "${SPLUNK_SSH_PUBLIC_KEY_PATH}")"
  [[ -n "${SSH_KEY}" ]] || {
    echo "Selected SSH public key is empty: ${SPLUNK_SSH_PUBLIC_KEY_PATH}" >&2
    exit 1
  }
}

fetch_managed_hec_token() {
  local tf_use_existing token_from_tfvars splunk_ip

  tf_use_existing="$(tfvars_val use_existing_splunk "${TFVARS_FILE}" || true)"
  [[ "${tf_use_existing}" == "true" ]] && return 0

  token_from_tfvars="$(tfvars_val splunk_hec_token "${TFVARS_FILE}" || true)"
  if [[ -n "${token_from_tfvars}" && "${token_from_tfvars}" != "TEMP_HEC_TOKEN_TO_REPLACE" && "${token_from_tfvars}" != "replace-with-hec-token" ]]; then
    export SPLUNK_HEC_TOKEN_OVERRIDE="${token_from_tfvars}"
    return 0
  fi

  splunk_ip="$(terraform output -raw splunk_instance_public_ip 2>/dev/null || true)"
  [[ -n "${splunk_ip}" ]] || return 0
  [[ -n "${SELECTED_SSH_PRIVATE_KEY_PATH}" ]] || return 0
  [[ -f "${SELECTED_SSH_PRIVATE_KEY_PATH}" ]] || return 0

  local fetched_token
  fetched_token="$(
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -i "${SELECTED_SSH_PRIVATE_KEY_PATH}" "opc@${splunk_ip}" \
      "sudo awk -F= '/^SPLUNK_HEC_TOKEN=/{gsub(/^[ \\t\\\"]+|[ \\t\\\"]+$/, \"\", \$2); print \$2}' /opt/oci-splunk/runtime.env 2>/dev/null | head -n1" 2>/dev/null || true
  )"
  if [[ -n "${fetched_token}" ]]; then
    export SPLUNK_HEC_TOKEN_OVERRIDE="${fetched_token}"
    echo "Fetched generated Splunk HEC token from managed instance."
  fi
}

print_connection_summary() {
  local splunk_ip splunk_url hec_url admin_password ssh_user hec_token
  splunk_ip="$(terraform output -raw splunk_instance_public_ip 2>/dev/null || true)"
  splunk_url="$(terraform output -raw splunk_web_url 2>/dev/null || true)"
  hec_url="$(terraform output -raw splunk_hec_endpoint 2>/dev/null || true)"
  admin_password="$(tfvars_val splunk_admin_password "${TFVARS_FILE}" || true)"
  hec_token="${SPLUNK_HEC_TOKEN_OVERRIDE:-$(tfvars_val splunk_hec_token "${TFVARS_FILE}" || true)}"
  ssh_user="opc"

  echo
  echo "Deployment access:"
  [[ -n "${splunk_ip}" ]] && echo "- Splunk VM Public IP: ${splunk_ip}"
  [[ -n "${splunk_url}" ]] && echo "- Splunk Web URL: ${splunk_url}"
  [[ -n "${hec_url}" ]] && echo "- Splunk HEC URL: ${hec_url}"
  [[ -n "${hec_token}" ]] && echo "- Splunk HEC Token: ${hec_token}"
  echo "- Splunk Username: admin"
  [[ -n "${admin_password}" ]] && echo "- Splunk Password: ${admin_password}"
  if [[ -n "${splunk_ip}" ]]; then
    if [[ -n "${SELECTED_SSH_PRIVATE_KEY_PATH}" ]]; then
      echo "- SSH command: ssh -i ${SELECTED_SSH_PRIVATE_KEY_PATH} ${ssh_user}@${splunk_ip}"
    else
      echo "- SSH command: ssh ${ssh_user}@${splunk_ip}"
    fi
  fi
}

need_cmd terraform

REGION=""
TENANCY_OCID=""
USER_OCID=""
FINGERPRINT=""
KEY_FILE=""

if [[ -f "${OCI_CONFIG_FILE}" ]]; then
  REGION="$(cfg_val region || true)"
  TENANCY_OCID="$(cfg_val tenancy || true)"
  USER_OCID="$(cfg_val user || true)"
  FINGERPRINT="$(cfg_val fingerprint || true)"
  KEY_FILE="$(cfg_val key_file || true)"
fi

SSH_KEY=""
prepare_ssh_key_material

if [[ -z "${TFVARS_FILE}" ]]; then
  if [[ -f "${SCRIPT_DIR}/terraform.tfvars.local" ]]; then
    TFVARS_FILE="${SCRIPT_DIR}/terraform.tfvars.local"
  else
    TFVARS_FILE="${SCRIPT_DIR}/terraform.tfvars"
  fi
fi
echo "Using vars file: ${TFVARS_FILE}"

cat > "${AUTO_VARS_FILE}" <<VARS
# Auto-generated by deploy_local.sh
auth = "ApiKey"
oci_profile = "${OCI_PROFILE}"
oci_config_file = "${OCI_CONFIG_FILE}"
region = "${REGION}"
tenancy_ocid = "${TENANCY_OCID}"
user_ocid = "${USER_OCID}"
fingerprint = "${FINGERPRINT}"
private_key_path = "${KEY_FILE}"
ssh_public_key = "${SSH_KEY}"
VARS

if [[ -n "${TF_VAR_compartment_ocid:-}" ]]; then
  echo "compartment_ocid = \"${TF_VAR_compartment_ocid}\"" >> "${AUTO_VARS_FILE}"
fi

if [[ -z "${TF_VAR_compartment_ocid:-}" ]]; then
  TFVARS_COMPARTMENT_OCID="$(tfvars_val compartment_ocid "${TFVARS_FILE}" || true)"
  if [[ -n "${TFVARS_COMPARTMENT_OCID}" ]]; then
    :
  elif [[ -n "${DEFAULT_COMPARTMENT_OCID}" ]]; then
    echo "compartment_ocid = \"${DEFAULT_COMPARTMENT_OCID}\"" >> "${AUTO_VARS_FILE}"
    echo "Using DEFAULT_COMPARTMENT_OCID for compartment_ocid: ${DEFAULT_COMPARTMENT_OCID}"
  elif [[ -n "${TENANCY_OCID}" ]]; then
    echo "compartment_ocid = \"${TENANCY_OCID}\"" >> "${AUTO_VARS_FILE}"
    echo "No compartment_ocid provided; defaulting to tenancy root compartment: ${TENANCY_OCID}"
  fi
fi

if [[ -n "${TF_VAR_allowed_ingress_cidr:-}" ]]; then
  echo "allowed_ingress_cidr = \"${TF_VAR_allowed_ingress_cidr}\"" >> "${AUTO_VARS_FILE}"
else
  TFVARS_INGRESS_CIDR="$(tfvars_val allowed_ingress_cidr "${TFVARS_FILE}" || true)"
  if [[ -n "${TFVARS_INGRESS_CIDR}" ]]; then
    # Respect user-configured ingress from the selected var file (laptop IP),
    # and do not override it with this runner's public IP.
    echo "allowed_ingress_cidr = \"${TFVARS_INGRESS_CIDR}\"" >> "${AUTO_VARS_FILE}"
    echo "Using configured ingress CIDR from ${TFVARS_FILE}: ${TFVARS_INGRESS_CIDR}"
  else
    DETECTED_PUBLIC_IP="$(detect_public_ip || true)"
    if [[ -n "${DETECTED_PUBLIC_IP}" ]]; then
      echo "allowed_ingress_cidr = \"${DETECTED_PUBLIC_IP}/32\"" >> "${AUTO_VARS_FILE}"
      echo "Using detected ingress CIDR: ${DETECTED_PUBLIC_IP}/32"
    fi
  fi
fi

if [[ ! -f "${TFVARS_FILE}" ]]; then
  cp terraform.tfvars.example "${TFVARS_FILE}"
  echo "Created ${TFVARS_FILE} from terraform.tfvars.example. Fill required values and rerun."
  echo "Detected values written to ${AUTO_VARS_FILE}."
  exit 1
fi

TARGET_COMPARTMENT_OCID="${TF_VAR_compartment_ocid:-${TENANCY_OCID}}"
TVARS_COMPARTMENT_OCID="$(tfvars_val compartment_ocid "${TFVARS_FILE}" || true)"
if [[ -n "${TVARS_COMPARTMENT_OCID}" ]]; then
  TARGET_COMPARTMENT_OCID="${TVARS_COMPARTMENT_OCID}"
fi

check_iam_policy_coverage "${TARGET_COMPARTMENT_OCID}" "${ACTION}"

if [[ "${ACTION}" != "destroy" && "${REUSE_EXISTING_STREAMING}" == "true" ]] && command -v oci >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  TARGET_STREAM_NAME="$(tfvars_val stream_name "${TFVARS_FILE}" || true)"
  if [[ -z "${TARGET_STREAM_NAME}" ]]; then
    TARGET_STREAM_NAME="oci-splunk-stream"
  fi

  if [[ -n "${TARGET_COMPARTMENT_OCID}" ]]; then
    EXISTING_STREAM_ID="$(
      oci streaming admin stream list \
        --compartment-id "${TARGET_COMPARTMENT_OCID}" \
        --all \
        --output json 2>/dev/null | jq -r --arg stream_name "${TARGET_STREAM_NAME}" '.data[] | select(.name == $stream_name and ."lifecycle-state" == "ACTIVE") | .id' | head -n1
    )" || true

    if [[ -n "${EXISTING_STREAM_ID}" ]]; then
      EXISTING_POOL_ID="$(
        oci streaming admin stream get \
          --stream-id "${EXISTING_STREAM_ID}" \
          --output json 2>/dev/null | jq -r '.data["stream-pool-id"]'
      )" || true
      if [[ -z "${EXISTING_POOL_ID}" ]]; then
        echo "Stream reuse lookup found stream but failed to read pool ID; keeping existing tfvars/autodetected values."
      fi
      cat > "${STREAM_REUSE_VARS_FILE}" <<VARS
# Auto-generated by deploy_local.sh (reuses an existing stream/pool)
existing_stream_id = "${EXISTING_STREAM_ID}"
existing_stream_pool_id = "${EXISTING_POOL_ID}"
VARS
      echo "Reusing existing stream '${TARGET_STREAM_NAME}' (${EXISTING_STREAM_ID}) and stream pool (${EXISTING_POOL_ID})."
    else
      if [[ -f "${STREAM_REUSE_VARS_FILE}" ]]; then
        echo "Could not refresh stream reuse from OCI CLI (or stream not found). Keeping existing ${STREAM_REUSE_VARS_FILE}."
      else
        echo "No existing stream named '${TARGET_STREAM_NAME}' found in ${TARGET_COMPARTMENT_OCID}; deployment may create new streaming resources."
      fi
    fi
  fi
fi

terraform init -upgrade

case "${ACTION}" in
  plan)
    terraform plan -var-file="${TFVARS_FILE}"
    ;;
  apply)
    terraform apply -auto-approve -var-file="${TFVARS_FILE}"
    fetch_managed_hec_token
    if [[ -x "${SCRIPT_DIR}/verify_deployment.sh" ]]; then
      TFVARS_FILE="${TFVARS_FILE}" "${SCRIPT_DIR}/verify_deployment.sh"
    fi
    print_connection_summary
    ;;
  destroy)
    terraform destroy -auto-approve -var-file="${TFVARS_FILE}"
    ;;
  *)
    echo "Unsupported action: ${ACTION}. Use apply|plan|destroy" >&2
    exit 1
    ;;
esac
