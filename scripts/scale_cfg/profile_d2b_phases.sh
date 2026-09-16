#!/usr/bin/env bash
# Profile D2b late-ONU edit phases (JSON vs SRBF) and optional batch apply.
#
# Fast path: load base, batch-apply first N-1 ONUs, then one profiled incremental edit.
# Also times serial vs batch for a smaller N.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

LOG="${RESULTS_DIR}/profile_phases.log"
CSV="${RESULTS_DIR}/profile_phases.csv"
CONFIGS_DIR="${WORK_DIR}/configs"
EXPORT_XML="${RESULTS_DIR}/export.xml"
N_LATE="${N_LATE:-100}"
N_LATE2="${N_LATE2:-300}"
N_SERIAL_VS_BATCH="${N_SERIAL_VS_BATCH:-50}"
SR_EDIT_FILES="${SCRIPT_DIR}/.local/bin/sr_edit_files"

log() { echo "$*" | tee -a "${LOG}"; }
die() { log "error: $*"; exit 1; }

mkdir -p "${RESULTS_DIR}" "${SCRIPT_DIR}/.local/bin"
# Keep previous profile log as .prev; this run starts clean.
if [[ -f "${LOG}" ]]; then
    mv -f "${LOG}" "${LOG}.prev"
fi
: > "${LOG}"

log "=== D2b phase profile + SRBF A/B ==="
log "started: $(date -Iseconds)"
log "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1 | tee -a "${LOG}"

[[ -x "${SR_EDIT_FILES}" ]] || die "sr_edit_files missing at ${SR_EDIT_FILES} (build it first)"

if [[ ! -d "${CONFIGS_DIR}/onu-provision" ]]; then
    [[ -s "${EXPORT_XML}" ]] || die "export.xml missing"
    log "splitting export.xml"
    python3 "${SCRIPT_DIR}/split_export.py" --export "${EXPORT_XML}" --out "${CONFIGS_DIR}" 2>&1 | tee -a "${LOG}"
fi

