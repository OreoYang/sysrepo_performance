#!/usr/bin/env bash
# Copy/update smoke scripts on Chicago OLT (persistent path, overlay survives reboot).
# Does not wipe ${OLT_SMOKE_DIR}/work (logs/timings).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.chicago.sh
source "${SCRIPT_DIR}/env.chicago.sh"
# shellcheck source=lib_ssh.sh
source "${SCRIPT_DIR}/lib_ssh.sh"

REMOTE="${OLT_SMOKE_DIR}"
echo "Updating ${CHICAGO_OLT_IP}:${REMOTE} (keeping ${REMOTE}/work if present)"
chicago_ssh "mkdir -p '${REMOTE}/olt' '${REMOTE}/work'"
chicago_scp "${SCRIPT_DIR}/olt/"*.sh "${CHICAGO_OLT_USER}@${CHICAGO_OLT_IP}:${REMOTE}/olt/"
chicago_scp "${SCRIPT_DIR}/env.chicago.sh" "${CHICAGO_OLT_USER}@${CHICAGO_OLT_IP}:${REMOTE}/"
chicago_ssh "chmod +x '${REMOTE}/olt/'*.sh"
echo "Done. Later runs: ssh and cd ${REMOTE}/olt — no copy needed unless scripts change."
