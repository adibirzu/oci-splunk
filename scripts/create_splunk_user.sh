#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  $0 --new-user <user> --new-password <password> [options]

Options:
  --host <ip-or-hostname>            Remote Splunk host (optional; local if omitted)
  --ssh-user <user>                  SSH user for remote host (default: opc)
  --ssh-key <path>                   SSH private key path (default: ~/.ssh/id_ed25519)
  --admin-user <user>                Splunk admin user (default: admin)
  --admin-password <password>        Splunk admin password (required)
  --new-user <user>                  New/existing Splunk user to create/update
  --new-password <password>          Password for the new user
  --new-role <role>                  Splunk role (default: user)
  --help                             Show this help
USAGE
}

HOST=""
SSH_USER="opc"
SSH_KEY="${HOME}/.ssh/id_ed25519"
ADMIN_USER="admin"
ADMIN_PASSWORD=""
NEW_USER=""
NEW_PASSWORD=""
NEW_ROLE="user"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --new-user) NEW_USER="$2"; shift 2 ;;
    --new-password) NEW_PASSWORD="$2"; shift 2 ;;
    --new-role) NEW_ROLE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "${ADMIN_PASSWORD}" ]] || { echo "--admin-password is required" >&2; exit 1; }
[[ -n "${NEW_USER}" ]] || { echo "--new-user is required" >&2; exit 1; }
[[ -n "${NEW_PASSWORD}" ]] || { echo "--new-password is required" >&2; exit 1; }

SPLUNK_CMD="/opt/splunk/bin/splunk edit user '${NEW_USER}' -password '${NEW_PASSWORD}' -roles '${NEW_ROLE}' -auth '${ADMIN_USER}:${ADMIN_PASSWORD}'"

if [[ -n "${HOST}" ]]; then
  [[ -f "${SSH_KEY}" ]] || { echo "SSH key not found: ${SSH_KEY}" >&2; exit 1; }
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${SSH_USER}@${HOST}" \
    "sudo bash -lc ${SPLUNK_CMD@Q}"
  echo "User '${NEW_USER}' created/updated on ${HOST} with role '${NEW_ROLE}'."
else
  sudo bash -lc "${SPLUNK_CMD}"
  echo "User '${NEW_USER}' created/updated on local host with role '${NEW_ROLE}'."
fi
