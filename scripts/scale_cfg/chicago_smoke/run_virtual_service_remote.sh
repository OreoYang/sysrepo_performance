#!/usr/bin/env bash
# Serial virtual SERVICE on Chicago. Default N=1022.
# First confirm one ONU (N=1), then full N=1022.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.chicago.sh"
source "${SCRIPT_DIR}/lib_ssh.sh"

N="${N:-1022}"
REMOTE="${OLT_SMOKE_DIR}"
BG="${BG:-1}"

echo "Starting serial virtual SERVICE N=${N} on ${CHICAGO_OLT_IP}"
if [ "$BG" = 0 ]; then
    chicago_ssh "cd '${REMOTE}/olt' && ./run_virtual_service_n.sh '${N}'"
else
    chicago_ssh "chmod +x '${REMOTE}/olt/'*.sh && cd '${REMOTE}/olt' && nohup ./run_virtual_service_n.sh '${N}' > '${REMOTE}/work/virtual_service_${N}.out' 2>&1 & echo PID=\$!"
    echo "Follow: tail -f ${REMOTE}/work/virtual_service_${N}.out"
fi
