#!/bin/sh
# Minimal service XML using profiles that exist on Chicago (2026-08-19 probe).
# No VoIP / Prod template / largescale TD names.
set -eu

SERIAL="${1:?usage: gen_service.sh SERIAL [TD_PROFILE] [outfile]}"
TD="${2:-${TD_PROFILE:-gpon5m}}"
OUT="${3:-}"
VANI="${SERIAL}-vani"
ETH="${SERIAL}-eth1"
VSI="${ETH}.vsi.cvlan2000.untag"

body=$(cat <<EOF
<interfaces xmlns="urn:ietf:params:xml:ns:yang:ietf-interfaces">
  <interface>
    <name>${ETH}</name>
    <type xmlns:bbf-xponift="urn:bbf:yang:bbf-xpon-if-type">bbf-xponift:olt-v-enet</type>
    <enabled>true</enabled>
    <olt-v-enet xmlns="urn:bbf:yang:bbf-xponvani">
      <lower-layer-interface>${VANI}</lower-layer-interface>
    </olt-v-enet>
  </interface>
  <interface>
    <name>${VSI}</name>
    <type xmlns:bbfift="urn:bbf:yang:bbf-if-type">bbfift:vlan-sub-interface</type>
    <l2-dhcpv4-relay xmlns="urn:bbf:yang:bbf-l2-dhcpv4-relay">
      <enable>true</enable>
      <profile-ref>dhcp-relay-profile</profile-ref>
    </l2-dhcpv4-relay>
    <dhcpv6-ldra xmlns="urn:bbf:yang:bbf-ldra">
      <enable>true</enable>
      <profile-ref>dhcpv6_replay_profile</profile-ref>
    </dhcpv6-ldra>
    <ingress-qos-policy-profile xmlns="urn:bbf:yang:bbf-qos-policies">pp-all-to-tc0</ingress-qos-policy-profile>
    <subif-lower-layer xmlns="urn:bbf:yang:bbf-sub-interfaces">
      <interface>${ETH}</interface>
    </subif-lower-layer>
    <inline-frame-processing xmlns="urn:bbf:yang:bbf-sub-interfaces">
      <ingress-rule>
        <rule>
          <name>u1_eth1_cvlan2000_untag</name>
          <priority>1</priority>
          <flexible-match>
            <match-criteria xmlns="urn:bbf:yang:bbf-sub-interface-tagging">
              <tag>
                <index>0</index>
                <dot1q-tag>
                  <tag-type xmlns:bbf-dot1qt="urn:bbf:yang:bbf-dot1q-types">bbf-dot1qt:c-vlan</tag-type>
                  <vlan-id>2000</vlan-id>
                </dot1q-tag>
              </tag>
            </match-criteria>
          </flexible-match>
          <ingress-rewrite>
            <pop-tags xmlns="urn:bbf:yang:bbf-sub-interface-tagging">1</pop-tags>
            <push-tag xmlns="urn:bbf:yang:bbf-sub-interface-tagging">
              <index>0</index>
              <dot1q-tag>
                <tag-type xmlns:bbf-dot1qt="urn:bbf:yang:bbf-dot1q-types">bbf-dot1qt:c-vlan</tag-type>
                <vlan-id>2000</vlan-id>
                <write-pbit>0</write-pbit>
                <write-dei-0/>
              </dot1q-tag>
            </push-tag>
          </ingress-rewrite>
        </rule>
      </ingress-rule>
    </inline-frame-processing>
  </interface>
</interfaces>
<xpongemtcont xmlns="urn:bbf:yang:bbf-xpongemtcont">
  <tconts>
    <tcont>
      <name>tcont-${SERIAL}/eth1.tcont-1</name>
      <interface-reference>${VANI}</interface-reference>
      <traffic-descriptor-profile-ref>${TD}</traffic-descriptor-profile-ref>
    </tcont>
  </tconts>
  <gemports>
    <gemport>
      <name>gem-${SERIAL}/eth1.cvlan2000.untag.tc0</name>
      <interface>${VSI}</interface>
      <traffic-class>0</traffic-class>
      <tcont-ref>tcont-${SERIAL}/eth1.tcont-1</tcont-ref>
    </gemport>
  </gemports>
</xpongemtcont>
<forwarding xmlns="urn:bbf:yang:bbf-l2-forwarding">
  <forwarders>
    <forwarder>
      <name>fwd_nto1_cvlan2000</name>
      <ports>
        <port>
          <name>fwd-port-onu-${SERIAL}/eth1-cvlan2000-untag</name>
          <sub-interface>${VSI}</sub-interface>
        </port>
      </ports>
    </forwarder>
  </forwarders>
</forwarding>
EOF
)

if [ -n "$OUT" ]; then
    printf '%s\n' "$body" > "$OUT"
    echo "wrote ${OUT}"
else
    printf '%s\n' "$body"
fi
