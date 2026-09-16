#!/usr/bin/env bash
# Chicago run: 00-base, then per-ONU provision+service paired by SN.
# Incremental must be exported on sysrepocfg (systemd env is not inherited).
# Keep netconf-polt + protocol-handler running (field-like path, change CBs fire).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.chicago.sh"
source "${SCRIPT_DIR}/lib_ssh.sh"

N="${N:-1022}"
REMOTE="${OLT_SMOKE_DIR}"
TAR="${SCRIPT_DIR}/work_n${N}.tar"
PHASE="${PHASE:-all}"   # pack|base|onu1|n1022|all
INCR="${SR_VALIDATE_INCREMENTAL:-1}"

echo "=== pack work N=${N} ==="
N="$N" OUT="$TAR" "${SCRIPT_DIR}/pack_work_n.sh"

echo "=== deploy scripts + tarball ==="
chicago_ssh "mkdir -p '${REMOTE}/olt' '${REMOTE}/work' '${REMOTE}/work_xml'"
chicago_scp "${SCRIPT_DIR}/olt/"*.sh "${CHICAGO_OLT_USER}@${CHICAGO_OLT_IP}:${REMOTE}/olt/"
chicago_scp "${TAR}" "${CHICAGO_OLT_USER}@${CHICAGO_OLT_IP}:${REMOTE}/work_n${N}.tar"
chicago_ssh "chmod +x '${REMOTE}/olt/'*.sh && tar -C '${REMOTE}/work_xml' -xf '${REMOTE}/work_n${N}.tar' && wc -l '${REMOTE}/work_xml/pairs.txt' && sed -n '1,3p;180p' '${REMOTE}/work_xml/pairs.txt'"

echo "=== probe ==="
chicago_ssh 'hostname
systemctl is-active netconf-polt protocol-handler netopeer2
systemctl show netconf-polt -p Environment | grep SR_VALIDATE || true
sysrepocfg --version | sed -n "1p"
strings /usr/lib/libyang.so.3 | grep -F lyd_validate_module_incr | sed -n "1p" || echo missing_incr_sym
'

echo "=== keep stack up (do not stop polt / protocol-handler during timed apply) ==="
chicago_ssh 'systemctl start protocol-handler netconf-polt netopeer2
systemctl is-active netconf-polt protocol-handler netopeer2
systemctl is-active netconf-polt >/dev/null || { echo error: netconf-polt not active; exit 1; }
systemctl is-active protocol-handler >/dev/null || { echo error: protocol-handler not active; exit 1; }
'

echo "=== reset running from startup if ONU data present (setup, not timed) ==="
chicago_ssh 'n=$(sysrepocfg -X -m ietf-interfaces -d running 2>/dev/null | grep -c "<v-ani" || true)
echo "running v-ani=${n:-0}"
if [ "${n:-0}" -gt 0 ]; then
  echo "copy-config startup -> running"
  sysrepocfg -C startup -d running
  echo -n "after v-ani="; sysrepocfg -X -m ietf-interfaces -d running 2>/dev/null | grep -c "<v-ani" || echo 0
fi
systemctl is-active netconf-polt protocol-handler
'

echo "=== load 00-base (SR_VALIDATE_INCREMENTAL=${INCR}) ==="
chicago_ssh "export SR_VALIDATE_INCREMENTAL='${INCR}' CFG='${REMOTE}/work_xml' && '${REMOTE}/olt/load_work_base.sh'"

echo "=== ONU1 paired provision+service ==="
chicago_ssh "export SR_VALIDATE_INCREMENTAL='${INCR}' CFG='${REMOTE}/work_xml' START=1 && cd '${REMOTE}/olt' && ./run_work_paired_n.sh 1"

echo "=== nohup paired N=${N} START=2 (SSH-safe) ==="
chicago_ssh "export SR_VALIDATE_INCREMENTAL='${INCR}' CFG='${REMOTE}/work_xml' START=2
cd '${REMOTE}/olt'
nohup ./run_work_paired_n.sh '${N}' > '${REMOTE}/work/work_paired_${N}_incr${INCR}.out' 2>&1 &
echo PID=\$!
sleep 1
sed -n '1,6p' '${REMOTE}/work/work_paired_${N}_incr${INCR}.out' || true
"
echo "Follow: ssh root@${CHICAGO_OLT_IP}  then  tail -f ${REMOTE}/work/work_paired_${N}_incr${INCR}.out"
