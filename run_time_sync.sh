#!/usr/bin/env bash
set -euo pipefail

INVENTORY_FILE="${INVENTORY_FILE:-./inventory.ini}"
GROUP_NAME="${GROUP_NAME:-managed_nodes}"
REMOTE_USER="${ANSIBLE_REMOTE_USER:-mitac}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"

generate_inventory() {
  : > "${INVENTORY_FILE}"

  cat >> "${INVENTORY_FILE}" <<EOF_INV
[${GROUP_NAME}]
EOF_INV

  awk '
    BEGIN { in_block=0 }
    /^[[:space:]]*# MANAGED_HOSTS_BEGIN[[:space:]]*$/ { in_block=1; next }
    /^[[:space:]]*# MANAGED_HOSTS_END[[:space:]]*$/   { in_block=0; next }
    !in_block { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      ip=$1
      host=""
      for (i=2; i<=NF; i++) {
        if ($i ~ /^#/) break
        host=$i
        break
      }
      if (ip != "" && host != "") {
        printf "%s ansible_host=%s\n", host, ip
      }
    }
  ' "${HOSTS_FILE}" >> "${INVENTORY_FILE}"

  cat >> "${INVENTORY_FILE}" <<EOF_VARS

[${GROUP_NAME}:vars]
ansible_user=${REMOTE_USER}
ansible_python_interpreter=/usr/bin/python3
EOF_VARS
}

validate_inventory() {
  if ! grep -qE "^[a-zA-Z0-9._-]+[[:space:]]+ansible_host=" "${INVENTORY_FILE}"; then
    echo "ERROR: inventory is empty or invalid: ${INVENTORY_FILE}" >&2
    echo "Please check ${HOSTS_FILE} and the block markers:" >&2
    echo "  # MANAGED_HOSTS_BEGIN" >&2
    echo "  # MANAGED_HOSTS_END" >&2
    exit 1
  fi
}

run_ping_test() {
  ansible -i "${INVENTORY_FILE}" "${GROUP_NAME}" -m ping
}

run_site() {
  ansible-playbook -i "${INVENTORY_FILE}" -b -K site.yml
}

run_verify() {
  ansible-playbook -i "${INVENTORY_FILE}" -b -K verify.yml
}

run_post_check() {
  ansible-playbook -i "${INVENTORY_FILE}" -b -K post_check.yml
}

main() {
  generate_inventory
  validate_inventory

  echo "Generated: ${INVENTORY_FILE}"
  echo "Group: ${GROUP_NAME}"
  echo "User : ${REMOTE_USER}"

  run_ping_test
  run_site
  run_verify
  run_post_check
}

main "$@"
