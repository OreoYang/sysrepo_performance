#!/usr/bin/env bash
# A/B: full-module YANG validation vs SR_VALIDATE_INCREMENTAL=1 (same binary).
#
# Default: serial N=40 provision+service, plus late single service edit at N=50 and N=100.
# Env: N_SERIAL (default 40), N_LATE (default 50), N_LATE2 (default 100)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

LOG="${LOG:-${RESULTS_DIR}/ab_validate_edit_diff.log}"
CSV="${CSV:-${RESULTS_DIR}/ab_validate_edit_diff.csv}"
PER_EDIT="${PER_EDIT:-${RESULTS_DIR}/ab_validate_edit_diff_per_edit.csv}"
CONFIGS_DIR="${CONFIGS_DIR:-${WORK_DIR}/configs}"
EXPORT_XML="${RESULTS_DIR}/export.xml"
# Env: N_SERIAL (0=skip), N_LATES="200 300 500" or N_LATE/N_LATE2
# Optional ordered scale run (skips default N_SERIAL / late edits):
#   AB_N_LIST="1022 1522"  — serial provision+service for each N
#   AB_MODE=editdiff|full|both  (default both when AB_N_LIST unset)
N_SERIAL="${N_SERIAL:-40}"
N_LATE="${N_LATE:-50}"
N_LATE2="${N_LATE2:-100}"
N_LATE3="${N_LATE3:-0}"
AB_N_LIST="${AB_N_LIST:-}"
AB_MODE="${AB_MODE:-both}"
SR_EDIT_FILES="${SR_EDIT_FILES:-${SCRIPT_DIR}/.local/bin/sr_edit_files}"
SR_EDIT_EXTRA="${SR_EDIT_EXTRA:-}"

log() { echo "$*" | tee -a "${LOG}"; }
die() { log "error: $*"; exit 1; }

mkdir -p "${RESULTS_DIR}"
if [[ "${N_SERIAL}" -eq 0 && -z "${AB_N_LIST}" ]]; then
    LOG="${RESULTS_DIR}/ab_validate_edit_diff_scale.log"
    CSV="${RESULTS_DIR}/ab_validate_edit_diff_scale.csv"
    PER_EDIT="${RESULTS_DIR}/ab_validate_edit_diff_scale_per_edit.csv"
fi
if [[ -z "${AB_APPEND:-}" ]]; then
    if [[ -f "${LOG}" ]]; then
        mv -f "${LOG}" "${LOG}.prev"
    fi
    : > "${LOG}"
    echo "mode,phase,idx,apply_s,file" > "${PER_EDIT}"
    echo "timestamp,mode,kind,n,ok,fail,seconds,first_s,mid_s,last_s,status" > "${CSV}"
fi

log "=== A/B full validate vs SR_VALIDATE_INCREMENTAL=1 ==="
log "started: $(date -Iseconds)"
log "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1 | tee -a "${LOG}"
log "sr_edit_files: ${SR_EDIT_FILES} ${SR_EDIT_EXTRA}"
[[ -x "${SR_EDIT_FILES}" ]] || die "sr_edit_files missing at ${SR_EDIT_FILES}"

if [[ ! -d "${CONFIGS_DIR}/onu-provision" ]]; then
    [[ -s "${EXPORT_XML}" ]] || die "export.xml missing"
    log "splitting export.xml"
    python3 "${SCRIPT_DIR}/split_export.py" --export "${EXPORT_XML}" --out "${CONFIGS_DIR}" 2>&1 | tee -a "${LOG}"
fi

