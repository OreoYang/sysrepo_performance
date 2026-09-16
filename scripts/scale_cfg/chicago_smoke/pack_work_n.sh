#!/usr/bin/env bash
# Pack work/configs like host N=1022: 00-base + first 1022 provision + matching service by SN.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${SCRIPT_DIR}/../work/configs"
N="${N:-1022}"
OUT="${OUT:-${SCRIPT_DIR}/work_n${N}.tar}"
STAGE="${SCRIPT_DIR}/.pack_n${N}"

rm -rf "$STAGE"
mkdir -p "$STAGE/00-base" "$STAGE/onu-provision" "$STAGE/onu-service"
cp -a "${CFG}/00-base/." "$STAGE/00-base/"

# Pair by serial number, not by taking the first N service files.
python3 "${SCRIPT_DIR}/../lib/build_onu_pairs.py" --configs "${CFG}" -n "${N}" --format tsv --preview 3 \
    > "$STAGE/pairs.txt"
python3 "${SCRIPT_DIR}/../lib/build_onu_pairs.py" --configs "${CFG}" -n "${N}" --format summary

while IFS='	' read -r idx prov svc; do
    [ -n "$idx" ] || continue
    cp -a "${CFG}/${prov}" "$STAGE/onu-provision/"
    if [ "$svc" != "-" ]; then
        cp -a "${CFG}/${svc}" "$STAGE/onu-service/"
    fi
done < "$STAGE/pairs.txt"

echo "packed $(wc -l < "$STAGE/pairs.txt") pairs"
tar -C "$STAGE" -cf "$OUT" 00-base onu-provision onu-service pairs.txt
ls -lh "$OUT"