mapfile -t PROV_FILES < <(ls -1 "${CONFIGS_DIR}"/onu-provision/*.xml)
mapfile -t SVC_FILES < <(ls -1 "${CONFIGS_DIR}"/onu-service/*.xml)
log "provision files: ${#PROV_FILES[@]} service files: ${#SVC_FILES[@]}"

YANG_CACHE="${WORK_DIR}/yang_installed_repo"

fresh_repo() {
    local shm_id="${1:-profile}"

    if [[ ! -d "${YANG_CACHE}/yang" ]]; then
        log "  installing YANG into cache ${YANG_CACHE}"
        rm -rf "${YANG_CACHE}" "${WORK_DIR}/shm/yang_cache"
        mkdir -p "${YANG_CACHE}" "${WORK_DIR}/shm/yang_cache"
        export SYSREPO_REPOSITORY_PATH="${YANG_CACHE}"
        export SYSREPO_SHM_DIR="${WORK_DIR}/shm/yang_cache"
        "${SCRIPT_DIR}/install_yang_modules.sh" >> "${LOG}" 2>&1 || log "warn: yang install reported errors (continuing if modules exist)"
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
    local before=(hardware.xml qos-stack.xml platform-stack.xml network-vsubif.xml xpongemtcont-base.xml)
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

# $1 = N (populate N-1 then profile Nth service)
# $2 = SR_DS_FORMAT (json|srbf)
profile_late() {
    local n="$1"
    local fmt="$2"
    local n1 label
    n1=$((n - 1))
    [[ "${n1}" -ge 1 ]] || n1=1
    [[ "${n}" -le "${#SVC_FILES[@]}" ]] || die "N=${n} > service files ${#SVC_FILES[@]}"
    label="late${n}_${fmt}"
    log "--- ${label}: batch populate ${n1} + provision #${n} (JSON), profile service #${n} fmt=${fmt} ---"
    unset SR_PROFILE_EDIT
    # Always populate with JSON. SRBF-only persist is still lossy on XPON trees.
    export SR_DS_FORMAT=json
    fresh_repo "profile_${label}"
    import_base
    python3 "${SCRIPT_DIR}/verify_base_ready.py" --configs "${CONFIGS_DIR}" >> "${LOG}" 2>&1 || die "base preflight failed"

    log "  batch provision 1..${n}"
    "${SR_EDIT_FILES}" --batch "${PROV_FILES[@]:0:${n}}" >> "${LOG}" 2>&1 || die "batch provision failed (${label})"
    log "  batch service 1..${n1}"
    "${SR_EDIT_FILES}" --batch "${SVC_FILES[@]:0:${n1}}" >> "${LOG}" 2>&1 || die "batch service failed (${label})"

    if [[ "${fmt}" == "srbf" ]]; then
        export SR_DS_FORMAT=both
    else
        export SR_DS_FORMAT=json
    fi

    export SR_PROFILE_EDIT=1
    log "  profiled incremental service #${n} fmt=${fmt}"
    local t0 t1
    t0=$(date +%s.%N)
    if SR_PROFILE_EDIT=1 "${SYSREPOCFG_EXECUTABLE}" --edit="${SVC_FILES[$((n - 1))]}" -d running -f xml >> "${LOG}" 2>&1; then
        t1=$(date +%s.%N)
        awk -v s="${t0}" -v e="${t1}" -v n="${n}" -v fmt="${fmt}" 'BEGIN { printf "late_edit n=%d fmt=%s wall=%.3fs\n", n, fmt, e-s }' | tee -a "${LOG}"
    else
        t1=$(date +%s.%N)
        awk -v s="${t0}" -v e="${t1}" -v n="${n}" -v fmt="${fmt}" 'BEGIN { printf "late_edit n=%d fmt=%s wall=%.3fs status=failed\n", n, fmt, e-s }' | tee -a "${LOG}"
        log "  profiled edit FAILED (${label}) — SR_PROFILE lines above still valid if validate ran"
    fi
    unset SR_PROFILE_EDIT
}

serial_vs_batch() {
    local n="$1"
    local t0 t1 serial_s batch_s
    [[ "${n}" -le "${#SVC_FILES[@]}" ]] || n="${#SVC_FILES[@]}"
    log "--- serial vs batch N=${n} (JSON) ---"
    export SR_DS_FORMAT=json
    unset SR_PROFILE_EDIT

    fresh_repo "serial_${n}"
    import_base
    python3 "${SCRIPT_DIR}/verify_base_ready.py" --configs "${CONFIGS_DIR}" >> "${LOG}" 2>&1 || die "base preflight failed"
    t0=$(date +%s.%N)
    "${SR_EDIT_FILES}" "${PROV_FILES[@]:0:${n}}" >> "${LOG}" 2>&1 || log "warn: serial provision had failures"
    "${SR_EDIT_FILES}" "${SVC_FILES[@]:0:${n}}" >> "${LOG}" 2>&1 || log "warn: serial service had failures"
    t1=$(date +%s.%N)
    serial_s=$(awk -v s="${t0}" -v e="${t1}" 'BEGIN { printf "%.3f", e-s }')
    log "serial N=${n} total=${serial_s}s"

    fresh_repo "batch_${n}"
    import_base
    python3 "${SCRIPT_DIR}/verify_base_ready.py" --configs "${CONFIGS_DIR}" >> "${LOG}" 2>&1 || die "base preflight failed"
    t0=$(date +%s.%N)
    "${SR_EDIT_FILES}" --batch "${PROV_FILES[@]:0:${n}}" >> "${LOG}" 2>&1 || log "warn: batch provision failed"
    "${SR_EDIT_FILES}" --batch "${SVC_FILES[@]:0:${n}}" >> "${LOG}" 2>&1 || log "warn: batch service failed"
    t1=$(date +%s.%N)
    batch_s=$(awk -v s="${t0}" -v e="${t1}" 'BEGIN { printf "%.3f", e-s }')
    log "batch  N=${n} total=${batch_s}s"
    awk -v n="${n}" -v s="${serial_s}" -v b="${batch_s}" 'BEGIN {
        printf "serial_vs_batch n=%d serial=%.3fs batch=%.3fs speedup=%.2fx\n", n, s, b, (b>0?s/b:0)
    }' | tee -a "${LOG}"
}

profile_late "${N_LATE}" json
profile_late "${N_LATE}" srbf
if [[ "${N_LATE2}" -gt "${N_LATE}" ]]; then
    profile_late "${N_LATE2}" json
    profile_late "${N_LATE2}" srbf
fi
serial_vs_batch "${N_SERIAL_VS_BATCH}"

log "finished: $(date -Iseconds)"
log "log: ${LOG}"
