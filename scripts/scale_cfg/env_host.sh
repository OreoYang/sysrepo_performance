#!/usr/bin/env bash
# Sourced by run_*.sh only — do not use in login shell.

_scalecfg_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repo_paths.sh
source "${_scalecfg_env_dir}/lib/repo_paths.sh"
unset _scalecfg_env_dir

if [[ ! -d "${RUNTIME_DIR}/usr/bin" ]]; then
    echo "error: staged runtime missing at ${RUNTIME_DIR}" >&2
    echo "Run: ${SCALECFG_DIR}/stage_from_yocto_sysrepo.sh" >&2
    return 1 2>/dev/null || exit 1
fi

mkdir -p "${LOCAL_BIN_DIR}"
# Yocto pyang uses nativepython3; harness stub skips vecima OD-360 lint only.
if [[ ! -x "${LOCAL_BIN_DIR}/pyang" ]]; then
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${LOCAL_BIN_DIR}/pyang"
    chmod +x "${LOCAL_BIN_DIR}/pyang"
fi

export PATH="${RUNTIME_DIR}/usr/bin:${LOCAL_BIN_DIR}:${PATH}"

_runtime_lib="${RUNTIME_DIR}/usr/lib"
export LD_LIBRARY_PATH="${_runtime_lib}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

if [[ -d "${RUNTIME_DIR}/usr/lib/libyang/extensions" ]]; then
    export LIBYANG_EXTENSIONS_PLUGINS_DIR="${RUNTIME_DIR}/usr/lib/libyang/extensions"
fi
if [[ -d "${RUNTIME_DIR}/usr/lib/libyang/user_types" ]]; then
    export LIBYANG_USER_TYPES_PLUGINS_DIR="${RUNTIME_DIR}/usr/lib/libyang/user_types"
fi

export SYSREPOCTL_EXECUTABLE="${RUNTIME_DIR}/usr/bin/sysrepoctl"
export SYSREPOCFG_EXECUTABLE="${RUNTIME_DIR}/usr/bin/sysrepocfg"
export PYANG_EXECUTABLE="${LOCAL_BIN_DIR}/pyang"

unset _runtime_lib
