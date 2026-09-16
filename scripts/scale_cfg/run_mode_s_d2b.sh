#!/usr/bin/env bash
# Mode S D2b: split export.xml -> base + ONU provision + service, timed incremental import.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

EXPORT_XML="${RESULTS_DIR}/export.xml"
CONFIGS_DIR="${WORK_DIR}/configs"
LOG="${RESULTS_DIR}/mode_s_d2b.log"
CSV="${RESULTS_DIR}/mode_s_d2b.csv"

mkdir -p "${RESULTS_DIR}"
: > "${LOG}"

log() { echo "$*" | tee -a "${LOG}"; }
die() { log "error: $*"; exit 1; }

import_file() {
    local label="$1"
    local file="$2"
    local mode="${3:-import}"
    if [[ "${mode}" == "edit" ]]; then
        if ! "${SYSREPOCFG_EXECUTABLE}" --edit="${file}" -d running -f xml 2>>"${LOG}"; then
            log "edit failed: ${label} (${file})"
            return 1
        fi
    elif ! "${SYSREPOCFG_EXECUTABLE}" --import="${file}" -d running -f xml 2>>"${LOG}"; then
        log "import failed: ${label} (${file})"
        return 1
    fi
    return 0
}

log "=== Mode S D2b: split export + incremental import ==="
log "started: $(date -Iseconds)"

