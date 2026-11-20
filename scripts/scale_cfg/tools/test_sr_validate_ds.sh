#!/usr/bin/env bash
# Regression harness for sr_validate_ds: planted invalid configs must exit 1; good copy exits 0.
#
# usage: test_sr_validate_ds.sh [path_to_sr_validate_ds_binary]
# env:   SCALECFG_RUNTIME_DIR (default scripts/scale_cfg/.local/runtime-prod-rel-incr)
#        AUDIT_REPO (default .../work/audit_running_full_audit/repo_full)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$(cd "${HERE}/.." && pwd)"
R="${SCALECFG_RUNTIME_DIR:-${SC}/.local/runtime-prod-rel-incr}"
W="${AUDIT_REPO:-${SC}/work/audit_running_full_audit/repo_full}"
BIN="${1:-/tmp/sr_validate_ds}"
SRC="${HERE}/sr_validate_ds.c"
if [[ ! -x "${BIN}" ]]; then
    gcc -O2 -Wall -Wextra -Werror -o "${BIN}" "${SRC}" -I"${R}/usr/include" -L"${R}/usr/lib" \
        -lsysrepo -lyang -Wl,-rpath,"${R}/usr/lib"
fi
export LD_LIBRARY_PATH="${R}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

BAD_LEAFREF='0,/"lower-layer-interface":"ALCLFCAA6718-vani"/s//"lower-layer-interface":"NO-SUCH-VANI"/'

prep() {
    rm -rf /tmp/sr_vds_repo /tmp/sr_vds_shm
    cp -a "${W}" /tmp/sr_vds_repo
    mkdir -p /tmp/sr_vds_shm
    export SYSREPO_REPOSITORY_PATH=/tmp/sr_vds_repo
    export SYSREPO_SHM_DIR=/tmp/sr_vds_shm
    "${BIN}" >/dev/null 2>&1
}

expect_exit() {
    local label=$1 expect=$2
    shift 2
    set +e
    "${BIN}" "$@" >/tmp/sr_vds_out 2>&1
    local rc=$?
    set -e
    if [[ "${expect}" == "${rc}" ]]; then
        echo "PASS  ${label} (exit ${rc})"
    else
        echo "FAIL  ${label} (expected exit ${expect}, got ${rc})"
        sed -n '1,12p' /tmp/sr_vds_out
        return 1
    fi
}

failures=0
prep && expect_exit "baseline both VALID" 0 -d both || failures=$((failures + 1))

prep
sed -i "${BAD_LEAFREF}" /tmp/sr_vds_repo/data/ietf-interfaces.startup
expect_exit "INVALID startup only (leafref)" 1 -d both || failures=$((failures + 1))
grep -q '^INVALID  startup' /tmp/sr_vds_out || { echo "FAIL  startup INVALID line missing"; failures=$((failures + 1)); }

prep
sed -i "${BAD_LEAFREF}" /tmp/sr_vds_shm/sr_ietf-interfaces.running
expect_exit "INVALID running only (leafref)" 1 -d both || failures=$((failures + 1))
grep -q '^INVALID  running' /tmp/sr_vds_out || { echo "FAIL  running INVALID line missing"; failures=$((failures + 1)); }
grep -q '^VALID    startup' /tmp/sr_vds_out || { echo "FAIL  startup should stay VALID when only running bad"; failures=$((failures + 1)); }

prep
expect_exit "bad -d option" 2 -d nonsense || failures=$((failures + 1))

rm -rf /tmp/sr_vds_repo /tmp/sr_vds_shm
if [[ "${failures}" -ne 0 ]]; then
    echo "${failures} test(s) failed"
    exit 1
fi
echo "All sr_validate_ds detection checks passed."