#!/usr/bin/env bash
# Generate provision XML for one ONU on Chicago (chpart.gpon.PON / chpair.gpon.PON).
set -euo pipefail

SERIAL="${1:?usage: gen_provision.sh SERIAL PON [TEMPLATE] [outfile]}"
PON="${2:?}"
TEMPLATE="${3:-${ONU_TEMPLATE:-default-onu-template}}"
OUT="${4:-}"
PON_TECH="${PON_TECH:-xgs}"

if [ "$PON_TECH" = gpon ]; then
    CHPART="chpart.gpon.${PON}"
    CHPAIR="chpair.gpon.${PON}"
else
    CHPART="chpart.${PON}"
    CHPAIR="chpair.${PON}"
fi
VANI="${SERIAL}-vani"

body=$(cat <<EOF
<interfaces xmlns="urn:ietf:params:xml:ns:yang:ietf-interfaces">
  <interface>
    <name>${VANI}</name>
    <type xmlns:bbf-xponift="urn:bbf:yang:bbf-xpon-if-type">bbf-xponift:v-ani</type>
    <v-ani xmlns="urn:bbf:yang:bbf-xponvani">
      <channel-partition>${CHPART}</channel-partition>
      <expected-serial-number>${SERIAL}</expected-serial-number>
      <preferred-channel-pair>${CHPAIR}</preferred-channel-pair>
    </v-ani>
  </interface>
</interfaces>
<onus xmlns="urn:bbf:yang:bbf-onus">
  <onu xmlns="urn:bbf:yang:bbf-onu-management">
    <name>${VANI}</name>
    <meta-data>
      <instance-origin>instance-from-template</instance-origin>
      <template-references>
        <template>${TEMPLATE}</template>
      </template-references>
    </meta-data>
  </onu>
</onus>
EOF
)

if [[ -n "$OUT" ]]; then
    printf '%s\n' "$body" > "$OUT"
    echo "wrote ${OUT}"
else
    printf '%s\n' "$body"
fi
