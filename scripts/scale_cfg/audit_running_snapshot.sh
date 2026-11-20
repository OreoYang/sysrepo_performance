#!/usr/bin/env bash
# Wrong-accept audit of a running-datastore snapshot, on the host. Never touches the OLT / production.
#
# Input : XML from `sysrepocfg --export -d running` (see chicago_smoke/run_export_running_remote.sh)
# Checks:
#   1. full build imports the snapshot            -> stored data is valid under full validation
#   2. incremental build imports the same snapshot -> verdict must equal check 1
#   3. both resulting datastores export the same XML
#   4. flip_diff_check.py on the snapshot: the same probe edits through full and incremental must agree
# Exit 0 = no wrong-accept found. Non-zero = see the line that says FAIL.
#
# Usage:
#   SCALECFG_RUNTIME_DIR=.local/runtime-prod-rel-incr \
#   SCALECFG_RUNTIME_DIR_FULL=.local/runtime-prod-rel-full \
#   ./audit_running_snapshot.sh /path/to/running_full_audit.xml
# Env: AUDIT_NOT_STRICT=1 (import with -n, ignores unknown data), AUDIT_WORK (default work/audit_<name>), FLIP_LIMIT (probe edits, default 300, 0 = all), SKIP_FLIP=1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${1:?usage: audit_running_snapshot.sh <running_export.xml>}"
[[ -s "${SNAP}" ]] || { echo "error: missing or empty ${SNAP}" >&2; exit 2; }
SNAP="$(readlink -f "${SNAP}")"

abs() { (cd "$(dirname "$1")" && echo "$(pwd)/$(basename "$1")"); }
export SCALECFG_RUNTIME_DIR="$(abs "${SCALECFG_RUNTIME_DIR:-${SCRIPT_DIR}/.local/runtime-prod-rel-incr}")"
export SCALECFG_RUNTIME_DIR_FULL="$(abs "${SCALECFG_RUNTIME_DIR_FULL:-${SCRIPT_DIR}/.local/runtime-prod-rel-full}")"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

W="${AUDIT_WORK:-${SCRIPT_DIR}/work/audit_$(basename "${SNAP%.*}")}"
FLIP_LIMIT="${FLIP_LIMIT:-300}"
rm -rf "${W}"
mkdir -p "${W}"
LOG="${W}/audit.log"
FAILS=0
# strict by default: -n would silently drop data the YANG does not know and make the audit vacuous
NOT_STRICT=""
[[ "${AUDIT_NOT_STRICT:-0}" == "1" ]] && NOT_STRICT="-n"

say() { echo "$*" | tee -a "${LOG}"; }
bad() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }

say "=== running snapshot audit: ${SNAP} ($(stat -c%s "${SNAP}") bytes) ==="
say "incr runtime: ${SCALECFG_RUNTIME_DIR}"
say "full runtime: ${SCALECFG_RUNTIME_DIR_FULL}"
say "YANG: ${YANG_ROOT}  (must be the YANG of the image the snapshot came from, else import fails on schema skew)"

MODS="${SNAP%.xml}.modules"

# one schema install, copied for each arm (same repo, same YANG)
export SYSREPO_REPOSITORY_PATH="${W}/repo_base"
export SYSREPO_SHM_DIR="${W}/shm_base"
sr_use_build incr >> "${LOG}" 2>&1
"${SCRIPT_DIR}/install_yang_modules.sh" >> "${LOG}" 2>&1 || { say "FAIL: YANG install failed, see ${LOG}"; exit 3; }

check_module_skew() {
    [[ -s "${MODS}" ]] || return 0
    sr_use_build incr >> "${LOG}" 2>&1
    export SYSREPO_REPOSITORY_PATH="${W}/repo_base" SYSREPO_SHM_DIR="${W}/shm_base"
    "${SYSREPOCTL_EXECUTABLE}" -l 2>/dev/null | awk -F'|' 'NR>2 && $1 !~ /^-/ {gsub(/ /,"",$1); gsub(/ /,"",$2); print $1"@"$2}' \
        | sort > "${W}/host.modules"
    sort "${MODS}" > "${W}/olt.modules"
    if diff -q "${W}/olt.modules" "${W}/host.modules" >/dev/null; then
        say "0. module list equals the image ($(wc -l < "${W}/olt.modules") modules)"
    else
        say "0. YANG skew vs image (only-in-image <, only-on-host >):"
        { diff "${W}/olt.modules" "${W}/host.modules" || true; } | grep '^[<>]' | head -10 | sed 's/^/     /' | tee -a "${LOG}" || true
    fi
}
check_module_skew

