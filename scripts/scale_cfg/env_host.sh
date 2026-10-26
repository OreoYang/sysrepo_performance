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

# Incremental validation is a build-time switch (cmake -DENABLE_VALIDATE_INCREMENTAL=ON|OFF), so the full-validation
# arm of an A/B run needs its own staged runtime:
#   SCALECFG_RUNTIME_DIR       incremental build (default .local/runtime)
#   SCALECFG_RUNTIME_DIR_FULL  full-validation build (same layout, usr/bin + usr/lib)
# Runtimes built before the switch became a macro read SR_VALIDATE_INCREMENTAL from the environment ("legacy"):
# they stay usable, one runtime serves both arms and the variable is toggled as before.

# Print incr|full|legacy|unknown for a staged runtime, judged from the log text compiled into libsysrepo.
sr_build_kind() {
    local so
    so="$(readlink -f "$1/usr/lib/libsysrepo.so" 2>/dev/null || true)"
    [[ -f "${so}" ]] || { echo unknown; return; }
    if grep -aq "not compiled in (ENABLE_VALIDATE_INCREMENTAL=OFF)" "${so}"; then
        echo full
    elif grep -aq "compiled in (ENABLE_VALIDATE_INCREMENTAL=ON)" "${so}"; then
        echo incr
    elif grep -aq "SR_VALIDATE_INCREMENTAL" "${so}"; then
        echo legacy
    else
        echo unknown
    fi
}

# _sr_path_without PATH_LIST DIR...: PATH_LIST (colon separated) minus the given directories.
_sr_path_without() {
    local list="$1" out="" item skip d
    shift
    local IFS=:
    for item in ${list}; do
        skip=0
        for d in "$@"; do
            [[ -n "${d}" && "${item}" == "${d}" ]] && skip=1
        done
        [[ "${skip}" -eq 1 || -z "${item}" ]] || out="${out:+${out}:}${item}"
    done
    echo "${out}"
}

# sr_use_build incr|full: point PATH, LD_LIBRARY_PATH and the sysrepo executables at the matching runtime.
# Refuses a runtime that would silently run the other validator.
sr_use_build() {
    local want="$1" dir kind incr_kind
    incr_kind="$(sr_build_kind "${RUNTIME_DIR}")"
    if [[ "${want}" == "incr" ]]; then
        dir="${RUNTIME_DIR}"
    elif [[ -n "${SCALECFG_RUNTIME_DIR_FULL:-}" ]]; then
        dir="${SCALECFG_RUNTIME_DIR_FULL}"
    elif [[ "${incr_kind}" == "legacy" ]]; then
        dir="${RUNTIME_DIR}"
    else
        echo "error: full validation needs SCALECFG_RUNTIME_DIR_FULL (build with -DENABLE_VALIDATE_INCREMENTAL=OFF)" >&2
        return 1
    fi
    [[ -x "${dir}/usr/bin/sysrepocfg" ]] || { echo "error: no sysrepocfg in ${dir}" >&2; return 1; }
    kind="$(sr_build_kind "${dir}")"
    case "${want}:${kind}" in
    incr:incr | full:full | incr:legacy | full:legacy) ;;
    *)
        echo "error: runtime ${dir} is a '${kind}' build, wanted '${want}'" >&2
        return 1
        ;;
    esac

    # drop every runtime entry (the default one from above and the one used before), then put the new one first
    PATH="$(_sr_path_without "${PATH}" "${RUNTIME_DIR}/usr/bin" "${SR_ACTIVE_RUNTIME:+${SR_ACTIVE_RUNTIME}/usr/bin}")"
    LD_LIBRARY_PATH="$(_sr_path_without "${LD_LIBRARY_PATH:-}" "${RUNTIME_DIR}/usr/lib" \
        "${SR_ACTIVE_RUNTIME:+${SR_ACTIVE_RUNTIME}/usr/lib}")"
    export SR_ACTIVE_RUNTIME="${dir}"
    export PATH="${dir}/usr/bin:${PATH}"
    export LD_LIBRARY_PATH="${dir}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export SYSREPOCTL_EXECUTABLE="${dir}/usr/bin/sysrepoctl"
    export SYSREPOCFG_EXECUTABLE="${dir}/usr/bin/sysrepocfg"

    if [[ "${kind}" == "legacy" ]]; then
        if [[ "${want}" == "incr" ]]; then
            export SR_VALIDATE_INCREMENTAL=1
        else
            unset SR_VALIDATE_INCREMENTAL
        fi
    fi
    echo "  build=${want} (${kind}) runtime=${dir}"
}
