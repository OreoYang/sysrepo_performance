#!/usr/bin/env bash
# Host: 00-base, then per-ONU provision + matching service by SN.
# Incremental on (SR_VALIDATE_INCREMENTAL=1). Do not use ls|head N on service.
#
# Env: PAIR_N (default 1), PAIR_MODE=editdiff|full (default editdiff)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

PAIR_N="${PAIR_N:-1}"
PAIR_MODE="${PAIR_MODE:-editdiff}"
CONFIGS_DIR="${CONFIGS_DIR:-${WORK_DIR}/configs}"
LOG="${LOG:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}.log}"
CSV="${CSV:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}.csv}"
PER_EDIT="${PER_EDIT:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}_per_edit.csv}"
PAIRS_OUT="${PAIRS_OUT:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}_pairs.txt}"
SR_EDIT_FILES="${SR_EDIT_FILES:-${SCRIPT_DIR}/.local/bin/sr_edit_files}"
SR_EDIT_EXTRA="${SR_EDIT_EXTRA:-}"
YANG_CACHE="${YANG_CACHE:-${WORK_DIR}/yang_installed_repo}"

log() { echo "$*" | tee -a "${LOG}"; }
die() { log "error: $*"; exit 1; }

mkdir -p "${RESULTS_DIR}"
if [[ -z "${AB_APPEND:-}" ]]; then
    if [[ -f "${LOG}" ]]; then
        mv -f "${LOG}" "${LOG}.prev"
    fi
    : > "${LOG}"
    echo "mode,phase,onu_idx,serial,apply_s,file" > "${PER_EDIT}"
    echo "timestamp,mode,kind,n,ok,fail,seconds,first_s,mid_s,last_s,status" > "${CSV}"
fi

log "=== paired SN provision+service PAIR_N=${PAIR_N} mode=${PAIR_MODE} ==="
log "started: $(date -Iseconds)"
log "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1 | tee -a "${LOG}"
[[ -x "${SR_EDIT_FILES}" ]] || die "sr_edit_files missing at ${SR_EDIT_FILES}"
[[ -d "${CONFIGS_DIR}/00-base" ]] || die "missing ${CONFIGS_DIR}/00-base"
[[ -d "${CONFIGS_DIR}/onu-provision" ]] || die "missing onu-provision"

python3 "${SCRIPT_DIR}/lib/build_onu_pairs.py" --configs "${CONFIGS_DIR}" -n "${PAIR_N}" \
    --format tsv --preview 3 > "${PAIRS_OUT}"
python3 "${SCRIPT_DIR}/lib/build_onu_pairs.py" --configs "${CONFIGS_DIR}" -n "${PAIR_N}" \
    --format summary | tee -a "${LOG}"
log "pairs: ${PAIRS_OUT}"
log "order: 00-base, then for each pair: provision XML then service XML (skip if no SN match)"

mapfile -t APPLY_FILES < <(
    python3 "${SCRIPT_DIR}/lib/build_onu_pairs.py" --configs "${CONFIGS_DIR}" -n "${PAIR_N}" --format apply
)
log "apply files: ${#APPLY_FILES[@]} (provision + present service)"

fresh_repo() {
    local shm_id="${1:-paired}"
    if [[ ! -d "${YANG_CACHE}/yang" ]]; then
        log "  installing YANG into cache ${YANG_CACHE}"
        rm -rf "${YANG_CACHE}" "${WORK_DIR}/shm/yang_cache"
        mkdir -p "${YANG_CACHE}" "${WORK_DIR}/shm/yang_cache"
        export SYSREPO_REPOSITORY_PATH="${YANG_CACHE}"
        export SYSREPO_SHM_DIR="${WORK_DIR}/shm/yang_cache"
        "${SCRIPT_DIR}/install_yang_modules.sh" >> "${LOG}" 2>&1 || log "warn: yang install reported errors"
        [[ -d "${YANG_CACHE}/yang" ]] || die "YANG cache install failed"
    fi
    rm -rf "${FRESH_REPO}"
    cp -a "${YANG_CACHE}" "${FRESH_REPO}"
    export SYSREPO_REPOSITORY_PATH="${FRESH_REPO}"
    export SYSREPO_SHM_DIR="${WORK_DIR}/shm/${shm_id}"
    rm -rf "${SYSREPO_SHM_DIR}"
    mkdir -p "${SYSREPO_SHM_DIR}"
}

