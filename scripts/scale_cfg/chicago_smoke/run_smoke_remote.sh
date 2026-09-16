#!/usr/bin/env bash
# Drive one STAGE on Chicago. Default STAGE=provision (single ONU).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.chicago.sh
source "${SCRIPT_DIR}/env.chicago.sh"
# shellcheck source=lib_ssh.sh
source "${SCRIPT_DIR}/lib_ssh.sh"

STAGE="${STAGE:-provision}"
REMOTE="${OLT_SMOKE_DIR}"

echo "=== Chicago STAGE=${STAGE} ONU_SN=${ONU_SN} PON=${PON} TEMPLATE=${ONU_TEMPLATE} ==="
chicago_ssh "export ONU_SN='${ONU_SN}' PON='${PON}' PON_TECH='${PON_TECH}' ONU_TEMPLATE='${ONU_TEMPLATE}' TD_PROFILE='${TD_PROFILE}' STAGE='${STAGE}' && cd '${REMOTE}/olt' && ./run_smoke_on_olt.sh"