if [[ ! -s "${EXPORT_XML}" ]]; then
    log "export.xml missing; running export step from run_mode_s_d2.sh logic"
    "${SCRIPT_DIR}/prep_largescale_db.sh" --force 2>&1 | tee -a "${LOG}"

    startup_backup="${WORK_DIR}/startup_backup"
    rm -rf "${startup_backup}"
    mkdir -p "${startup_backup}"
    shopt -s nullglob
    _startup_files=( "${SNAPSHOT_REPO}/data/"*.startup )
    if [[ ${#_startup_files[@]} -gt 0 ]]; then
        mv "${SNAPSHOT_REPO}/data/"*.startup "${startup_backup}/"
    fi
    shopt -u nullglob
    export SYSREPO_REPOSITORY_PATH="${SNAPSHOT_REPO}"
    export SYSREPO_SHM_DIR="${WORK_DIR}/shm/snapshot"
    "${SCRIPT_DIR}/install_yang_modules.sh" >> "${LOG}" 2>&1
    if [[ -d "${startup_backup}" ]] && compgen -G "${startup_backup}/*.startup" >/dev/null; then
        mv "${startup_backup}/"*.startup "${SNAPSHOT_REPO}/data/"
    fi
    rmdir "${startup_backup}" 2>/dev/null || true

    export SYSREPO_REPOSITORY_PATH="${SNAPSHOT_REPO}"
    rm -rf "${WORK_DIR}/shm/snapshot_export"
    export SYSREPO_SHM_DIR="${WORK_DIR}/shm/snapshot_export"
    mkdir -p "${SYSREPO_SHM_DIR}"
    "${SYSREPOCFG_EXECUTABLE}" --export="${EXPORT_XML}" -d running -f xml >> "${LOG}" 2>&1 \
        || die "export failed"
fi

if [[ "${SKIP_SPLIT:-0}" == "1" ]]; then
    log "Step A: skip split (SKIP_SPLIT=1), using existing ${CONFIGS_DIR}"
else
    log "Step A: split export.xml"
    python3 "${SCRIPT_DIR}/split_export.py" --export "${EXPORT_XML}" --out "${CONFIGS_DIR}" 2>&1 | tee -a "${LOG}"
fi
if [[ -n "${EXTEND_ONU_COUNT:-}" && "${EXTEND_ONU_COUNT}" -gt 0 ]]; then
    log "Step A.1: extend ${EXTEND_ONU_COUNT} synthetic ONUs"
    python3 "${SCRIPT_DIR}/extend_onu_configs.py" --configs "${CONFIGS_DIR}" --count "${EXTEND_ONU_COUNT}" --emit-rpc 2>&1 | tee -a "${LOG}"
fi

rm -rf "${FRESH_REPO}"
mkdir -p "${FRESH_REPO}"
export SYSREPO_REPOSITORY_PATH="${FRESH_REPO}"
export SYSREPO_SHM_DIR="${WORK_DIR}/shm/fresh_d2b"
rm -rf "${SYSREPO_SHM_DIR}"
mkdir -p "${SYSREPO_SHM_DIR}"

log "Step B1: install YANG on fresh repo"
"${SCRIPT_DIR}/install_yang_modules.sh" >> "${LOG}" 2>&1

base_order_before_templates=(
    hardware.xml
    qos-stack.xml
    voip-stack.xml
    platform-stack.xml
    network-vsubif.xml
    xpongemtcont-base.xml
)
base_order_after_templates=(
    forwarding-shell.xml
    keystore.xml
    truststore.xml
    system.xml
    device.xml
    datastore.xml
    subsys.xml
    netconf-server.xml
    lldp.xml
)

import_base_file() {
    local rel="$1"
    local path="$2"
    log "  base: ${rel}"
    import_file "base:${rel}" "${path}" edit || base_fail=$((base_fail + 1))
}

log "Step B2: import base configs (not timed, merge via --edit)"
base_fail=0
for f in "${base_order_before_templates[@]}"; do
    path="${CONFIGS_DIR}/00-base/${f}"
    [[ -f "${path}" ]] && import_base_file "${f}" "${path}"
done
if [[ -d "${CONFIGS_DIR}/00-base/onu-templates" ]]; then
    shopt -s nullglob
    for path in "${CONFIGS_DIR}"/00-base/onu-templates/*.xml; do
        rel="onu-templates/$(basename "${path}")"
        import_base_file "${rel}" "${path}"
    done
    shopt -u nullglob
elif [[ -f "${CONFIGS_DIR}/00-base/onu-templates.xml" ]]; then
    import_base_file "onu-templates.xml" "${CONFIGS_DIR}/00-base/onu-templates.xml"
fi
for f in "${base_order_after_templates[@]}"; do
    path="${CONFIGS_DIR}/00-base/${f}"
    [[ -f "${path}" ]] && import_base_file "${f}" "${path}"
done
if [[ "${base_fail}" -gt 0 ]]; then
    log "warning: base import had ${base_fail} failure(s); continuing incremental test (see ${LOG})"
fi

log "Step B2.5: preflight — verify chpart/chpair/templates in running before ONU provision"
if ! python3 "${SCRIPT_DIR}/verify_base_ready.py" --configs "${CONFIGS_DIR}" 2>&1 | tee -a "${LOG}"; then
    die "base preflight failed; fix base import before running onu-provision/*.xml (see ${LOG})"
fi

log "Step B3: timed ONU provision imports"
provision_fail=0
provision_ok=0
start_provision=$(date +%s.%N)
shopt -s nullglob
for f in "${CONFIGS_DIR}"/onu-provision/*.xml; do
    if import_file "provision:$(basename "${f}")" "${f}" edit; then
        provision_ok=$((provision_ok + 1))
    else
        provision_fail=$((provision_fail + 1))
        if [[ "${provision_fail}" -le 5 ]]; then
            log "  first failures logged above; continuing"
        fi
    fi
done
shopt -u nullglob
end_provision=$(date +%s.%N)
provision_seconds=$(awk -v s="${start_provision}" -v e="${end_provision}" 'BEGIN { printf "%.3f", e - s }')

log "Step B4: timed ONU service imports"
service_fail=0
service_ok=0
start_service=$(date +%s.%N)
shopt -s nullglob
for f in "${CONFIGS_DIR}"/onu-service/*.xml; do
    if import_file "service:$(basename "${f}")" "${f}" edit; then
        service_ok=$((service_ok + 1))
    else
        service_fail=$((service_fail + 1))
    fi
done
shopt -u nullglob
end_service=$(date +%s.%N)
service_seconds=$(awk -v s="${start_service}" -v e="${end_service}" 'BEGIN { printf "%.3f", e - s }')

total_seconds=$(awk -v a="${provision_seconds}" -v b="${service_seconds}" 'BEGIN { printf "%.3f", a + b }')

if [[ "${provision_fail}" -eq 0 && "${service_fail}" -eq 0 ]]; then
    status=ok
elif [[ "${provision_fail}" -gt 0 ]]; then
    status="provision_failed_${provision_fail}"
else
    status="service_failed_${service_fail}"
fi

timestamp=$(date -Iseconds)
log "provision: ok=${provision_ok} fail=${provision_fail} time=${provision_seconds}s"
log "service: ok=${service_ok} fail=${service_fail} time=${service_seconds}s"
log "incremental total: ${total_seconds}s status=${status}"

if [[ ! -f "${CSV}" ]]; then
    echo "timestamp,provision_ok,provision_fail,provision_seconds,service_ok,service_fail,service_seconds,status" > "${CSV}"
fi
echo "${timestamp},${provision_ok},${provision_fail},${provision_seconds},${service_ok},${service_fail},${service_seconds},${status}" >> "${CSV}"

log "results: ${CSV}"
log "configs: ${CONFIGS_DIR}"
log "finished: $(date -Iseconds)"
