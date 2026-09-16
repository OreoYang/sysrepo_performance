#!/bin/sh
# Import work/ 00-base in the same order as host ab_validate_edit_diff.sh import_base.
set -eu
CFG="${CFG:-/root/chicago_smoke/work_xml}"
LOG="${LOG:-/root/chicago_smoke/work/load_base.log}"
export SR_VALIDATE_INCREMENTAL="${SR_VALIDATE_INCREMENTAL:-1}"
echo "load_base SR_VALIDATE_INCREMENTAL=${SR_VALIDATE_INCREMENTAL}"

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

edit() {
    f=$1
    [ -f "$f" ] || return 0
    echo "base: $f"
    if ! sysrepocfg --edit="$f" -d running -f xml >>"$LOG" 2>&1; then
        echo "WARN base failed: $f" | tee -a "$LOG"
        return 1
    fi
    return 0
}

fail=0
for f in hardware.xml qos-stack.xml voip-stack.xml platform-stack.xml network-vsubif.xml xpongemtcont-base.xml; do
    edit "${CFG}/00-base/${f}" || fail=$((fail + 1))
done
if [ -d "${CFG}/00-base/onu-templates" ]; then
    for f in "${CFG}/00-base/onu-templates/"*.xml; do
        edit "$f" || fail=$((fail + 1))
    done
fi
for f in forwarding-shell.xml keystore.xml truststore.xml system.xml device.xml datastore.xml subsys.xml netconf-server.xml lldp.xml; do
    edit "${CFG}/00-base/${f}" || fail=$((fail + 1))
done
echo "load_base done fail=${fail}"
[ "$fail" -eq 0 ]
