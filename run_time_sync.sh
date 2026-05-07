#!/usr/bin/env bash
set -euo pipefail

INVENTORY_FILE="${INVENTORY_FILE:-./inventory.ini}"
GROUP_NAME="${GROUP_NAME:-managed_nodes}"
REMOTE_USER="${ANSIBLE_REMOTE_USER:-mitac}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"

TIME_ZONE=""
TIME_SERVERS=()
RUN_PING=1

usage() {
  cat <<'USAGE'
Usage:
  ./run_time_sync.sh --time-server <server> [--time-zone <timezone>] [options]

Required:
  --time-server <server>       Chrony/NTP time server IP or hostname.
                               Can be specified multiple times.

Optional:
  --time-zone <timezone>       Timezone, for example: Asia/Taipei, UTC.
  --inventory <file>           Inventory output file. Default: ./inventory.ini
  --group <group_name>         Inventory group name. Default: managed_nodes
  --user <remote_user>         Remote SSH user. Default: mitac
  --hosts-file <file>          Source hosts file. Default: /etc/hosts
  --skip-ping                  Skip Ansible ping test.
  -h, --help                   Show this help.

Examples:
  ./run_time_sync.sh --time-server 10.88.0.23 --time-zone Asia/Taipei

  ./run_time_sync.sh \
    --time-server 10.88.0.23 \
    --time-server 10.88.0.24 \
    --time-zone Asia/Taipei

  INVENTORY_FILE=./inventory.ini ANSIBLE_REMOTE_USER=mitac \
    ./run_time_sync.sh --time-server 10.88.0.23 --time-zone Asia/Taipei
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

is_placeholder_time_server() {
  local value="$1"

  case "${value}" in
    xxx.xxx.xxx.xxx|XXX.XXX.XXX.XXX|x.x.x.x|X.X.X.X)
      return 0
      ;;
  esac

  return 1
}

validate_time_server_value() {
  local value="$1"

  [[ -n "${value}" ]] || die "--time-server cannot be empty"

  if is_placeholder_time_server "${value}"; then
    die "--time-server looks like a placeholder: ${value}"
  fi

  # 這裡刻意不做太嚴格的 hostname/IP 驗證，
  # 因為 NTP server 可能是 IP、FQDN、短 hostname。
  if [[ "${value}" =~ [[:space:]] ]]; then
    die "--time-server must not contain spaces: ${value}"
  fi
}

validate_time_zone_value() {
  local value="$1"

  [[ -n "${value}" ]] || die "--time-zone cannot be empty"

  if [[ "${value}" =~ [[:space:]] ]]; then
    die "--time-zone must not contain spaces: ${value}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --time-server)
        [[ $# -ge 2 ]] || die "Missing value for --time-server"
        validate_time_server_value "$2"
        TIME_SERVERS+=("$2")
        shift 2
        ;;

      --time-zone)
        [[ $# -ge 2 ]] || die "Missing value for --time-zone"
        validate_time_zone_value "$2"
        TIME_ZONE="$2"
        shift 2
        ;;

      --inventory)
        [[ $# -ge 2 ]] || die "Missing value for --inventory"
        INVENTORY_FILE="$2"
        shift 2
        ;;

      --group)
        [[ $# -ge 2 ]] || die "Missing value for --group"
        GROUP_NAME="$2"
        shift 2
        ;;

      --user)
        [[ $# -ge 2 ]] || die "Missing value for --user"
        REMOTE_USER="$2"
        shift 2
        ;;

      --hosts-file)
        [[ $# -ge 2 ]] || die "Missing value for --hosts-file"
        HOSTS_FILE="$2"
        shift 2
        ;;

      --skip-ping)
        RUN_PING=0
        shift
        ;;

      -h|--help)
        usage
        exit 0
        ;;

      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

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

build_extra_vars_args() {
  EXTRA_VARS_ARGS=()

  if [[ ${#TIME_SERVERS[@]} -gt 0 ]]; then
    local json_servers=""
    local server

    for server in "${TIME_SERVERS[@]}"; do
      if [[ -n "${json_servers}" ]]; then
        json_servers+=","
      fi
      json_servers+="\"${server}\""
    done

    EXTRA_VARS_ARGS+=(--extra-vars "{\"chrony_time_servers\":[${json_servers}]}")
  fi

  if [[ -n "${TIME_ZONE}" ]]; then
    EXTRA_VARS_ARGS+=(--extra-vars "time_zone=${TIME_ZONE}")
  fi
}

validate_required_runtime_vars() {
  # 為了避免誤用 group_vars 裡面的 placeholder，這裡要求明確傳入 --time-server。
  # 如果未來你想完全依賴 group_vars/all.yml，可以把這段改成 warning。
  if [[ ${#TIME_SERVERS[@]} -eq 0 ]]; then
    die "Missing required option: --time-server <server>"
  fi

  # time_zone 可以選擇不傳，交給 group_vars/all.yml。
  # 但若 group_vars/all.yml 也沒設定，time_sync role 可能會失敗。
}

run_ping_test() {
  ansible -i "${INVENTORY_FILE}" "${GROUP_NAME}" -m ping
}

run_all_playbooks() {
  ansible-playbook \
    -i "${INVENTORY_FILE}" \
    -b -K \
    "${EXTRA_VARS_ARGS[@]}" \
    site.yml verify.yml post_check.yml
}

main() {
  parse_args "$@"
  validate_required_runtime_vars
  build_extra_vars_args

  generate_inventory
  validate_inventory

  echo "Generated    : ${INVENTORY_FILE}"
  echo "Group        : ${GROUP_NAME}"
  echo "User         : ${REMOTE_USER}"
  echo "Hosts file   : ${HOSTS_FILE}"
  echo "Time servers : ${TIME_SERVERS[*]}"
  echo "Time zone    : ${TIME_ZONE:-'(from group_vars/default)'}"

  if [[ "${RUN_PING}" -eq 1 ]]; then
    run_ping_test
  else
    echo "Skip ping    : yes"
  fi

  run_all_playbooks
}

main "$@"
