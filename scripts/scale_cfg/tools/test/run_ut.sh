#!/usr/bin/env bash
# Run sr_validate_ds unit cases on the host (17 test methods, self-contained vds-test.yang database).
#
# usage: run_ut.sh [binary_path]
#
# Keep sr_validate_ds_test.py and fixtures/ in sync with xpon-apps/sr-validate/test/.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "${HERE}/.." && pwd)"
SC="$(cd "${TOOLS}/.." && pwd)"
R="$(readlink -f "${SCALECFG_RUNTIME_DIR:-${SC}/.local/runtime-prod-rel-incr}")"
BIN="${1:-/tmp/sr_validate_ds}"

# host build: use the host dynamic linker, the default one is the Yocto image path
"${TOOLS}/build_sr_validate_ds.sh" "$R" "$BIN" "$(ls /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 2>/dev/null | head -1)"
export LD_LIBRARY_PATH="${R}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export SYSREPOCTL="${SYSREPOCTL:-${R}/usr/bin/sysrepoctl}"
export SYSREPOCFG="${SYSREPOCFG:-${R}/usr/bin/sysrepocfg}"
[ -d "${R}/usr/lib/libyang/extensions" ] &&
    export LIBYANG_EXTENSIONS_PLUGINS_DIR="${R}/usr/lib/libyang/extensions"

exec python3 "${HERE}/sr_validate_ds_test.py" "$BIN" "${HERE}/fixtures"