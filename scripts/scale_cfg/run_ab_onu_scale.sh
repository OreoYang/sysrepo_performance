#!/usr/bin/env bash
# Ordered ONU-scale A/B: edit-diff ON (1022, 1522) then full validate (1022, 1056).
# Same harness as ab_validate_edit_diff.sh; does not change test XML.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_host.sh
source "${SCRIPT_DIR}/env_host.sh"

export N_SERIAL=0 N_LATE=0 N_LATE2=0 N_LATE3=0
export AB_N_LIST=""
export LOG="${RESULTS_DIR}/ab_validate_edit_diff_onu_scale.log"
export CSV="${RESULTS_DIR}/ab_validate_edit_diff_onu_scale.csv"
export PER_EDIT="${RESULTS_DIR}/ab_validate_edit_diff_onu_scale_per_edit.csv"

log() { echo "$*" | tee -a "${LOG}"; }

mkdir -p "${RESULTS_DIR}"
if [[ -f "${LOG}" ]]; then
    mv -f "${LOG}" "${LOG}.prev"
fi
: > "${LOG}"

log "=== ONU scale: editdiff 1022/1522 then full 1022/1056 ==="
log "started: $(date -Iseconds)"

run_phase() {
    local mode="$1"
    local ns="$2"
    local append="${3:-}"
    log "--- phase mode=${mode} N=${ns} ---"
    export AB_MODE="${mode}"
    export AB_N_LIST="${ns}"
    if [[ -n "${append}" ]]; then
        export AB_APPEND=1
    else
        unset AB_APPEND
    fi
    "${SCRIPT_DIR}/ab_validate_edit_diff.sh" >> "${LOG}" 2>&1
}

# Phase 1: edit-diff ON
run_phase editdiff "1022 1522"

# Phase 2: full validate OFF
run_phase full "1022 1056" append

log "finished: $(date -Iseconds)"
log "csv: ${CSV}"
log "per-edit: ${PER_EDIT}"
log "log: ${LOG}"

python3 - "${CSV}" << 'PY' | tee -a "${LOG}"
import csv, sys
from collections import defaultdict

path = sys.argv[1]
rows = list(csv.DictReader(open(path)))
print("\n=== summary (provision + service wall seconds) ===")
print(f"{'mode':8} {'kind':18} {'n':>5} {'seconds':>10} {'first':>8} {'mid':>8} {'last':>8} status")
for r in rows:
  if r.get("kind", "").startswith("serial"):
    print(f"{r['mode']:8} {r['kind']:18} {r['n']:>5} {r['seconds']:>10} {r.get('first_s',''):>8} {r.get('mid_s',''):>8} {r.get('last_s',''):>8} {r.get('status','')}")

by = defaultdict(dict)
for r in rows:
  if r.get("kind") == "serial_service":
    by[int(r["n"])][r["mode"]] = float(r["seconds"])
print("\n=== service total speedup (full / editdiff) ===")
for n in sorted(by):
  full = by[n].get("full")
  ed = by[n].get("editdiff")
  if full and ed:
    print(f"N={n}: full={full:.1f}s editdiff={ed:.1f}s speedup={full/ed:.1f}x")
PY
