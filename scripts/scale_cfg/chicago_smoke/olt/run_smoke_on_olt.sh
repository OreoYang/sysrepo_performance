#!/bin/sh
# Serial smoke on Chicago. STAGE=provision|service|negative|full
# Always one RPC at a time. Times written to $WORK/times.csv
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/root/chicago_smoke/work}"
SERIAL="${ONU_SN:-ZYXE53725310}"
PON="${PON:-1}"
TEMPLATE="${ONU_TEMPLATE:-default-onu-template}"
TD="${TD_PROFILE:-gpon5m}"
PON_TECH="${PON_TECH:-xgs}"
STAGE="${STAGE:-provision}"
VANI="${SERIAL}-vani"
TIMES="${WORK}/times.csv"

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

record() {
    step=$1
    rc=$2
    ms=0
    [ -f "${WORK}/${step}.log.ms" ] && ms=$(cat "${WORK}/${step}.log.ms")
    echo "$(date +%Y-%m-%dT%H:%M:%S),${SERIAL},${STAGE},${step},${rc},${ms}" >> "$TIMES"
    echo "[TIME] ${step} rc=${rc} ${ms} ms"
}

mkdir -p "$WORK"
cd "$DIR"
: > "$TIMES" 2>/dev/null || true
echo "timestamp,serial,stage,step,rc,ms" > "$TIMES"

echo "=============================================="
echo "Chicago incr smoke  STAGE=${STAGE}"
echo "  SERIAL=${SERIAL} PON=${PON} TEMPLATE=${TEMPLATE} TD=${TD}"
echo "=============================================="

do_preflight() {
    ONU_SN="$SERIAL" PON="$PON" PON_TECH="$PON_TECH" ONU_TEMPLATE="$TEMPLATE" ./preflight.sh
}

do_provision() {
    PROV="${WORK}/provision.xml"
    PON_TECH="$PON_TECH" ./gen_provision.sh "$SERIAL" "$PON" "$TEMPLATE" "$PROV"
    if sysrepocfg -X -m ietf-interfaces -d running 2>/dev/null | grep -q "<name>${VANI}</name>"; then
        info "SKIP provision — ${VANI} already in running"
        echo "0" > "${WORK}/provision.log.ms"
        record provision skip
        return 0
    fi
    echo "--- provision (serial, one RPC) ---"
    set +e
    ./netconf_edit.sh "$PROV" "${WORK}/provision.log"
    rc=$?
    set -e
    record provision "$rc"
    [ "$rc" -eq 0 ] || fail "provision NETCONF failed"
    sysrepocfg -X -m ietf-interfaces -d running | grep -q "<name>${VANI}</name>" || fail "${VANI} missing after provision"
    pass "provision: ${VANI} in running"
    if command -v dbc >/dev/null 2>&1; then
        dbc -C "xpon get vani ${VANI}" -A netconf 2>/dev/null | sed -n '1,25p' || true
    fi
}

do_service() {
    SVC="${WORK}/service.xml"
    ./gen_service.sh "$SERIAL" "$TD" "$SVC"
    echo "--- service (serial, one RPC) ---"
    set +e
    ./netconf_edit.sh "$SVC" "${WORK}/service.log"
    rc=$?
    set -e
    record service "$rc"
    [ "$rc" -eq 0 ] || fail "service NETCONF failed"
    sysrepocfg -X -m ietf-interfaces -d running | grep -q "<name>${SERIAL}-eth1</name>" || fail "eth1 missing after service"
    pass "service: ${SERIAL}-eth1 in running"
}

do_negative() {
    BAD="${WORK}/bad.xml"
    cat > "$BAD" <<EOF
<onus xmlns="urn:bbf:yang:bbf-onus" xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">
  <onu xmlns="urn:bbf:yang:bbf-onu-management">
    <name>${VANI}</name>
    <meta-data>
      <template-references nc:operation="replace">
        <template>NONEXISTENT_TEMPLATE_SMOKE_CHICAGO</template>
      </template-references>
    </meta-data>
  </onu>
</onus>
EOF
    echo "--- negative (expect FAIL, serial) ---"
    set +e
    ./netconf_edit.sh "$BAD" "${WORK}/bad.log"
    rc=$?
    set -e
    record negative "$rc"
    [ "$rc" -ne 0 ] || fail "negative edit was accepted"
    sysrepocfg -X -m bbf-onus -d running | grep -q 'NONEXISTENT_TEMPLATE_SMOKE_CHICAGO' && fail "bad template stored"
    pass "negative rejected; running unchanged"
}

do_preflight

case "$STAGE" in
    provision) do_provision ;;
    service) do_service ;;
    negative) do_negative ;;
    full)
        do_provision
        do_service
        do_negative
        ;;
    *) echo "unknown STAGE=$STAGE (provision|service|negative|full)" >&2; exit 1 ;;
esac

echo "=============================================="
echo "STAGE ${STAGE} DONE"
echo "times: ${TIMES}"
cat "$TIMES"
echo "=============================================="
