#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${SYSREPO_REPOSITORY_PATH:-}" ]] || die "SYSREPO_REPOSITORY_PATH must be set"
[[ -d "${YANG_ROOT}" ]] || die "YANG root missing: ${YANG_ROOT}"
[[ -x "${SETUP_DATASTORE_SH}" ]] || die "setup script missing: ${SETUP_DATASTORE_SH}"

mkdir -p "${SYSREPO_REPOSITORY_PATH}"
export SYSREPO_REPOSITORY_PATH

if [[ -z "${SYSREPO_SHM_DIR:-}" ]]; then
    export SYSREPO_SHM_DIR="${WORK_DIR}/shm/$(basename "${SYSREPO_REPOSITORY_PATH}")"
fi
mkdir -p "${SYSREPO_SHM_DIR}"

export DESTDIR="${YANG_ROOT}"
export NP2_MODULE_PERMS=600

echo "Installing YANG modules into ${SYSREPO_REPOSITORY_PATH}"
echo "  DESTDIR=${DESTDIR}"
echo "  SYSREPO_SHM_DIR=${SYSREPO_SHM_DIR}"

# Only module schemas — do not run init_data.sh (would overwrite largescale config)
bash "${SETUP_DATASTORE_SH}"

echo "Installed modules ($("${SYSREPOCTL_EXECUTABLE}" -l | wc -l) lines from sysrepoctl -l)"
