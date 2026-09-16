#!/usr/bin/env bash
# Product-pin baseline: Yocto sysrepo 3.7.11 + libyang (recipe 3.13.5 / LY_VERSION 3.9.13).
# Serial provision+service at N=1022 and N=1522 (service capped at 1516 files).
# Same harness as A/B (sr_edit_files, persistent session). Does not overwrite private 4.5.4 runtime.
#
# Env: AB_N_LIST (default "1022 1522"), AB_APPEND=1 to add rows without resetting CSV.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCALECFG_RUNTIME_DIR="${SCRIPT_DIR}/.local/runtime-yocto"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

export N_SERIAL=0 N_LATE=0 N_LATE2=0 N_LATE3=0
export AB_MODE=full
export AB_N_LIST="${AB_N_LIST:-1022 1522}"
export SR_EDIT_FILES="${SCRIPT_DIR}/.local/bin/sr_edit_files_yocto"
export YANG_CACHE="${WORK_DIR}/yang_installed_repo_yocto3711"
export LOG="${RESULTS_DIR}/ab_validate_product_pin.log"
export CSV="${RESULTS_DIR}/ab_validate_product_pin.csv"
export PER_EDIT="${RESULTS_DIR}/ab_validate_product_pin_per_edit.csv"
unset SR_VALIDATE_EDIT_DIFF

[[ -x "${SR_EDIT_FILES}" ]] || {
    echo "error: ${SR_EDIT_FILES} missing; compile against Yocto runtime first" >&2
    exit 1
}

mkdir -p "${RESULTS_DIR}"
echo "=== product pin baseline AB_N_LIST=${AB_N_LIST} AB_APPEND=${AB_APPEND:-} ==="
echo "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1
echo "libyang so: $(ldd "${SYSREPOCFG_EXECUTABLE}" | awk '/libyang/{print $3}')"
if [[ -f "${SCALECFG_RUNTIME_DIR}/usr/include/libyang/version.h" ]]; then
    grep 'define LY_VERSION ' "${SCALECFG_RUNTIME_DIR}/usr/include/libyang/version.h"
fi

"${SCRIPT_DIR}/ab_validate_edit_diff.sh"
