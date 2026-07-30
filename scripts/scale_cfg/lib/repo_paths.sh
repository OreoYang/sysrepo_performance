#!/usr/bin/env bash
# Paths for scale_cfg harness (standalone repo or netconf-polt subtree).

_scalecfg_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCALECFG_DIR="$(cd "${_scalecfg_lib_dir}/.." && pwd)"
REPO_ROOT="$(cd "${SCALECFG_DIR}/../.." && pwd)"

WORK_DIR="${SCALECFG_DIR}/work"
RESULTS_DIR="${SCALECFG_DIR}/results"
TARBALL="${SCALECFG_DIR}/largescaleDb.tar"
SNAPSHOT_REPO="${WORK_DIR}/var_db/upper/sysrepo"
FRESH_REPO="${WORK_DIR}/fresh_repo"

# Runtime staged by stage_from_yocto_sysrepo.sh (local to scale_cfg by default)
RUNTIME_DIR="${SCALECFG_RUNTIME_DIR:-${SCALECFG_DIR}/.local/runtime}"
LOCAL_BIN_DIR="${SCALECFG_DIR}/.local/bin"

# xpon-yang: override with XPON_YANG_ROOT if not in default layout
if [[ -n "${XPON_YANG_ROOT:-}" ]]; then
    YANG_ROOT="${XPON_YANG_ROOT}"
elif [[ -d "${REPO_ROOT}/../xpon-yang/yang" ]]; then
    YANG_ROOT="$(cd "${REPO_ROOT}/../xpon-yang/yang" && pwd)"
elif [[ -d "${HOME}/works/repo/build-xpon/workspace/sources/xpon-yang/yang" ]]; then
    YANG_ROOT="${HOME}/works/repo/build-xpon/workspace/sources/xpon-yang/yang"
else
    YANG_ROOT="${XPON_YANG_ROOT:-/path/to/xpon-yang/yang}"
fi
SETUP_DATASTORE_SH="${YANG_ROOT}/scripts/setup_datastore.sh"

# Yocto build-xpon: override with XPON_BUILDDIR
BUILDDIR="${XPON_BUILDDIR:-}"
if [[ -z "${BUILDDIR}" ]]; then
    _search="${REPO_ROOT}"
    while [[ -n "${_search}" && "${_search}" != "/" ]]; do
        if [[ -f "${_search}/conf/bblayers.conf" ]]; then
            BUILDDIR="${_search}"
            break
        fi
        _search="$(dirname "${_search}")"
    done
    unset _search
fi
if [[ -z "${BUILDDIR}" && -d "${HOME}/works/repo/build-xpon" ]]; then
    BUILDDIR="${HOME}/works/repo/build-xpon"
fi

SYSROOTS_X86="${BUILDDIR}/tmp/sysroots-components/x86_64"
SYSREPO_NATIVE_ROOT="${SYSROOTS_X86}/sysrepo-native"
LIBYANG_NATIVE_ROOT="${SYSROOTS_X86}/libyang-native"
PYANG_NATIVE_ROOT="${SYSROOTS_X86}/python3-pyang-native"

unset _scalecfg_lib_dir
