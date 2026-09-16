#!/bin/sh
# Apply one config body on the OLT via sysrepocfg (sr_apply_changes → incremental validate).
# One RPC at a time; no netopeer2-cli (needs /dev/tty).
set -eu

CFG="${1:?usage: netconf_edit.sh <config.xml> [logfile]}"
LOG="${2:-/root/chicago_smoke/work/last_netconf.log}"

if [ ! -f "$CFG" ]; then
    echo "error: missing ${CFG}" >&2
    exit 1
fi
if ! command -v sysrepocfg >/dev/null 2>&1; then
    echo "error: sysrepocfg not found" >&2
    exit 1
fi

start_ms=$(date +%s%3N)
# merge edit into running; same validate path as NETCONF edit-config apply
sysrepocfg --edit="$CFG" -d running -f xml >"$LOG" 2>&1
rc=$?
end_ms=$(date +%s%3N)
elapsed=$(( end_ms - start_ms ))
echo "$elapsed" > "${LOG}.ms"
cat "$LOG"

if [ "$rc" -eq 0 ]; then
    echo "APPLY OK (${elapsed} ms)"
    exit 0
fi
echo "APPLY FAILED (${elapsed} ms) — ${LOG}" >&2
exit 1
