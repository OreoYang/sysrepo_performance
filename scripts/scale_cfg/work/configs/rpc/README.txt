NETCONF edit-config RPC files generated from export.xml split.

Directory layout:
  rpc/base/       - platform bootstrap (load once, in numeric order)
  rpc/provision/  - RPC 1 per ONU: v-ani + onu meta-data
  rpc/service/    - RPC 2 per ONU: eth/vlan + shaper + tcont/gem + fwd port

Config bodies (without envelope) for sysrepocfg --edit:
  00-base/  onu-provision/  onu-service/

Counts: base=34 provision=1022 service=1016

Note: split from export.xml final state, not live controller RPC capture.
