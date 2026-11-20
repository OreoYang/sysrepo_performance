#!/usr/bin/env bash
# Run sr_validate_ds unit cases on the host (21 cases, self-contained vds-test.yang database).
#
# usage: run_ut.sh [binary_path]
#
# Keep sr_validate_ds_ctest.sh and fixtures/ in sync with xpon-apps/sr-validate/test/.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "${HERE}/.." && pwd)"
SC="$(cd "${TOOLS}/.." && pwd)"
R="${SCALECFG_RUNTIME_DIR:-${SC}/.local/runtime-prod-rel-incr}"
BIN="${1:-/tmp/sr_validate_ds}"

"${TOOLS}/build_sr_validate_ds.sh" "$R" "$BIN"
export LD_LIBRARY_PATH="${R}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export SYSREPOCTL="${SYSREPOCTL:-${R}/usr/bin/sysrepoctl}"
export SYSREPOCFG="${SYSREPOCFG:-${R}/usr/bin/sysrepocfg}"
[ -d "${R}/usr/lib/libyang/extensions" ] &&
    export LIBYANG_EXTENSIONS_PLUGINS_DIR="${R}/usr/lib/libyang/extensions"

exec "${HERE}/sr_validate_ds_ctest.sh" "$BIN" "${HERE}/fixtures"