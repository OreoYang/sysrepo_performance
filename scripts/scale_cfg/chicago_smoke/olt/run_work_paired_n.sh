#!/bin/sh
# Per-ONU: provision then service (work/ XML). Serial only.
# pairs.txt: idx TAB onu-provision/file.xml TAB onu-service/file.xml|-
# Do not stop netconf-polt / protocol-handler. Still export SR_VALIDATE_INCREMENTAL
# on this shell — sysrepocfg does not inherit systemd Environment.
set -eu

CFG="${CFG:-/root/chicago_smoke/work_xml}"
WORK="${WORK:-/root/chicago_smoke/work}"
N="${1:-${N:-1022}}"
START="${START:-1}"
# Only =1 enables incr. Use 0/unset for full validate. Do not inherit systemd.
export SR_VALIDATE_INCREMENTAL="${SR_VALIDATE_INCREMENTAL:-1}"
CSV="${WORK}/work_paired_${N}_incr${SR_VALIDATE_INCREMENTAL}.csv"
LOG="${WORK}/work_paired_${N}_incr${SR_VALIDATE_INCREMENTAL}.log"
PAIRS="${CFG}/pairs.txt"

mkdir -p "$WORK"
cd "$CFG"
[ -f "$PAIRS" ] || { echo "missing ${PAIRS}"; exit 1; }
: > "$LOG"

ok_p=0; fail_p=0; ok_s=0; fail_s=0; skip_s=0
t0=$(date +%s)
first_p=""; mid_p=""; last_p=""
first_s=""; mid_s=""; last_s=""
mid_i=$(( N / 2 ))
last_pms=""; last_sms=""

echo "timestamp,idx,serial,step,rc,ms,file" > "$CSV"
echo "paired N=${N} START=${START} SR_VALIDATE_INCREMENTAL=${SR_VALIDATE_INCREMENTAL}"
echo "csv=${CSV} log=${LOG}"

while IFS='	' read -r idx prov svc; do
    [ -n "$idx" ] || continue
    i=$idx
    [ "$i" -ge "$START" ] || continue
    [ "$i" -le "$N" ] || break

    serial=$(basename "$prov")
    serial=${serial#*-}
    serial=${serial%.xml}

    start_ms=$(date +%s%3N)
    set +e
    sysrepocfg --edit="$prov" -d running -f xml >>"$LOG" 2>&1
    rc=$?
    set -e
    ms=$(( $(date +%s%3N) - start_ms ))
    last_pms=$ms
    if [ "$rc" -eq 0 ]; then ok_p=$((ok_p + 1)); else fail_p=$((fail_p + 1)); echo "FAIL provision idx=${i} ${prov}"; fi
    echo "$(date +%Y-%m-%dT%H:%M:%S),${i},${serial},provision,${rc},${ms},${prov}" >> "$CSV"
    [ "$i" -eq "$START" ] && first_p=$ms
    [ "$i" -eq "$mid_i" ] && mid_p=$ms
    [ "$i" -eq "$N" ] && last_p=$ms

    if [ "$i" -eq "$START" ] && [ "$rc" -ne 0 ]; then
        echo "FIRST provision failed — stop"
        exit 1
    fi

    if [ "$svc" = "-" ] || [ ! -f "$svc" ]; then
        skip_s=$((skip_s + 1))
        echo "$(date +%Y-%m-%dT%H:%M:%S),${i},${serial},service,skip,0,-" >> "$CSV"
        last_sms=0
    else
        start_ms=$(date +%s%3N)
        set +e
        sysrepocfg --edit="$svc" -d running -f xml >>"$LOG" 2>&1
        rc=$?
        set -e
        ms=$(( $(date +%s%3N) - start_ms ))
        last_sms=$ms
        if [ "$rc" -eq 0 ]; then ok_s=$((ok_s + 1)); else fail_s=$((fail_s + 1)); echo "FAIL service idx=${i} ${svc}"; fi
        echo "$(date +%Y-%m-%dT%H:%M:%S),${i},${serial},service,${rc},${ms},${svc}" >> "$CSV"
        [ "$i" -eq "$START" ] && first_s=$ms
        [ "$i" -eq "$mid_i" ] && mid_s=$ms
        [ "$i" -eq "$N" ] && last_s=$ms
        if [ "$i" -eq "$START" ] && [ "$rc" -ne 0 ]; then
            echo "FIRST service failed — stop"
            exit 1
        fi
    fi

    if [ $(( i % 25 )) -eq 0 ] || [ "$i" -eq "$START" ] || [ "$i" -eq "$N" ]; then
        now=$(date +%s)
        echo "[progress] ${i}/${N} p_ok=${ok_p} p_fail=${fail_p} s_ok=${ok_s} s_fail=${fail_s} s_skip=${skip_s} prov_ms=${last_pms} svc_ms=${last_sms} elapsed=$(( now - t0 ))s"
    fi
done < "$PAIRS"

t1=$(date +%s)
echo "DONE paired N=${N} wall=$(( t1 - t0 ))s p_ok=${ok_p} p_fail=${fail_p} s_ok=${ok_s} s_fail=${fail_s} s_skip=${skip_s}"
echo "prov first/mid/last_ms ${first_p} ${mid_p} ${last_p}"
echo "svc  first/mid/last_ms ${first_s} ${mid_s} ${last_s}"
echo "csv=${CSV}"
