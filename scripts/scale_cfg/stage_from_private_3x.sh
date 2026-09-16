#!/usr/bin/env bash
# Stage private product-pin 3.7.11 + 3.9.13 (edit-diff PoC) into a harness runtime.
# Does not overwrite .local/runtime (4.5.4) or .local/runtime-yocto (Yocto native full).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LY_PREFIX="${LY_PREFIX:-${HOME}/works/private/libyang-3.9.13/install}"
SR_PREFIX="${SR_PREFIX:-${HOME}/works/private/sysrepo-3.7.11/install}"
RUNTIME_DIR="${SCALECFG_RUNTIME_DIR:-${SCRIPT_DIR}/.local/runtime-yocto-editdiff}"

die() { echo "error: $*" >&2; exit 1; }

[[ -x "${SR_PREFIX}/bin/sysrepocfg" ]] || die "sysrepocfg missing at ${SR_PREFIX}/bin"
[[ -f "${LY_PREFIX}/lib/libyang.so" ]] || die "libyang missing at ${LY_PREFIX}/lib"

rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/usr/bin" "${RUNTIME_DIR}/usr/lib" "${RUNTIME_DIR}/usr/include"

cp -a "${SR_PREFIX}/bin/." "${RUNTIME_DIR}/usr/bin/"
cp -a "${SR_PREFIX}/lib/." "${RUNTIME_DIR}/usr/lib/"
cp -a "${LY_PREFIX}/lib/." "${RUNTIME_DIR}/usr/lib/"
cp -a "${SR_PREFIX}/include/." "${RUNTIME_DIR}/usr/include/"
cp -a "${LY_PREFIX}/include/." "${RUNTIME_DIR}/usr/include/"
if [[ -d "${LY_PREFIX}/share" ]]; then
    mkdir -p "${RUNTIME_DIR}/usr/share"
    cp -a "${LY_PREFIX}/share/." "${RUNTIME_DIR}/usr/share/"
fi

echo "Staged ${RUNTIME_DIR}"
echo "  sysrepocfg: ${RUNTIME_DIR}/usr/bin/sysrepocfg"
LD_LIBRARY_PATH="${RUNTIME_DIR}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${RUNTIME_DIR}/usr/bin/sysrepocfg" --version | head -1
grep 'define LY_VERSION ' "${RUNTIME_DIR}/usr/include/libyang/version.h"
