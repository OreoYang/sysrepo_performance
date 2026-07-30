#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

LOG="${RESULTS_DIR}/mode_s_d2.log"
EXPORT_XML="${RESULTS_DIR}/export.xml"
CSV="${RESULTS_DIR}/mode_s_d2.csv"
MIN_EXPORT_BYTES=1048576

mkdir -p "${RESULTS_DIR}"
: > "${LOG}"

log() { echo "$*" | tee -a "${LOG}"; }
die() { log "error: $*"; exit 1; }

log "=== Mode S D2: export from snapshot, timed import to fresh repo ==="
log "started: $(date -Iseconds)"

# --- Step A: export (not timed) ---
"${SCRIPT_DIR}/prep_largescale_db.sh" --force 2>&1 | tee -a "${LOG}"

log "Step A1: install YANG on snapshot repo (backup/restore .startup data)"
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

rm -f "${EXPORT_XML}"
log "Step A2: export running -> ${EXPORT_XML}"
"${SYSREPOCFG_EXECUTABLE}" --export="${EXPORT_XML}" -d running -f xml 2>&1 | tee -a "${LOG}" || {
    log "export failed; sysrepoctl -l:"
    "${SYSREPOCTL_EXECUTABLE}" -l 2>&1 | tee -a "${LOG}" || true
    die "sysrepocfg export failed"
}

if [[ ! -s "${EXPORT_XML}" ]]; then
    "${SYSREPOCTL_EXECUTABLE}" -l 2>&1 | tee -a "${LOG}" || true
    die "export.xml is empty"
fi

export_bytes=$(stat -c%s "${EXPORT_XML}")
log "export size: ${export_bytes} bytes"
if [[ "${export_bytes}" -lt "${MIN_EXPORT_BYTES}" ]]; then
    log "warning: export smaller than ${MIN_EXPORT_BYTES} bytes (expected large ONU config)"
fi

# --- Step B: timed import ---
rm -rf "${FRESH_REPO}"
mkdir -p "${FRESH_REPO}"
export SYSREPO_REPOSITORY_PATH="${FRESH_REPO}"
export SYSREPO_SHM_DIR="${WORK_DIR}/shm/fresh"

log "Step B1: install YANG on fresh repo"
"${SCRIPT_DIR}/install_yang_modules.sh" >> "${LOG}" 2>&1

log "Step B2: timed import"
start_ts=$(date +%s.%N)
set +e
"${SYSREPOCFG_EXECUTABLE}" --import="${EXPORT_XML}" -d running -f xml -n 2>&1 | tee -a "${LOG}"
import_rc=${PIPESTATUS[0]}
set -e
end_ts=$(date +%s.%N)
import_seconds=$(awk -v s="${start_ts}" -v e="${end_ts}" 'BEGIN { printf "%.3f", e - s }')

if [[ "${import_rc}" -eq 0 ]]; then
    status=ok
else
    status="import_failed_${import_rc}"
    log "warning: import exited ${import_rc} (often YANG revision skew vs field DB — see log)"
fi
timestamp=$(date -Iseconds)
log "import completed in ${import_seconds}s"

if [[ ! -f "${CSV}" ]]; then
    echo "timestamp,export_bytes,import_seconds,status" > "${CSV}"
fi
echo "${timestamp},${export_bytes},${import_seconds},${status}" >> "${CSV}"

log "results: ${CSV}"
log "finished: $(date -Iseconds)"
