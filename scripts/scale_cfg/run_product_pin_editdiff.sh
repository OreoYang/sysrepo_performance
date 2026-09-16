#!/usr/bin/env bash
# Product-pin 3.7.11 + 3.9.13 with incremental validation (SR_VALIDATE_INCREMENTAL).
# Same harness as product-pin baseline. Default A/B both modes at N=1022 and 1522.
#
# Env: AB_N_LIST (default "1022 1522"), AB_MODE (default both), AB_APPEND=1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCALECFG_RUNTIME_DIR="${SCALECFG_RUNTIME_DIR:-${SCRIPT_DIR}/.local/runtime-yocto-editdiff}"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

export N_SERIAL=0 N_LATE=0 N_LATE2=0 N_LATE3=0
export AB_MODE="${AB_MODE:-both}"
export AB_N_LIST="${AB_N_LIST:-1022 1522}"
export SR_EDIT_FILES="${SR_EDIT_FILES:-${SCRIPT_DIR}/.local/bin/sr_edit_files_yocto_editdiff}"
export YANG_CACHE="${YANG_CACHE:-${WORK_DIR}/yang_installed_repo_yocto3711}"
export LOG="${LOG:-${RESULTS_DIR}/ab_validate_product_pin_editdiff.log}"
export CSV="${CSV:-${RESULTS_DIR}/ab_validate_product_pin_editdiff.csv}"
export PER_EDIT="${PER_EDIT:-${RESULTS_DIR}/ab_validate_product_pin_editdiff_per_edit.csv}"

[[ -x "${SR_EDIT_FILES}" ]] || {
    echo "error: ${SR_EDIT_FILES} missing; stage + compile first" >&2
    exit 1
}

mkdir -p "${RESULTS_DIR}"
echo "=== product pin edit-diff AB_N_LIST=${AB_N_LIST} AB_MODE=${AB_MODE} AB_APPEND=${AB_APPEND:-} ==="
echo "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1
echo "libyang so: $(ldd "${SYSREPOCFG_EXECUTABLE}" | awk '/libyang/{print $3}')"
if [[ -f "${SCALECFG_RUNTIME_DIR}/usr/include/libyang/version.h" ]]; then
    grep 'define LY_VERSION ' "${SCALECFG_RUNTIME_DIR}/usr/include/libyang/version.h"
fi
nm -D "${SCALECFG_RUNTIME_DIR}/usr/lib/libyang.so" | grep -q lyd_validate_module_incr \
    || { echo "error: libyang missing lyd_validate_module_incr" >&2; exit 1; }

"${SCRIPT_DIR}/ab_validate_edit_diff.sh"
