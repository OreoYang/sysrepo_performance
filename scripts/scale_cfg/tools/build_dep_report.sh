#!/usr/bin/env bash
# Build the offline constraint classifier report tool.
#
# It compiles libyang's own classifier (src/validation_deps.c) into the binary, because libyang exports
# only its public API, and links the rest against the private 3.9.13 / 3.7.11 build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LY_SRC="${LY_SRC:-${HOME}/works/private/libyang-3.9.13}"
LY_PREFIX="${LY_PREFIX:-${LY_SRC}/install}"
SR_PREFIX="${SR_PREFIX:-${HOME}/works/private/sysrepo-3.7.11/install}"
OUT="${OUT:-${SCRIPT_DIR}/../.local/bin/yang_dep_report}"

mkdir -p "$(dirname "${OUT}")"

gcc -O2 -std=gnu11 -o "${OUT}" \
    "${SCRIPT_DIR}/yang_dep_report.c" \
    "${LY_SRC}/src/validation_deps.c" \
    -I "${LY_SRC}/src" -I "${LY_SRC}/build" -I "${LY_SRC}/build/libyang" \
    -I "${LY_SRC}/build/compat" -I "${LY_SRC}/compat" \
    -I "${LY_PREFIX}/include" -I "${SR_PREFIX}/include" \
    -L "${LY_PREFIX}/lib" -L "${SR_PREFIX}/lib" \
    -lyang -lsysrepo -lpthread \
    -Wl,-rpath,"${LY_PREFIX}/lib" -Wl,-rpath,"${SR_PREFIX}/lib"

echo "built ${OUT}"
