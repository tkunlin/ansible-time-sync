#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
OUT_FILE="${OUT_FILE:-./inventory.ini}"
GROUP_NAME="${GROUP_NAME:-managed_nodes}"
ANSIBLE_USER="${ANSIBLE_USER:-mitac}"

BLOCK_BEGIN="${BLOCK_BEGIN:-# MANAGED_HOSTS_BEGIN}"
BLOCK_END="${BLOCK_END:-# MANAGED_HOSTS_END}"

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

mapfile -t HOST_LINES < <(
  awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    $0 == begin { in_block=1; next }
    $0 == end   { in_block=0; exit }
    in_block    { print }
  ' "$HOSTS_FILE" \
  | awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      {
        ip=$1
        host=$2
        if (ip == "" || host == "") next
        if (ip ~ /^127\./) next
        if (ip == "::1") next
        if (ip ~ /:/) next
        print ip, host
      }
    '
)

if [[ "${#HOST_LINES[@]}" -eq 0 ]]; then
  echo "ERROR: No hosts found between markers:"
  echo "  $BLOCK_BEGIN"
  echo "  $BLOCK_END"
  echo "in $HOSTS_FILE"
  exit 1
fi

{
  echo "[${GROUP_NAME}]"

  for line in "${HOST_LINES[@]}"; do
    ip="$(awk '{print $1}' <<< "$line")"
    host="$(awk '{print $2}' <<< "$line")"

    [[ -z "${ip:-}" || -z "${host:-}" ]] && continue
    printf "%s ansible_host=%s\n" "$host" "$ip"
  done

  echo
  echo "[all:vars]"
  echo "ansible_user=${ANSIBLE_USER}"
} > "$tmpfile"

mv "$tmpfile" "$OUT_FILE"

echo "Generated: $OUT_FILE"
echo "Group: $GROUP_NAME"
echo "User : $ANSIBLE_USER"
