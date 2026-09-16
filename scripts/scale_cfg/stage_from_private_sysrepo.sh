#!/usr/bin/env bash
# Stage private ~/works/private/sysrepo (SRBF + phase profiling) into harness runtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repo_paths.sh
source "${SCRIPT_DIR}/lib/repo_paths.sh"

SR_SRC="${PRIVATE_SYSREPO:-${HOME}/works/private/sysrepo}"
SR_BUILD="${SR_SRC}/build"
LY_INSTALL="${PRIVATE_LIBYANG_INSTALL:-${HOME}/works/private/libyang/install}"

die() { echo "error: $*" >&2; exit 1; }

[[ -x "${SR_BUILD}/sysrepocfg" ]] || die "private sysrepo not built: ${SR_BUILD}/sysrepocfg"
[[ -e "${SR_BUILD}/libsysrepo.so" ]] || die "libsysrepo missing in ${SR_BUILD}"

echo "Staging private sysrepo -> ${RUNTIME_DIR}"
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/usr/bin" "${RUNTIME_DIR}/usr/lib"

cp -a "${SR_BUILD}/sysrepocfg" "${SR_BUILD}/sysrepoctl" "${RUNTIME_DIR}/usr/bin/"
cp -a "${SR_BUILD}/libsysrepo.so"* "${RUNTIME_DIR}/usr/lib/"

# Prefer private libyang (edit-diff APIs). Fall back to /usr/local.
if [[ -e "${LY_INSTALL}/lib/libyang.so.5" ]]; then
    cp -a "${LY_INSTALL}/lib/libyang.so"* "${RUNTIME_DIR}/usr/lib/"
    if [[ -d "${LY_INSTALL}/share/yang" ]]; then
        mkdir -p "${RUNTIME_DIR}/usr/share/yang"
        cp -a "${LY_INSTALL}/share/yang/." "${RUNTIME_DIR}/usr/share/yang/"
    fi
elif [[ -e /usr/local/lib/libyang.so.5 ]]; then
    echo "warning: using /usr/local libyang (no edit-diff APIs unless rebuilt)" >&2
    cp -a /usr/local/lib/libyang.so* "${RUNTIME_DIR}/usr/lib/" || true
    if [[ -d /usr/local/lib/libyang ]]; then
        mkdir -p "${RUNTIME_DIR}/usr/lib/libyang"
        cp -a /usr/local/lib/libyang/. "${RUNTIME_DIR}/usr/lib/libyang/" || true
    fi
fi

[[ -x "${RUNTIME_DIR}/usr/bin/sysrepocfg" ]] || die "sysrepocfg not staged"

mkdir -p "${LOCAL_BIN_DIR}"
if [[ ! -x "${LOCAL_BIN_DIR}/pyang" ]]; then
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${LOCAL_BIN_DIR}/pyang"
    chmod +x "${LOCAL_BIN_DIR}/pyang"
fi

export LD_LIBRARY_PATH="${RUNTIME_DIR}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
echo "Staged private sysrepo OK:"
echo "  sysrepocfg: ${RUNTIME_DIR}/usr/bin/sysrepocfg"
"${RUNTIME_DIR}/usr/bin/sysrepocfg" --version | head -1
