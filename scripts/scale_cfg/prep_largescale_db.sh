#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repo_paths.sh
source "${SCRIPT_DIR}/lib/repo_paths.sh"

FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f) FORCE=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--force]"
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -f "${TARBALL}" ]] || { echo "error: missing ${TARBALL}" >&2; exit 1; }

if [[ -d "${WORK_DIR}/var_db" && "${FORCE}" -eq 0 ]]; then
    echo "work/ already exists; use --force to re-extract"
    exit 0
fi

echo "Extracting ${TARBALL} -> ${WORK_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
tar -xf "${TARBALL}" -C "${WORK_DIR}"

SYSREPO_DIR="${SNAPSHOT_REPO}"
[[ -d "${SYSREPO_DIR}" ]] || { echo "error: expected ${SYSREPO_DIR}" >&2; exit 1; }

echo "Cleaning stale sysrepo locks and pipes"
rm -f "${SYSREPO_DIR}"/sr_evpipe* "${SYSREPO_DIR}"/sr_main_lock 2>/dev/null || true
rm -rf "${SYSREPO_DIR}/conn" 2>/dev/null || true
mkdir -p "${SYSREPO_DIR}/conn"

echo "Snapshot repo: ${SYSREPO_DIR}"
ls -la "${SYSREPO_DIR}/data/" | head -20
