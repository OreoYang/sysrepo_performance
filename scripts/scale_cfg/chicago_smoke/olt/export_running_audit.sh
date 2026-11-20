#!/bin/sh
# Export live running datastore for offline full YANG validation (does not change running).
# Output is created on first run; path is not pre-installed on the OLT.
set -eu

WORK="${WORK:-/root/chicago_smoke/work}"
OUT="${1:-${WORK}/running_full_audit.xml}"

mkdir -p "$(dirname "${OUT}")"

if ! command -v sysrepocfg >/dev/null 2>&1; then
    echo "error: sysrepocfg not found" >&2
    exit 1
fi

start_ms=$(date +%s%3N)
sysrepocfg --export="${OUT}" -d running -f xml
rc=$?
end_ms=$(date +%s%3N)
elapsed=$(( end_ms - start_ms ))

if [ "$rc" -ne 0 ]; then
    echo "EXPORT FAILED rc=${rc}" >&2
    exit "$rc"
fi

# module names + revisions of this image, so the host can detect YANG skew before importing
sysrepoctl -l 2>/dev/null | awk -F'|' 'NR>2 && $1 !~ /^-/ {gsub(/ /,"",$1); gsub(/ /,"",$2); print $1"@"$2}' > "${OUT%.xml}.modules" || true

bytes=$(stat -c%s "${OUT}" 2>/dev/null || wc -c <"${OUT}")
echo "EXPORT OK ${elapsed} ms"
echo "  path: ${OUT}"
echo "  size: ${bytes} bytes"
echo "  modules: ${OUT%.xml}.modules ($(wc -l < "${OUT%.xml}.modules") modules)"