import_arm() { # arm: full|incr -> sets <arm>_rc, exports <arm>.xml
    local arm="$1"
    cp -a "${W}/repo_base" "${W}/repo_${arm}"
    export SYSREPO_REPOSITORY_PATH="${W}/repo_${arm}"
    export SYSREPO_SHM_DIR="${W}/shm_${arm}"
    mkdir -p "${SYSREPO_SHM_DIR}"
    sr_use_build "${arm}" >> "${LOG}" 2>&1
    set +e
    "${SYSREPOCFG_EXECUTABLE}" --import="${SNAP}" -d running -f xml ${NOT_STRICT} > "${W}/import_${arm}.out" 2>&1
    eval "${arm}_rc=$?"
    set -e
    # running is rebuilt from startup whenever a new SHM is created, so keep both the same (probe edits use new SHMs)
    if [[ "$(eval echo \${${arm}_rc})" -eq 0 ]]; then
        "${SYSREPOCFG_EXECUTABLE}" -C running -d startup >> "${LOG}" 2>&1 || bad "copy running to startup failed (${arm})"
    fi
    "${SYSREPOCFG_EXECUTABLE}" --export="${W}/after_${arm}.xml" -d running -f xml >> "${LOG}" 2>&1 || true
}

import_arm full
import_arm incr

say "1. full import  rc=${full_rc}   2. incr import rc=${incr_rc}"
if [[ "${full_rc}" -ne 0 ]] && grep -qE 'not found as a child|Unknown element|unknown module|No module' "${W}/import_full.out"; then
    say "INCONCLUSIVE: the host YANG does not match the image the snapshot came from (schema skew), the data was never validated."
    grep -m3 -E 'not found as a child|Unknown element|unknown module|No module' "${W}/import_full.out" | sed 's/^/     /' | tee -a "${LOG}"
    say "   Fix: point XPON_YANG_ROOT at the xpon-yang checkout of the image version, then rerun."
    exit 4
fi
if [[ "${full_rc}" -ne 0 ]]; then
    say "   snapshot is NOT valid under full validation. First errors:"
    grep -m5 -E 'error|Error|condition|leafref|Unique|Mandatory' "${W}/import_full.out" | sed 's/^/     /' | tee -a "${LOG}"
fi
if [[ "${full_rc}" -ne 0 && "${incr_rc}" -eq 0 ]]; then
    bad "WRONG-ACCEPT: full rejects the snapshot, incremental accepts it"
elif [[ "${full_rc}" -eq 0 && "${incr_rc}" -ne 0 ]]; then
    bad "OVER-REJECT: incremental rejects what full accepts"
fi

if [[ "${full_rc}" -eq 0 && "${incr_rc}" -eq 0 ]]; then
    if cmp -s "${W}/after_full.xml" "${W}/after_incr.xml"; then
        say "3. exports after import are identical"
    else
        bad "datastores differ after import (diff ${W}/after_full.xml ${W}/after_incr.xml)"
    fi
fi

if [[ "${SKIP_FLIP:-0}" != "1" && "${full_rc}" -eq 0 ]]; then
    say "4. probe edits through both validators (flip_diff_check.py, limit=${FLIP_LIMIT})"
    set +e
    python3 "${SCRIPT_DIR}/flip_diff_check.py" --runtime "${SCALECFG_RUNTIME_DIR}" \
        --runtime-full "${SCALECFG_RUNTIME_DIR_FULL}" --repo "${W}/repo_full" --limit "${FLIP_LIMIT}" \
        --csv "${W}/flip.csv" 2>&1 | tee -a "${LOG}"
    flip_rc=${PIPESTATUS[0]}
    set -e
    [[ "${flip_rc}" -eq 0 ]] || bad "probe edits disagree between full and incremental (see ${W}/flip.csv)"
    grep -q '^cases=0 ' "${LOG}" && bad "probe step ran 0 cases, nothing was checked"
fi

say ""
[[ "${full_rc}" -eq 0 ]] || bad "snapshot is not valid under full validation (nothing else was proven)"
if [[ "${FAILS}" -eq 0 ]]; then
    say "RESULT: PASS - no wrong-accept found. Log: ${LOG}"
else
    say "RESULT: FAIL (${FAILS}) - Log: ${LOG}"
fi
exit $((FAILS > 0))
