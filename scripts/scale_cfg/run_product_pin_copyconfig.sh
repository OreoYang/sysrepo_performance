#!/usr/bin/env bash
# Product-pin copy-config A/B: each ONU XML is merged into running then sr_replace_config.
# Same N list and SR_VALIDATE_INCREMENTAL switch as the edit-config harness.
#
# Env: AB_N_LIST (default "1022 1522"), AB_MODE (default both)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCALECFG_RUNTIME_DIR="${SCALECFG_RUNTIME_DIR:-${SCRIPT_DIR}/.local/runtime-yocto-editdiff}"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

export N_SERIAL=0 N_LATE=0 N_LATE2=0 N_LATE3=0
export AB_MODE="${AB_MODE:-both}"
export AB_N_LIST="${AB_N_LIST:-1022 1522}"
export SR_EDIT_FILES="${SR_EDIT_FILES:-${SCRIPT_DIR}/.local/bin/sr_edit_files_yocto_editdiff}"
export SR_EDIT_EXTRA="${SR_EDIT_EXTRA:---replace}"
export YANG_CACHE="${YANG_CACHE:-${WORK_DIR}/yang_installed_repo_yocto3711}"
export LOG="${LOG:-${RESULTS_DIR}/ab_validate_product_pin_copyconfig.log}"
export CSV="${CSV:-${RESULTS_DIR}/ab_validate_product_pin_copyconfig.csv}"
export PER_EDIT="${PER_EDIT:-${RESULTS_DIR}/ab_validate_product_pin_copyconfig_per_edit.csv}"

[[ -x "${SR_EDIT_FILES}" ]] || {
    echo "error: ${SR_EDIT_FILES} missing; stage + compile first" >&2
    exit 1
}

mkdir -p "${RESULTS_DIR}"
echo "=== product pin copy-config AB_N_LIST=${AB_N_LIST} AB_MODE=${AB_MODE} ==="
echo "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1
echo "libyang so: $(ldd "${SYSREPOCFG_EXECUTABLE}" | awk '/libyang/{print $3}')"
nm -D "${SCALECFG_RUNTIME_DIR}/usr/lib/libyang.so" | grep -q lyd_validate_module_incr \
    || { echo "error: libyang missing lyd_validate_module_incr" >&2; exit 1; }

"${SCRIPT_DIR}/ab_validate_edit_diff.sh"
