#!/usr/bin/env bash
# Export Chicago OLT running to /root/chicago_smoke/work/running_full_audit.xml
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.chicago.sh
source "${SCRIPT_DIR}/env.chicago.sh"
# shellcheck source=lib_ssh.sh
source "${SCRIPT_DIR}/lib_ssh.sh"

REMOTE="${OLT_SMOKE_DIR}"
OUT="${REMOTE}/work/running_full_audit.xml"

echo "=== export running on ${CHICAGO_OLT_IP} -> ${OUT} ==="
chicago_ssh "test -x '${REMOTE}/olt/export_running_audit.sh' || test -x '${REMOTE}/olt/netconf_edit.sh'" \
    || { echo "error: deploy first: ${SCRIPT_DIR}/deploy_to_olt.sh" >&2; exit 1; }

chicago_ssh "mkdir -p '${REMOTE}/work' && cd '${REMOTE}/olt' && ./export_running_audit.sh '${OUT}' 2>/dev/null || {
  mkdir -p '${REMOTE}/work'
  sysrepocfg --export='${OUT}' -d running -f xml
  echo \"EXPORT OK (inline sysrepocfg)\"
  stat -c 'size=%s bytes' '${OUT}'
}"

echo ""
echo "On PC, fetch:"
echo "  scp root@${CHICAGO_OLT_IP}:${OUT} /tmp/"