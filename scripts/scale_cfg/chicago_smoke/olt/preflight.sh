#!/bin/sh
# Chicago OLT preflight. Do not slurp whole datastore into a shell variable.
set -eu

PON="${PON:-1}"
PON_TECH="${PON_TECH:-xgs}"
SERIAL="${ONU_SN:-ZYXE53725310}"
VANI="${SERIAL}-vani"
TEMPLATE="${ONU_TEMPLATE:-default-onu-template}"
FAIL=0

if [ "$PON_TECH" = gpon ]; then
    CHPART="chpart.gpon.${PON}"
    CHPAIR="chpair.gpon.${PON}"
else
    CHPART="chpart.${PON}"
    CHPAIR="chpair.${PON}"
fi

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; FAIL=1; }
info() { echo "[INFO] $*"; }

has_name() {
    mod=$1
    name=$2
    sysrepocfg -X -m "$mod" -d running 2>/dev/null | grep -q "<name>${name}</name>"
}

info "hostname=$(hostname) pon_tech=${PON_TECH} chpart=${CHPART}"

for svc in netconf-polt netopeer2; do
    if systemctl is-active --quiet "$svc"; then
        pass "service $svc active"
    else
        fail "service $svc not active"
    fi
    env_line=$(systemctl show "$svc" -p Environment 2>/dev/null || true)
    case "$env_line" in
        *SR_VALIDATE_INCREMENTAL=1*) pass "$svc has SR_VALIDATE_INCREMENTAL=1" ;;
        *) fail "$svc missing SR_VALIDATE_INCREMENTAL=1" ;;
    esac
done

if strings /usr/lib/libyang.so.3 2>/dev/null | grep lyd_validate_module_incr >/dev/null; then
    pass "libyang has lyd_validate_module_incr"
else
    fail "libyang missing lyd_validate_module_incr"
fi

info "sysrepocfg: $(sysrepocfg --version 2>/dev/null | sed -n '1p')"

if has_name ietf-interfaces "$CHPART"; then
    pass "running has ${CHPART}"
else
    fail "running missing ${CHPART} (PON=${PON} PON_TECH=${PON_TECH})"
fi
if has_name ietf-interfaces "$CHPAIR"; then
    pass "running has ${CHPAIR}"
else
    fail "running missing ${CHPAIR}"
fi

if sysrepocfg -X -m bbf-onus -d running 2>/dev/null | grep -q "$TEMPLATE"; then
    pass "template ${TEMPLATE} present in bbf-onus"
else
    fail "template ${TEMPLATE} not in running"
fi

if has_name ietf-interfaces "$VANI"; then
    info "ONU ${VANI} already in running — provision will skip"
else
    pass "ONU ${VANI} not in running (clean for ONU1 provision)"
fi

incr_log=$(journalctl -u netconf-polt -u netopeer2 2>/dev/null | grep 'Incremental YANG validation is enabled' | sed -n '$p' || true)
if [ -n "$incr_log" ]; then
    info "prior incr log: $incr_log"
fi

if [ "$FAIL" -ne 0 ]; then
    echo "preflight FAILED" >&2
    exit 1
fi
echo "preflight OK"
exit 0
