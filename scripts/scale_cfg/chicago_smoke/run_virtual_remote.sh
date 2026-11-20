#!/usr/bin/env bash
# Start serial virtual N-ONU provision on Chicago (nohup on OLT). Default N=1022.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.chicago.sh"
source "${SCRIPT_DIR}/lib_ssh.sh"

N="${N:-1022}"
START="${START:-1}"
REMOTE="${OLT_SMOKE_DIR}"
OUT="${REMOTE}/work/virtual_${N}.out"

echo "Starting serial virtual N=${N} START=${START} on ${CHICAGO_OLT_IP}:${REMOTE}"
# setsid + closed stdin so logind SSH session teardown does not kill the scale loop.
chicago_ssh "mkdir -p '${REMOTE}/work' && chmod +x '${REMOTE}/olt/'/*.sh && setsid sh -c 'export START=${START} WORK=${REMOTE}/work; cd ${REMOTE}/olt && exec ./run_virtual_n.sh ${N}' >>'${OUT}' 2>&1 </dev/null & sleep 1; tail -3 '${OUT}'"
echo "Follow: ssh root@${CHICAGO_OLT_IP}  then  tail -f ${OUT}"
