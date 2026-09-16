#!/usr/bin/env bash
# Product-pin 3.7.11 + 3.9.13: 00-base then per-ONU provision+service paired by SN.
# Incremental on. PAIR_N=1 first to verify order; PAIR_N=1022 for scale timing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCALECFG_RUNTIME_DIR="${SCALECFG_RUNTIME_DIR:-${SCRIPT_DIR}/.local/runtime-yocto-editdiff}"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

export PAIR_N="${PAIR_N:-1}"
export PAIR_MODE="${PAIR_MODE:-editdiff}"
export SR_EDIT_FILES="${SR_EDIT_FILES:-${SCRIPT_DIR}/.local/bin/sr_edit_files_yocto_editdiff}"
export YANG_CACHE="${YANG_CACHE:-${WORK_DIR}/yang_installed_repo_yocto3711}"
export LOG="${LOG:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}.log}"
export CSV="${CSV:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}.csv}"
export PER_EDIT="${PER_EDIT:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}_per_edit.csv}"
export PAIRS_OUT="${PAIRS_OUT:-${RESULTS_DIR}/ab_validate_paired_n${PAIR_N}_pairs.txt}"

[[ -x "${SR_EDIT_FILES}" ]] || {
    echo "error: ${SR_EDIT_FILES} missing; stage + compile first" >&2
    exit 1
}
nm -D "${SCALECFG_RUNTIME_DIR}/usr/lib/libyang.so" | grep -q lyd_validate_module_incr \
    || { echo "error: libyang missing lyd_validate_module_incr" >&2; exit 1; }

echo "=== product pin paired SN PAIR_N=${PAIR_N} PAIR_MODE=${PAIR_MODE} ==="
echo "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1
grep 'define LY_VERSION ' "${SCALECFG_RUNTIME_DIR}/usr/include/libyang/version.h" || true

"${SCRIPT_DIR}/ab_validate_paired.sh"
