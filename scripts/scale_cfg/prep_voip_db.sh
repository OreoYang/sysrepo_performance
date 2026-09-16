#!/usr/bin/env bash
# Extract db_1230_voip.tar, export running datastore, split into work_voip/configs/.
# Isolated from work/ (largescale) harness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

TARBALL="${SCRIPT_DIR}/db_1230_voip.tar"
VOIP_WORK="${SCRIPT_DIR}/work_voip"
SNAPSHOT_REPO="${VOIP_WORK}/db_1230_voip/upper/sysrepo"
EXPORT_XML="${VOIP_WORK}/export.xml"
CONFIGS_DIR="${VOIP_WORK}/configs"
FORCE=0
SKIP_SPLIT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f) FORCE=1; shift ;;
        --skip-split) SKIP_SPLIT=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--force] [--skip-split]"
            echo "  Extract voip DB, export XML, split to ${CONFIGS_DIR}/"
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -f "${TARBALL}" ]] || { echo "error: missing ${TARBALL}" >&2; exit 1; }

if [[ "${FORCE}" -eq 1 ]]; then
    rm -rf "${VOIP_WORK}"
fi
mkdir -p "${VOIP_WORK}"

if [[ ! -d "${SNAPSHOT_REPO}/data" ]]; then
    echo "Extracting ${TARBALL} -> ${VOIP_WORK}"
    tar -xf "${TARBALL}" -C "${VOIP_WORK}"
fi

[[ -d "${SNAPSHOT_REPO}" ]] || { echo "error: expected ${SNAPSHOT_REPO}" >&2; exit 1; }

echo "Cleaning stale sysrepo locks and pipes"
rm -f "${SNAPSHOT_REPO}"/sr_evpipe* "${SNAPSHOT_REPO}"/sr_main_lock 2>/dev/null || true
rm -rf "${SNAPSHOT_REPO}/conn" 2>/dev/null || true
mkdir -p "${SNAPSHOT_REPO}/conn"

startup_backup="${VOIP_WORK}/startup_backup"
rm -rf "${startup_backup}"
mkdir -p "${startup_backup}"
shopt -s nullglob
_startup_files=( "${SNAPSHOT_REPO}/data/"*.startup )
if [[ ${#_startup_files[@]} -gt 0 ]]; then
    mv "${SNAPSHOT_REPO}/data/"*.startup "${startup_backup}/"
fi
shopt -u nullglob

export SYSREPO_REPOSITORY_PATH="${SNAPSHOT_REPO}"
export SYSREPO_SHM_DIR="${VOIP_WORK}/shm/snapshot"
mkdir -p "${SYSREPO_SHM_DIR}"
"${SCRIPT_DIR}/install_yang_modules.sh"

if [[ -d "${startup_backup}" ]] && compgen -G "${startup_backup}/*.startup" >/dev/null; then
    mv "${startup_backup}/"*.startup "${SNAPSHOT_REPO}/data/"
fi
rmdir "${startup_backup}" 2>/dev/null || true

export SYSREPO_REPOSITORY_PATH="${SNAPSHOT_REPO}"
rm -rf "${VOIP_WORK}/shm/snapshot_export"
export SYSREPO_SHM_DIR="${VOIP_WORK}/shm/snapshot_export"
mkdir -p "${SYSREPO_SHM_DIR}"

if [[ ! -s "${EXPORT_XML}" || "${FORCE}" -eq 1 ]]; then
    rm -f "${EXPORT_XML}"
    echo "Exporting running -> ${EXPORT_XML}"
    "${SYSREPOCFG_EXECUTABLE}" --export="${EXPORT_XML}" -d running -f xml
fi

export_bytes=$(stat -c%s "${EXPORT_XML}")
echo "export size: ${export_bytes} bytes"

if [[ "${SKIP_SPLIT}" -eq 0 ]]; then
    hw="${YANG_ROOT}/init-data/ietf-hardware.xml"
    hw_arg=()
    [[ -f "${hw}" ]] && hw_arg=(--hardware "${hw}")
    echo "Splitting -> ${CONFIGS_DIR}"
    python3 "${SCRIPT_DIR}/split_export.py" --export "${EXPORT_XML}" --out "${CONFIGS_DIR}" "${hw_arg[@]}"
fi

echo "voip configs: ${CONFIGS_DIR}"
echo "manifest: ${CONFIGS_DIR}/manifest.json"
