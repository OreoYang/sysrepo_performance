#!/usr/bin/env bash
# CTest driver for sr_validate_ds. Exit 0 if every case passes, 77 (skipped) if sysrepoctl or sysrepocfg is missing.
#
# usage: sr_validate_ds_ctest.sh BINARY FIXTURE_DIR
# env:   SYSREPOCTL, SYSREPOCFG  full paths of the sysrepo tools (default: from PATH)
#
# Every case builds its own small sysrepo database in a temp directory: it installs fixtures/vds-test.yang
# (a leafref and a must) and stores fixtures/good.xml in running and startup. Nothing outside the temp directory
# is touched. Bad stored data is written straight into the datastore files, because sysrepo refuses to store it
# through its own API, which is exactly how bad data gets in without validation.

set -uo pipefail

BIN="${1:?usage: sr_validate_ds_ctest.sh BINARY FIXTURE_DIR}"
FIX="${2:?usage: sr_validate_ds_ctest.sh BINARY FIXTURE_DIR}"
SYSREPOCTL="${SYSREPOCTL:-$(command -v sysrepoctl || true)}"
SYSREPOCFG="${SYSREPOCFG:-$(command -v sysrepocfg || true)}"

if [[ -z "$SYSREPOCTL" || -z "$SYSREPOCFG" ]]; then
    echo "SKIP  sysrepoctl or sysrepocfg not found (set SYSREPOCTL and SYSREPOCFG)"
    exit 77
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SYSREPO_REPOSITORY_PATH="$TMP/repo"
export SYSREPO_SHM_DIR="$TMP/shm"
export LIBYANG_EXTENSIONS_PLUGINS_DIR="${LIBYANG_EXTENSIONS_PLUGINS_DIR:-}"

failures=0

# fresh database: schema installed, good.xml in running and startup
new_db() {
    rm -rf "$SYSREPO_REPOSITORY_PATH" "$SYSREPO_SHM_DIR"
    mkdir -p "$SYSREPO_REPOSITORY_PATH" "$SYSREPO_SHM_DIR"
    "$SYSREPOCTL" -i "$FIX/vds-test.yang" >/dev/null 2>&1 &&
    "$SYSREPOCFG" -I"$FIX/good.xml" -d startup -m vds-test -f xml >/dev/null 2>&1 &&
    "$SYSREPOCFG" -I"$FIX/good.xml" -d running -m vds-test -f xml >/dev/null 2>&1
}

running_file() { ls "$SYSREPO_SHM_DIR"/*vds-test.running; }
startup_file() { ls "$SYSREPO_REPOSITORY_PATH"/data/vds-test.startup; }

# data in a datastore file that breaks the leafref and the must of y
corrupt() { sed -i 's/"peer": *"x"/"peer":"no-such-item"/' "$1"; }

# assert_exit LABEL EXPECTED_EXIT [-- output must contain PATTERN] COMMAND...
assert_exit() {
    local label=$1 expect=$2 pattern="" rc
    shift 2
    if [[ "$1" == "--contains" ]]; then pattern=$2; shift 2; fi
    "$@" >"$TMP/out" 2>&1
    rc=$?
    if [[ "$rc" -ne "$expect" ]]; then
        echo "FAIL  $label (expected exit $expect, got $rc)"
        sed -n '1,6p' "$TMP/out"
        failures=$((failures + 1))
    elif [[ -n "$pattern" ]] && ! grep -q -- "$pattern" "$TMP/out"; then
        echo "FAIL  $label (exit $rc, output lacks \"$pattern\")"
        sed -n '1,6p' "$TMP/out"
        failures=$((failures + 1))
    else
        echo "PASS  $label (exit $rc)"
    fi
}

# command line, no database needed
assert_exit "cli bad -d" 2 "$BIN" -d nonsense
assert_exit "cli -e together with -f" 2 "$BIN" -e "$FIX/edit_good.xml" -f "$FIX/good.xml"

if ! new_db; then
    echo "FAIL  could not build the test database (sysrepoctl / sysrepocfg failed)"
    exit 1
fi

# stored data
assert_exit "stored: good database, both datastores" 0 --contains "VALID    running" "$BIN" -d both
"$BIN" -d both >/dev/null 2>&1   # opens the connection once, as a running OLT would have

corrupt "$(startup_file)"
assert_exit "stored: bad startup only, -d startup" 1 --contains "INVALID  startup" "$BIN" -d startup
assert_exit "stored: bad startup only, running is still good" 0 --contains "VALID    running" "$BIN" -d running

new_db; "$BIN" >/dev/null 2>&1
corrupt "$(running_file)"
assert_exit "stored: bad running only, -d running" 1 --contains "INVALID  running" "$BIN" -d running
assert_exit "stored: bad running only, startup is still good" 0 --contains "VALID    startup" "$BIN" -d startup
assert_exit "stored: bad running only, -d both" 1 "$BIN" -d both

# -e edit dry run on a good database
new_db; "$BIN" >/dev/null 2>&1
assert_exit "edit: good edit" 0 --contains "VALID    running" "$BIN" -d running -e "$FIX/edit_good.xml"
assert_exit "edit: leafref to a missing item" 1 --contains "no-such-item" "$BIN" -d running -e "$FIX/edit_bad_leafref.xml"
assert_exit "edit: must broken on another item" 1 --contains "peer must be an item of kind b" "$BIN" -d running -e "$FIX/edit_bad_must.xml"
assert_exit "edit: unknown leaf" 1 --contains "no-such-leaf" "$BIN" -d running -e "$FIX/edit_bad_schema.xml"
assert_exit "edit: missing file" 2 "$BIN" -d running -e "$FIX/does-not-exist.xml"
assert_exit "edit: good edit, startup" 0 "$BIN" -d startup -e "$FIX/edit_good.xml"
assert_exit "edit: bad edit, both datastores" 1 "$BIN" -d both -e "$FIX/edit_bad_must.xml"

# the dry run must leave the stored data as it was
before=$(md5sum "$(running_file)" "$(startup_file)" | awk '{print $1}')
"$BIN" -d both -e "$FIX/edit_good.xml" >/dev/null 2>&1
"$BIN" -d both -e "$FIX/edit_bad_must.xml" >/dev/null 2>&1
after=$(md5sum "$(running_file)" "$(startup_file)" | awk '{print $1}')
if [[ "$before" == "$after" ]]; then
    echo "PASS  edit: stored data unchanged after dry runs"
else
    echo "FAIL  edit: stored data changed by a dry run"
    failures=$((failures + 1))
fi
assert_exit "edit: database still good afterwards" 0 "$BIN" -d both

# -f copy-config source file
assert_exit "file: good content" 0 --contains "VALID    file" "$BIN" -f "$FIX/good.xml"
assert_exit "file: broken must" 1 --contains "peer must be an item of kind b" "$BIN" -f "$FIX/copy_bad.xml"
assert_exit "file: unknown leaf" 1 --contains "no-such-leaf" "$BIN" -f "$FIX/edit_bad_schema.xml"
assert_exit "file: missing file" 2 "$BIN" -f "$FIX/does-not-exist.xml"

if [[ "$failures" -ne 0 ]]; then
    echo "$failures case(s) failed"
    exit 1
fi
echo "All sr_validate_ds cases passed."
