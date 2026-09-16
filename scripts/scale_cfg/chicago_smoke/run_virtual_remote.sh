#!/usr/bin/env bash
# Start serial virtual N-ONU provision on Chicago (nohup on OLT). Default N=1022.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.chicago.sh"
source "${SCRIPT_DIR}/lib_ssh.sh"

N="${N:-1022}"
REMOTE="${OLT_SMOKE_DIR}"

echo "Starting serial virtual N=${N} on ${CHICAGO_OLT_IP}:${REMOTE}"
chicago_ssh "mkdir -p '${REMOTE}/work' && chmod +x '${REMOTE}/olt/'*.sh && cd '${REMOTE}/olt' && nohup ./run_virtual_n.sh '${N}' > '${REMOTE}/work/virtual_${N}.out' 2>&1 & echo PID=\$!"
echo "Follow: ssh root@${CHICAGO_OLT_IP}  then  tail -f ${REMOTE}/work/virtual_${N}.out"