mapfile -t PROV_FILES < <(ls -1 "${CONFIGS_DIR}"/onu-provision/*.xml)
mapfile -t SVC_FILES < <(ls -1 "${CONFIGS_DIR}"/onu-service/*.xml)
log "provision files: ${#PROV_FILES[@]} service files: ${#SVC_FILES[@]}"

YANG_CACHE="${YANG_CACHE:-${WORK_DIR}/yang_installed_repo}"

fresh_repo() {
    local shm_id="${1:-ab}"

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

set_mode() {
    local mode="$1"
    if [[ "${mode}" == "editdiff" ]]; then
        export SR_VALIDATE_INCREMENTAL=1
        log "  mode=editdiff SR_VALIDATE_INCREMENTAL=1"
    else
        unset SR_VALIDATE_INCREMENTAL
        log "  mode=full (SR_VALIDATE_INCREMENTAL unset)"
    fi
}

parse_serial() {
    local mode="$1"
    local phase="$2"
    local tmp="$3"
    grep '^SR_EDIT ' "${tmp}" | awk -v mode="${mode}" -v phase="${phase}" '
    {
        idx=""; t=""; file="";
        for (i=1;i<=NF;i++) {
            if ($i ~ /^idx=/) { split($i,a,"="); idx=a[2] }
            if ($i ~ /^apply=/) { split($i,a,"="); t=a[2]; sub(/s$/,"",t) }
            if ($i ~ /^file=/) { file=substr($i,6) }
        }
        if (idx!="" && t!="") printf "%s,%s,%s,%s,%s\n", mode, phase, idx, t, file
    }' >> "${PER_EDIT}"
}

# first/mid/last from this run's sr_edit_files log, not cumulative PER_EDIT
# (AB_N_LIST with multiple N, or AB_APPEND=1, would otherwise steal first/mid from earlier runs).
summarize_from_tmp() {
    local tmp="$1"
    grep '^SR_EDIT ' "${tmp}" | awk '
    {
        t="";
        for (i=1;i<=NF;i++) {
            if ($i ~ /^apply=/) { split($i,a,"="); t=a[2]; sub(/s$/,"",t) }
        }
        if (t!="") { n++; v[n]=t }
    }
    END {
        if (n==0) { print "0,0,0"; exit }
        printf "%s,%s,%s", v[1], v[int((n+1)/2)], v[n]
    }'
}

run_serial() {
    local mode="$1"
    local n="$2"
    local tmp prov_s svc_s t0 t1 prov_n svc_n
    local prov_ok svc_ok psum ssum st_p st_s
    prov_n="${n}"
    svc_n="${n}"
    [[ "${prov_n}" -gt "${#PROV_FILES[@]}" ]] && prov_n="${#PROV_FILES[@]}"
    [[ "${svc_n}" -gt "${#SVC_FILES[@]}" ]] && svc_n="${#SVC_FILES[@]}"
    log "--- serial N=${n} (prov=${prov_n} svc=${svc_n}) mode=${mode} ---"
    set_mode "${mode}"
    fresh_repo "ab_serial_${mode}_${n}"
    import_base
    python3 "${SCRIPT_DIR}/verify_base_ready.py" --configs "${CONFIGS_DIR}" >> "${LOG}" 2>&1 \
        || die "base preflight failed"

    tmp=$(mktemp)
    t0=$(date +%s.%N)
    set +e
    "${SR_EDIT_FILES}" ${SR_EDIT_EXTRA} "${PROV_FILES[@]:0:${prov_n}}" > "${tmp}" 2>&1
    prov_ok=$?
    set -e
    t1=$(date +%s.%N)
    cat "${tmp}" >> "${LOG}"
    parse_serial "${mode}" provision "${tmp}"
    psum=$(summarize_from_tmp "${tmp}")
    prov_s=$(awk -v s="${t0}" -v e="${t1}" 'BEGIN { printf "%.3f", e-s }')
    log "serial provision N=${n} prov_files=${prov_n} mode=${mode} total=${prov_s}s rc=${prov_ok}"

    : > "${tmp}"
    t0=$(date +%s.%N)
    set +e
    "${SR_EDIT_FILES}" ${SR_EDIT_EXTRA} "${SVC_FILES[@]:0:${svc_n}}" > "${tmp}" 2>&1
    svc_ok=$?
    set -e
    t1=$(date +%s.%N)
    cat "${tmp}" >> "${LOG}"
    parse_serial "${mode}" service "${tmp}"
    ssum=$(summarize_from_tmp "${tmp}")
    svc_s=$(awk -v s="${t0}" -v e="${t1}" 'BEGIN { printf "%.3f", e-s }')
    log "serial service N=${n} svc_files=${svc_n} mode=${mode} total=${svc_s}s rc=${svc_ok}"
    rm -f "${tmp}"

    st_p=$([ "${prov_ok}" -eq 0 ] && echo ok || echo fail)
    st_s=$([ "${svc_ok}" -eq 0 ] && echo ok || echo fail)
    echo "$(date -Iseconds),${mode},serial_provision,${n},,,${prov_s},${psum},${st_p}" >> "${CSV}"
    echo "$(date -Iseconds),${mode},serial_service,${n},,,${svc_s},${ssum},${st_s}" >> "${CSV}"
}

run_late() {
    local mode="$1"
    local n="$2"
    local n1 t0 t1 wall rc
    n1=$((n - 1))
    [[ "${n1}" -ge 1 ]] || n1=1
    [[ "${n}" -le "${#SVC_FILES[@]}" ]] || die "N=${n} > service files"
    log "--- late service #${n} mode=${mode} (serial editdiff populate ${n} provision + ${n1} service) ---"
    unset SR_VALIDATE_INCREMENTAL
    fresh_repo "ab_late_${mode}_${n}"
    import_base
    python3 "${SCRIPT_DIR}/verify_base_ready.py" --configs "${CONFIGS_DIR}" >> "${LOG}" 2>&1 \
        || die "base preflight failed"
    export SR_VALIDATE_INCREMENTAL=1
    log "  serial provision 1..${n} (editdiff populate)"
    "${SR_EDIT_FILES}" ${SR_EDIT_EXTRA} "${PROV_FILES[@]:0:${n}}" >> "${LOG}" 2>&1 || die "serial provision populate failed"
    log "  serial service 1..${n1} (editdiff populate)"
    "${SR_EDIT_FILES}" ${SR_EDIT_EXTRA} "${SVC_FILES[@]:0:${n1}}" >> "${LOG}" 2>&1 || die "serial service populate failed"

    set_mode "${mode}"
    t0=$(date +%s.%N)
    set +e
    "${SYSREPOCFG_EXECUTABLE}" --edit="${SVC_FILES[$((n - 1))]}" -d running -f xml >> "${LOG}" 2>&1
    rc=$?
    set -e
    t1=$(date +%s.%N)
    wall=$(awk -v s="${t0}" -v e="${t1}" 'BEGIN { printf "%.4f", e-s }')
    log "late_edit n=${n} mode=${mode} wall=${wall}s rc=${rc}"
    echo "$(date -Iseconds),${mode},late_service,${n},$([ ${rc} -eq 0 ] && echo 1 || echo 0),${rc},${wall},,,,$( [ ${rc} -eq 0 ] && echo ok || echo fail)" >> "${CSV}"
}

if [[ -n "${AB_N_LIST}" ]]; then
    log "AB_N_LIST=${AB_N_LIST} AB_MODE=${AB_MODE}"
    for n in ${AB_N_LIST}; do
        case "${AB_MODE}" in
            editdiff)
                run_serial editdiff "${n}"
                ;;
            full)
                run_serial full "${n}"
                ;;
            both)
                run_serial full "${n}"
                run_serial editdiff "${n}"
                ;;
            *)
                die "AB_MODE must be editdiff, full, or both"
                ;;
        esac
    done
elif [[ "${N_SERIAL}" -gt 0 ]]; then
    run_serial full "${N_SERIAL}"
    run_serial editdiff "${N_SERIAL}"
fi

if [[ -z "${AB_N_LIST}" ]]; then
    lates=("${N_LATE}")
    [[ "${N_LATE2}" -gt 0 ]] && lates+=("${N_LATE2}")
    [[ "${N_LATE3}" -gt 0 ]] && lates+=("${N_LATE3}")
    prev=0
    for n in "${lates[@]}"; do
        [[ "${n}" -gt "${prev}" ]] || continue
        run_late full "${n}"
        run_late editdiff "${n}"
        prev="${n}"
    done
fi

log "--- summary ---"
python3 - "${CSV}" "${PER_EDIT}" << 'PY' | tee -a "${LOG}"
import csv, sys
from collections import defaultdict

csv_path, per_path = sys.argv[1], sys.argv[2]
print("kind,mode,n,seconds,first_s,mid_s,last_s,status")
rows = list(csv.DictReader(open(csv_path)))
for r in rows:
    print("{kind},{mode},{n},{seconds},{first_s},{mid_s},{last_s},{status}".format(**r))

print("")
print("service per-edit (serial): idx  full_s  editdiff_s  speedup")
by = defaultdict(dict)
try:
    with open(per_path) as f:
        for r in csv.DictReader(f):
            if r.get("phase") != "service":
                continue
            by[int(r["idx"])][r["mode"]] = float(r["apply_s"])
except FileNotFoundError:
    pass
if not by:
    print("(no serial per-edit rows)")
for idx in sorted(by):
    full = by[idx].get("full")
    ed = by[idx].get("editdiff")
    if full is None or ed is None:
        continue
    sp = (full / ed) if ed else 0
    print(f"{idx:4d}  {full:7.4f}  {ed:10.4f}  {sp:6.2f}x")
PY

log "finished: $(date -Iseconds)"
log "csv: ${CSV}"
log "per-edit: ${PER_EDIT}"
log "log: ${LOG}"
