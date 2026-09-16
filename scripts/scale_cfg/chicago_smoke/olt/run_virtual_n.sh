#!/bin/sh
# Serial virtual provision of N ONUs on Chicago (no concurrent edits).
# Mix XGS (chpart.N / pon.N) and GPON (chpart.gpon.N / gpon.N) round-robin on ports 1..16.
# SN is 12 hex digits (YANG serial-number). Does not touch the lab ONU ZYXE53725310.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/root/chicago_smoke/work}"
N="${1:-${N:-1022}}"
TEMPLATE="${ONU_TEMPLATE:-default-onu-template}"
CSV="${WORK}/virtual_${N}.csv"
LOG="${WORK}/virtual_${N}.log"
XML="${WORK}/virtual_one.xml"

mkdir -p "$WORK"
cd "$DIR"

ok=0
fail=0
i=1
t0=$(date +%s)
first_ms=""
mid_ms=""
last_ms=""

echo "timestamp,idx,serial,tech,pon,rc,ms" > "$CSV"
echo "virtual N=${N} template=${TEMPLATE} serial, mix xgs/gpon, ports 1-16"
echo "log=${LOG}"

while [ "$i" -le "$N" ]; do
    pon=$(( (i - 1) % 16 + 1 ))
    # even idx → XGS (pon.N); odd idx → GPON (gpon.N)
    if [ $(( i % 2 )) -eq 0 ]; then
        tech=xgs
        serial=$(printf 'AA%010X' "$i")
    else
        tech=gpon
        serial=$(printf 'BB%010X' "$i")
    fi

    PON_TECH="$tech" ./gen_provision.sh "$serial" "$pon" "$TEMPLATE" "$XML" >/dev/null

    start_ms=$(date +%s%3N)
    if sysrepocfg --edit="$XML" -d running -f xml >/dev/null 2>>"$LOG"; then
        rc=0
        ok=$((ok + 1))
    else
        rc=1
        fail=$((fail + 1))
        echo "FAIL idx=${i} ${serial} ${tech} pon=${pon}" >> "$LOG"
    fi
    end_ms=$(date +%s%3N)
    ms=$(( end_ms - start_ms ))
    echo "$(date +%Y-%m-%dT%H:%M:%S),${i},${serial},${tech},${pon},${rc},${ms}" >> "$CSV"

    if [ "$i" -eq 1 ]; then first_ms=$ms; fi
    if [ "$i" -eq $(( N / 2 )) ]; then mid_ms=$ms; fi
    if [ "$i" -eq "$N" ]; then last_ms=$ms; fi

    if [ $(( i % 25 )) -eq 0 ] || [ "$i" -eq 1 ] || [ "$i" -eq "$N" ]; then
        now=$(date +%s)
        echo "[progress] ${i}/${N} ok=${ok} fail=${fail} last_ms=${ms} elapsed=$(( now - t0 ))s"
    fi
    i=$(( i + 1 ))
done

t1=$(date +%s)
echo "DONE N=${N} ok=${ok} fail=${fail} wall=$(( t1 - t0 ))s first_ms=${first_ms} mid_ms=${mid_ms} last_ms=${last_ms}"
echo "csv=${CSV}"