import_base() {
    local f path
    local before=(hardware.xml qos-stack.xml voip-stack.xml platform-stack.xml network-vsubif.xml xpongemtcont-base.xml)
    local after=(forwarding-shell.xml keystore.xml truststore.xml system.xml device.xml datastore.xml subsys.xml netconf-server.xml lldp.xml)
    for f in "${before[@]}"; do
        path="${CONFIGS_DIR}/00-base/${f}"
        [[ -f "${path}" ]] || continue
        "${SYSREPOCFG_EXECUTABLE}" --edit="${path}" -d running -f xml >> "${LOG}" 2>&1 || log "warn: base ${f} failed"
    done
    if [[ -d "${CONFIGS_DIR}/00-base/onu-templates" ]]; then
        for path in "${CONFIGS_DIR}"/00-base/onu-templates/*.xml; do
            "${SYSREPOCFG_EXECUTABLE}" --edit="${path}" -d running -f xml >> "${LOG}" 2>&1 || log "warn: template failed"
        done
    fi
    for f in "${after[@]}"; do
        path="${CONFIGS_DIR}/00-base/${f}"
        [[ -f "${path}" ]] || continue
        "${SYSREPOCFG_EXECUTABLE}" --edit="${path}" -d running -f xml >> "${LOG}" 2>&1 || log "warn: base ${f} failed"
    done
}

if [[ "${PAIR_MODE}" == "editdiff" ]]; then
    export SR_VALIDATE_INCREMENTAL=1
    log "mode=editdiff SR_VALIDATE_INCREMENTAL=1"
else
    unset SR_VALIDATE_INCREMENTAL
    log "mode=full (SR_VALIDATE_INCREMENTAL unset)"
fi

fresh_repo "paired_${PAIR_MODE}_${PAIR_N}"

t_base0=$(date +%s.%N)
import_base
t_base1=$(date +%s.%N)
base_s=$(awk -v s="${t_base0}" -v e="${t_base1}" 'BEGIN { printf "%.3f", e-s }')
log "00-base wall=${base_s}s"
python3 "${SCRIPT_DIR}/verify_base_ready.py" --configs "${CONFIGS_DIR}" >> "${LOG}" 2>&1 \
    || die "base preflight failed"
echo "$(date -Iseconds),${PAIR_MODE},base,${PAIR_N},,,${base_s},,,,ok" >> "${CSV}"

tmp=$(mktemp)
t0=$(date +%s.%N)
set +e
"${SR_EDIT_FILES}" ${SR_EDIT_EXTRA} "${APPLY_FILES[@]}" > "${tmp}" 2>&1
onu_ok=$?
set -e
t1=$(date +%s.%N)
cat "${tmp}" >> "${LOG}"
onu_s=$(awk -v s="${t0}" -v e="${t1}" 'BEGIN { printf "%.3f", e-s }')
log "paired ONU wall=${onu_s}s rc=${onu_ok}"

python3 - "${tmp}" "${PER_EDIT}" "${CSV}" "${PAIR_MODE}" "${PAIR_N}" "${onu_ok}" "${onu_s}" "${PAIRS_OUT}" << 'PY'
import csv, re, sys
from pathlib import Path

tmp, per_path, csv_path, mode, n, rc, wall, pairs_path = sys.argv[1:9]
n = int(n)
rc = int(rc)
sn_by_rel = {}
for line in Path(pairs_path).read_text().splitlines():
    if not line.strip():
        continue
    idx, prov, svc = line.split("\t")
    sn_by_rel[prov] = (idx, "provision")
    if svc != "-":
        sn_by_rel[svc] = (idx, "service")

def classify(path):
    p = Path(path)
    rel = f"{p.parent.name}/{p.name}"
    if rel in sn_by_rel:
        return sn_by_rel[rel]
    if p.parent.name == "onu-provision":
        return "", "provision"
    if p.parent.name == "onu-service":
        return "", "service"
    return "", "unknown"

rows = []
with open(tmp) as f:
    for line in f:
        if not line.startswith("SR_EDIT "):
            continue
        m_idx = re.search(r"idx=(\d+)", line)
        m_t = re.search(r"apply=([0-9.]+)s", line)
        m_file = re.search(r"file=(\S+)", line)
        if not (m_idx and m_t and m_file):
            continue
        path = m_file.group(1)
        name = Path(path).name
        onu_idx, phase = classify(path)
        serial = name.split("-", 1)[1][:-4] if "-" in name and name.endswith(".xml") else name
        rows.append((mode, phase, onu_idx, serial, m_t.group(1), path))

with open(per_path, "a") as out:
    for r in rows:
        out.write(",".join(r) + "\n")

def first_mid_last(phase):
    vals = [float(r[4]) for r in rows if r[1] == phase]
    if not vals:
        return "0", "0", "0", 0
    mid = vals[(len(vals) + 1) // 2 - 1]
    return f"{vals[0]:.4f}", f"{mid:.4f}", f"{vals[-1]:.4f}", len(vals)

ts = __import__("datetime").datetime.now().astimezone().isoformat(timespec="seconds")
status = "ok" if rc == 0 else "fail"
with open(csv_path, "a") as out:
    for kind, phase in (("paired_provision", "provision"), ("paired_service", "service")):
        first, mid, last, count = first_mid_last(phase)
        total = sum(float(r[4]) for r in rows if r[1] == phase)
        out.write(f"{ts},{mode},{kind},{n},{count},,{total:.3f},{first},{mid},{last},{status}\n")
    out.write(f"{ts},{mode},paired_onu_wall,{n},,,{wall},,,,{status}\n")
print(f"per-edit rows={len(rows)} fail_rc={rc}")
for phase in ("provision", "service"):
    first, mid, last, count = first_mid_last(phase)
    print(f"{phase} n={count} first/mid/last_s {first} {mid} {last}")
PY
rm -f "${tmp}"

log "finished: $(date -Iseconds)"
log "csv: ${CSV}"
log "per-edit: ${PER_EDIT}"
log "log: ${LOG}"
[[ "${onu_ok}" -eq 0 ]]
