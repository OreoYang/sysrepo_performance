#!/bin/sh
# Serial virtual SERVICE for N ONUs already provisioned (no concurrent edits).
# Same SN/tech/pon mapping as run_virtual_n.sh. Shared forwarder fwd_nto1_cvlan2000.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/root/chicago_smoke/work}"
N="${1:-${N:-1022}}"
START="${START:-1}"
TD="${TD_PROFILE:-gpon5m}"
CSV="${WORK}/virtual_service_${N}.csv"
LOG="${WORK}/virtual_service_${N}.log"
XML="${WORK}/virtual_service_one.xml"

mkdir -p "$WORK"
cd "$DIR"

ok=0
fail=0
i=$START
t0=$(date +%s)
first_ms=""
mid_ms=""
last_ms=""
mid_i=$(( N / 2 ))

echo "timestamp,idx,serial,tech,pon,rc,ms" > "$CSV"
echo "virtual SERVICE N=${N} START=${START} TD=${TD} serial, shared fwd_nto1_cvlan2000"

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

    if [ "$i" -eq "$START" ]; then first_ms=$ms; fi
    if [ "$i" -eq "$mid_i" ]; then mid_ms=$ms; fi
    if [ "$i" -eq "$N" ]; then last_ms=$ms; fi

    if [ $(( i % 25 )) -eq 0 ] || [ "$i" -eq "$START" ] || [ "$i" -eq "$N" ] || [ "$rc" -ne 0 ]; then
        now=$(date +%s)
        echo "[progress] ${i}/${N} ok=${ok} fail=${fail} last_ms=${ms} elapsed=$(( now - t0 ))s"
    fi

    # stop after first failure so we can inspect (serial, no continue-on-error for first ONU)
    if [ "$rc" -ne 0 ] && [ "$i" -eq "$START" ]; then
        echo "FIRST service failed — stopping"
        exit 1
    fi
    i=$(( i + 1 ))
done

t1=$(date +%s)
echo "DONE SERVICE N=${N} ok=${ok} fail=${fail} wall=$(( t1 - t0 ))s first_ms=${first_ms} mid_ms=${mid_ms} last_ms=${last_ms}"
echo "csv=${CSV}"
