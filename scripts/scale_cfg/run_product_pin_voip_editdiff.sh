#!/usr/bin/env bash
# Largescale VoIP DB (db_1230_voip): full vs incremental validation, same harness as run_product_pin_editdiff.sh.
#
# Prereq: ./prep_voip_db.sh  (work_voip/configs/, 1024 provision + 976 service, ~44% services carry vecima-onu-voip)
#
# Env:
#   AB_N_LIST   default 1024 (caps service at 976 files)
#   AB_MODE     editdiff|full|both (default both)
#   SCALECFG_RUNTIME_DIR / SCALECFG_RUNTIME_DIR_FULL  (see env_host.sh)
#
# Example:
#   SCALECFG_RUNTIME_DIR=.local/runtime-prod-rel-incr \
#   SCALECFG_RUNTIME_DIR_FULL=.local/runtime-prod-rel-full \
#   AB_N_LIST=1024 AB_MODE=both ./run_product_pin_voip_editdiff.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOIP_WORK="${SCRIPT_DIR}/work_voip"

[[ -d "${VOIP_WORK}/configs/onu-provision" ]] || {
    echo "error: missing ${VOIP_WORK}/configs — run: ${SCRIPT_DIR}/prep_voip_db.sh" >&2
    exit 1
}

export WORK_DIR="${VOIP_WORK}"
export CONFIGS_DIR="${VOIP_WORK}/configs"
export FRESH_REPO="${VOIP_WORK}/fresh_repo"

export SCALECFG_RUNTIME_DIR="${SCALECFG_RUNTIME_DIR:-${SCRIPT_DIR}/.local/runtime-yocto-editdiff}"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

export N_SERIAL=0 N_LATE=0 N_LATE2=0 N_LATE3=0
export AB_MODE="${AB_MODE:-both}"
export AB_N_LIST="${AB_N_LIST:-1024}"
export SR_EDIT_FILES="${SR_EDIT_FILES:-${SCRIPT_DIR}/.local/bin/sr_edit_files_yocto_editdiff}"
export YANG_CACHE="${YANG_CACHE:-${VOIP_WORK}/yang_installed_repo_yocto3711}"
export LOG="${LOG:-${RESULTS_DIR}/ab_validate_product_pin_voip_editdiff.log}"
export CSV="${CSV:-${RESULTS_DIR}/ab_validate_product_pin_voip_editdiff.csv}"
export PER_EDIT="${PER_EDIT:-${RESULTS_DIR}/ab_validate_product_pin_voip_editdiff_per_edit.csv}"

[[ -x "${SR_EDIT_FILES}" ]] || {
    echo "error: ${SR_EDIT_FILES} missing; stage + compile first" >&2
    exit 1
}

mkdir -p "${RESULTS_DIR}"
echo "=== product pin VoIP largescale AB_N_LIST=${AB_N_LIST} AB_MODE=${AB_MODE} ==="
echo "configs: ${CONFIGS_DIR}"
prov_n=$(find "${CONFIGS_DIR}/onu-provision" -maxdepth 1 -name '*.xml' | wc -l)
svc_n=$(find "${CONFIGS_DIR}/onu-service" -maxdepth 1 -name '*.xml' | wc -l)
echo "on disk: provision=${prov_n} service=${svc_n}"
echo "sysrepocfg: ${SYSREPOCFG_EXECUTABLE}"
"${SYSREPOCFG_EXECUTABLE}" --version | head -1
nm -D "${SCALECFG_RUNTIME_DIR}/usr/lib/libyang.so" 2>/dev/null | grep -q lyd_validate_module_incr \
    || { echo "error: libyang missing lyd_validate_module_incr" >&2; exit 1; }

"${SCRIPT_DIR}/ab_validate_edit_diff.sh"