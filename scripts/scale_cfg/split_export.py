#!/usr/bin/env python3
"""Split export.xml into base + per-ONU provision/service config fragments."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

IETF_HW_NS = "urn:ietf:params:xml:ns:yang:ietf-hardware"
IETF_IF_NS = "urn:ietf:params:xml:ns:yang:ietf-interfaces"
NC_NS = "urn:ietf:params:xml:ns:netconf:base:1.0"
BBF_ONUS_NS = "urn:bbf:yang:bbf-onus"
BBF_ONU_MGMT_NS = "urn:bbf:yang:bbf-onu-management"
BBF_FWD_NS = "urn:bbf:yang:bbf-l2-forwarding"
BBF_XGEM_NS = "urn:bbf:yang:bbf-xpongemtcont"
BBF_VOIP_MEDIA_NS = "urn:bbf:yang:bbf-voip-media"
BBF_VOIP_SIP_NS = "urn:bbf:yang:bbf-voip-sip"
VECIMA_ONU_VOIP_NS = "urn:vecima:yang:vecima-onu-voip"

TOP_TAGS = [
    "l2-dhcpv4-relay-profiles",
    "forwarding",
    "dhcpv6-ldra-profiles",
    "onus",
    "classifiers",
    "policies",
    "qos-policy-profiles",
    "tm-profiles",
    "xpon",
    "xpongemtcont",
    "lldp",
    "interfaces",
    "keystore",
    "netconf-server",
    "system",
    "truststore",
    "device",
    "datastore",
    "subsys",
    "media",
    "sip",
]

BASE_SHARED_TAGS = [
    "l2-dhcpv4-relay-profiles",
    "dhcpv6-ldra-profiles",
    "classifiers",
    "policies",
    "qos-policy-profiles",
    "tm-profiles",
    "xpon",
    "lldp",
    "keystore",
    "netconf-server",
    "system",
    "truststore",
    "device",
    "datastore",
    "subsys",
    "media",
    "sip",
]


def extract_module(text: str, tag: str) -> str | None:
    if tag == "media":
        m = re.search(
            rf"^<media xmlns=\"{re.escape(BBF_VOIP_MEDIA_NS)}\">.*?</media>",
            text,
            re.DOTALL | re.MULTILINE,
        )
        return m.group(0) if m else None
    if tag == "sip":
        m = re.search(
            rf"^<sip xmlns=\"{re.escape(BBF_VOIP_SIP_NS)}\">.*?</sip>",
            text,
            re.DOTALL | re.MULTILINE,
        )
        return m.group(0) if m else None
    if tag == "interfaces":
        m = re.search(
            rf"^<interfaces xmlns=\"{re.escape(IETF_IF_NS)}\">.*?</interfaces>",
            text,
            re.DOTALL | re.MULTILINE,
        )
        return m.group(0) if m else None
    m = re.search(rf"^<{tag}\b[^>]*>.*?</{tag}>", text, re.DOTALL | re.MULTILINE)
    return m.group(0) if m else None


def extract_elements(body: str, tag: str) -> list[str]:
    open_re = re.compile(rf"<{re.escape(tag)}(\s[^>]*)?>")
    close_tag = f"</{tag}>"
    out: list[str] = []
    i = 0
    while i < len(body):
        m = open_re.search(body, i)
        if not m:
            break
        start = m.start()
        depth = 0
        pos = start
        while pos < len(body):
            om = open_re.match(body, pos)
            if om:
                depth += 1
                pos = om.end()
            elif body.startswith(close_tag, pos):
                depth -= 1
                pos += len(close_tag)
                if depth == 0:
                    out.append(body[start:pos])
                    i = pos
                    break
            else:
                pos += 1
        else:
            break
    return out


def element_name(block: str) -> str | None:
    m = re.search(r"<name>([^<]+)</name>", block)
    return m.group(1) if m else None


def serial_hits(block: str, serials: set[str]) -> list[str]:
    return sorted(s for s in serials if s in block)


def is_platform_interface(block: str, serials: set[str]) -> bool:
    if serial_hits(block, serials):
        return False
    name = element_name(block)
    if not name:
        return False
    if re.match(r"^(pon\.|gpon\.|uplink-|lag-|chpair\.|chpart\.)", name):
        return True
    return "channel-termination" in block or "channel-pair" in block


def vani_shaper_patch(iface_block: str) -> str | None:
    name = element_name(iface_block)
    if not name or not name.endswith("-vani"):
        return None
    shaper = re.search(r"<shaper-name[^>]*>.*?</shaper-name>", iface_block, re.DOTALL)
    if not shaper:
        return None
    return (
        f"  <interface>\n"
        f"    <name>{name}</name>\n"
        f'    <v-ani xmlns="urn:bbf:yang:bbf-xponvani">\n'
        f"      {shaper.group(0)}\n"
        f"    </v-ani>\n"
        f"  </interface>"
    )


def strip_vani_shaper(iface_block: str) -> str:
    return re.sub(
        r"\s*<shaper-name[^>]*>.*?</shaper-name>",
        "",
        iface_block,
        flags=re.DOTALL,
    )


def strip_port_layer_if(iface_block: str) -> str:
    return re.sub(
        r'\s*<hardware-component xmlns="urn:bbf:yang:bbf-hardware">.*?</hardware-component>',
        "",
        iface_block,
        flags=re.DOTALL,
    )


def onu_create_body(onu_block: str) -> str:
    name = element_name(onu_block)
    meta = re.search(r"<meta-data>.*?</meta-data>", onu_block, re.DOTALL)
    if not name or not meta:
        raise ValueError("onu block missing name or meta-data")
    return (
        f'  <onu xmlns="{BBF_ONU_MGMT_NS}">\n'
        f"    <name>{name}</name>\n"
        f"    {meta.group(0)}\n"
        f"  </onu>"
    )


def onu_service_voip_instance(onu_block: str) -> str | None:
    """Per-ONU vecima-onu-voip sip under data-instance-from-template."""
    sip = re.search(
        rf'<sip xmlns="{re.escape(VECIMA_ONU_VOIP_NS)}">.*?</sip>',
        onu_block,
        re.DOTALL,
    )
    if not sip:
        return None
    return (
        "    <data-instance-from-template>\n"
        f"      {sip.group(0)}\n"
        "    </data-instance-from-template>"
    )


def onu_service_meta_body(onu_block: str) -> str:
    """Second RPC: meta-data replace; include per-ONU voip instance when present."""
    name = element_name(onu_block)
    meta = re.search(r"<meta-data>.*?</meta-data>", onu_block, re.DOTALL)
    if not name or not meta:
        raise ValueError("onu block missing name or meta-data")
    meta_xml = meta.group(0)
    if 'nc:operation="replace"' not in meta_xml:
        meta_xml = re.sub(
            r"<template-references>",
            '<template-references nc:operation="replace">',
            meta_xml,
            count=1,
        )
    voip_xml = onu_service_voip_instance(onu_block)
    parts = [
        f'  <onu xmlns="{BBF_ONU_MGMT_NS}">',
        f"    <name>{name}</name>",
        f"    {meta_xml}",
    ]
    if voip_xml:
        parts.append(voip_xml)
    parts.append("  </onu>")
    return "\n".join(parts)


def is_network_vsubif(iface_block: str) -> bool:
    name = element_name(iface_block)
    return bool(name and name.startswith("vsubif-lag-"))


def wrap_forwarder_ports(forwarder_name: str, ports: list[str]) -> str:
    port_xml = "\n".join(f"        {p.strip()}" for p in ports)
    return f"""<forwarding xmlns="{BBF_FWD_NS}">
  <forwarders>
    <forwarder>
      <name>{forwarder_name}</name>
      <ports>
{port_xml}
      </ports>
    </forwarder>
  </forwarders>
</forwarding>
"""


def wrap_xpongemtcont_service(items: list[str]) -> str:
    tconts = [item for item in items if re.match(r"<tcont\b", item.strip())]
    gemports = [item for item in items if re.match(r"<gemport\b", item.strip())]
    chunks: list[str] = []
    if tconts:
        chunks.append(
            "<tconts>\n" + "\n".join(f"    {item.strip()}" for item in tconts) + "\n  </tconts>"
        )
    if gemports:
        chunks.append(
            "<gemports>\n" + "\n".join(f"    {item.strip()}" for item in gemports) + "\n  </gemports>"
        )
    return f'<xpongemtcont xmlns="{BBF_XGEM_NS}">\n  ' + "\n  ".join(chunks) + "\n</xpongemtcont>\n"


def build_forwarding_shell(forwarding_xml: str, serials: set[str]) -> str:
    body = re.sub(r"^<forwarding\b[^>]*>|</forwarding>\s*$", "", forwarding_xml, flags=re.DOTALL).strip()
    forwarders = extract_elements(body, "forwarder")
    rebuilt: list[str] = []
    for fw in forwarders:
        fw_name = element_name(fw)
        ports = extract_elements(fw, "port")
        keep = [p for p in ports if "fwd-port-onu-" not in p and not serial_hits(p, serials)]
        tail = re.sub(r"<ports>.*?</ports>", "", fw, flags=re.DOTALL)
        tail = re.sub(r"^\s*<forwarder>\s*", "", tail)
        tail = re.sub(r"\s*</forwarder>\s*$", "", tail)
        port_xml = "\n".join(f"        {p.strip()}" for p in keep)
        rebuilt.append(
            f"    <forwarder>\n      {tail.strip()}\n      <ports>\n{port_xml}\n      </ports>\n    </forwarder>"
        )
    databases = re.search(r"<forwarding-databases>.*?</forwarding-databases>", body, re.DOTALL)
    db_xml = databases.group(0) if databases else ""
    return f'<forwarding xmlns="{BBF_FWD_NS}">\n  <forwarders>\n' + "\n".join(rebuilt) + f"\n  </forwarders>\n  {db_xml}\n</forwarding>\n"


def build_xpongemtcont_base(xpongemtcont_xml: str, serials: set[str]) -> str:
    del serials  # per-ONU tcont/gemport live under dedicated list containers.
    body = re.sub(r"^<xpongemtcont\b[^>]*>|</xpongemtcont>\s*$", "", xpongemtcont_xml, flags=re.DOTALL).strip()
    body = re.sub(r"<tconts>.*?</tconts>\s*", "", body, flags=re.DOTALL)
    body = re.sub(r"<gemports>.*?</gemports>\s*", "", body, flags=re.DOTALL)
    return f'<xpongemtcont xmlns="{BBF_XGEM_NS}">\n{body}\n</xpongemtcont>\n'


def wrap_onus(inner: str) -> str:
    return f'<onus xmlns="{BBF_ONUS_NS}">\n{inner.rstrip()}\n</onus>\n'


def template_slug(name: str) -> str:
    slug = re.sub(r"[^\w.-]+", "_", name).strip("_")
    return slug or "unknown"


BASE_RPC_ORDER = [
    "hardware.xml",
    "qos-stack.xml",
    "voip-stack.xml",
    "platform-stack.xml",
    "network-vsubif.xml",
    "xpongemtcont-base.xml",
    "onu-templates/",  # directory: shared + one file per template
    "forwarding-shell.xml",
    "keystore.xml",
    "truststore.xml",
    "system.xml",
    "device.xml",
    "datastore.xml",
    "subsys.xml",
    "netconf-server.xml",
    "lldp.xml",
]


def iter_base_config_paths(base_dir: Path) -> list[Path]:
    """Return base XML paths in harness load order."""
    paths: list[Path] = []
    for name in BASE_RPC_ORDER:
        if name == "onu-templates/":
            tpl_dir = base_dir / "onu-templates"
            legacy = base_dir / "onu-templates.xml"
            if tpl_dir.is_dir():
                paths.extend(sorted(tpl_dir.glob("*.xml")))
            elif legacy.is_file():
                paths.append(legacy)
            continue
        path = base_dir / name
        if path.is_file():
            paths.append(path)
    return paths


def wrap_edit_config(config_body: str) -> str:
    """Wrap config fragment in NETCONF edit-config RPC (matches controller envelope)."""
    lines = config_body.strip().splitlines()
    indented = "\n".join(f"        {line}" if line.strip() else "" for line in lines)
    return (
        "<edit-config>\n"
        "    <target>\n"
        "        <running/>\n"
        "    </target>\n"
        "    <test-option>test-then-set</test-option>\n"
        "    <error-option>rollback-on-error</error-option>\n"
        f'    <config xmlns:nc="{NC_NS}">\n'
        f"{indented}\n"
        "    </config>\n"
        "</edit-config>\n"
    )


def emit_rpc_wrappers(
    out: Path,
    base_dir: Path,
    provision_dir: Path,
    service_dir: Path,
    manifest: dict,
) -> None:
    """Mirror config bodies as one edit-config RPC per file under rpc/."""
    rpc_root = out / "rpc"
    rpc_base = rpc_root / "base"
    rpc_provision = rpc_root / "provision"
    rpc_service = rpc_root / "service"
    rpc_base.mkdir(parents=True, exist_ok=True)
    rpc_provision.mkdir(parents=True, exist_ok=True)
    rpc_service.mkdir(parents=True, exist_ok=True)

    rpc_manifest: dict = {"base": [], "provision": [], "service": []}
    seq = 0
    for src in iter_base_config_paths(base_dir):
        seq += 1
        rel = src.relative_to(base_dir)
        stem = str(rel).replace("/", "__").removesuffix(".xml")
        dest = rpc_base / f"{seq:02d}-{stem}.edit-config.xml"
        body = src.read_text(encoding="utf-8")
        rpc_manifest["base"].append(
            {
                "file": str(dest.relative_to(out)),
                "source": f"00-base/{rel}",
                "bytes": write_text(dest, wrap_edit_config(body)),
            }
        )

    for entry in manifest["provision"]:
        src_name = Path(entry["file"]).name
        dest = rpc_provision / src_name.replace(".xml", ".edit-config.xml")
        body = (provision_dir / src_name).read_text(encoding="utf-8")
        rpc_manifest["provision"].append(
            {
                "file": str(dest.relative_to(out)),
                "serial": entry["serial"],
                "bytes": write_text(dest, wrap_edit_config(body)),
            }
        )

    for entry in manifest["service"]:
        src_name = Path(entry["file"]).name
        dest = rpc_service / src_name.replace(".xml", ".edit-config.xml")
        body = (service_dir / src_name).read_text(encoding="utf-8")
        rpc_manifest["service"].append(
            {
                "file": str(dest.relative_to(out)),
                "serial": entry["serial"],
                "bytes": write_text(dest, wrap_edit_config(body)),
            }
        )

    readme = rpc_root / "README.txt"
    write_text(
        readme,
        "\n".join(
            [
                "NETCONF edit-config RPC files generated from export.xml split.",
                "",
                "Directory layout:",
                "  rpc/base/       - platform bootstrap (load once, in numeric order)",
                "  rpc/provision/  - RPC 1 per ONU: v-ani + onu meta-data",
                "  rpc/service/    - RPC 2 per ONU: eth/vlan + shaper + tcont/gem + fwd port",
                "",
                "Config bodies (without envelope) for sysrepocfg --edit:",
                "  00-base/  onu-provision/  onu-service/",
                "",
                f"Counts: base={len(rpc_manifest['base'])} "
                f"provision={len(rpc_manifest['provision'])} "
                f"service={len(rpc_manifest['service'])}",
                "",
                "Note: split from export.xml final state, not live controller RPC capture.",
            ]
        )
        + "\n",
    )
    manifest["rpc"] = rpc_manifest
    manifest["rpc"]["readme"] = str(readme.relative_to(out))


def write_text(path: Path, content: str) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return len(content.encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--export",
        type=Path,
        default=Path(__file__).resolve().parent / "results" / "export.xml",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent / "work" / "configs",
    )
    parser.add_argument(
        "--hardware",
        type=Path,
        default=Path(__file__).resolve().parent.parent.parent.parent / "xpon-yang" / "yang" / "init-data" / "ietf-hardware.xml",
    )
    args = parser.parse_args()

    if not args.export.is_file():
        print(f"error: export not found: {args.export}", file=sys.stderr)
        return 1

    text = args.export.read_text(encoding="utf-8", errors="replace")
    out = args.out
    if out.exists():
        shutil.rmtree(out)
    base_dir = out / "00-base"
    provision_dir = out / "onu-provision"
    service_dir = out / "onu-service"
    base_dir.mkdir(parents=True)
    provision_dir.mkdir()
    service_dir.mkdir()

    modules = {tag: extract_module(text, tag) for tag in TOP_TAGS}
    onus_xml = modules.get("onus")
    if not onus_xml:
        print("error: onus module missing", file=sys.stderr)
        return 1

    onus_body = re.sub(r"^<onus\b[^>]*>|</onus>\s*$", "", onus_xml, flags=re.DOTALL)
    onu_blocks = extract_elements(onus_body, "onu")
    template_blocks = re.findall(
        r'<template xmlns="urn:bbf:yang:bbf-onu-management">.*?</template>',
        onus_body,
        re.DOTALL,
    )
    serials = {element_name(b).replace("-vani", "") for b in onu_blocks if element_name(b)}
    serials.discard(None)

    manifest: dict = {"export": str(args.export), "base": [], "provision": [], "service": []}

    if args.hardware.is_file():
        hw = args.hardware.read_text(encoding="utf-8")
        manifest["base"].append({"file": "hardware.xml", "bytes": write_text(base_dir / "hardware.xml", hw)})
    else:
        print(f"warning: hardware init file missing: {args.hardware}", file=sys.stderr)

    qos_tags = [
        "classifiers",
        "policies",
        "qos-policy-profiles",
        "tm-profiles",
        "l2-dhcpv4-relay-profiles",
        "dhcpv6-ldra-profiles",
    ]
    qos_parts = [modules[tag] for tag in qos_tags if modules.get(tag)]
    if qos_parts:
        manifest["base"].append(
            {
                "file": "qos-stack.xml",
                "bytes": write_text(base_dir / "qos-stack.xml", "\n".join(qos_parts) + "\n"),
            }
        )

    voip_parts = [modules[tag] for tag in ("media", "sip") if modules.get(tag)]
    if voip_parts:
        manifest["base"].append(
            {
                "file": "voip-stack.xml",
                "bytes": write_text(base_dir / "voip-stack.xml", "\n".join(voip_parts) + "\n"),
            }
        )

    for tag in ["system", "device", "datastore", "subsys", "keystore", "truststore", "netconf-server", "lldp"]:
        if modules.get(tag):
            manifest["base"].append(
                {"file": f"{tag}.xml", "bytes": write_text(base_dir / f"{tag}.xml", modules[tag] + "\n")}
            )

    platform_parts: list[str] = []
    if modules.get("xpon"):
        platform_parts.append(modules["xpon"])
    iface_mod = modules.get("interfaces")
    plat_iface_xml = ""
    per_iface: dict[str, dict[str, list[str]]] = {}
    if iface_mod:
        iface_body = re.sub(r"^<interfaces\b[^>]*>|</interfaces>\s*$", "", iface_mod, flags=re.DOTALL)
        iface_blocks = extract_elements(iface_body, "interface")
        plat = [b for b in iface_blocks if is_platform_interface(b, serials)]
        shared = [
            b
            for b in iface_blocks
            if not serial_hits(b, serials) and not is_platform_interface(b, serials)
        ]
        vsubif = [b for b in shared if is_network_vsubif(b)]
        shared_other = [b for b in shared if not is_network_vsubif(b)]
        if plat or shared_other:
            plat_iface_xml = (
                f'<interfaces xmlns="{IETF_IF_NS}">\n'
                + "\n".join(f"  {strip_port_layer_if(b).strip()}" for b in plat + shared_other)
                + "\n</interfaces>\n"
            )
            platform_parts.append(plat_iface_xml)
        if vsubif:
            vsubif_xml = (
                f'<interfaces xmlns="{IETF_IF_NS}">\n'
                + "\n".join(f"  {strip_port_layer_if(b).strip()}" for b in vsubif)
                + "\n</interfaces>\n"
            )
            manifest["base"].append(
                {
                    "file": "network-vsubif.xml",
                    "bytes": write_text(base_dir / "network-vsubif.xml", vsubif_xml),
                }
            )

        for b in iface_blocks:
            hits = serial_hits(b, serials)
            if len(hits) != 1:
                continue
            serial = hits[0]
            name = element_name(b) or ""
            bucket = per_iface.setdefault(serial, {"create": [], "service": [], "service_extra": []})
            if name.endswith("-vani"):
                bucket["create"].append(strip_vani_shaper(b))
                patch = vani_shaper_patch(b)
                if patch:
                    bucket["service_extra"].append(patch)
            else:
                bucket["service"].append(b)

    if platform_parts:
        manifest["base"].append(
            {
                "file": "platform-stack.xml",
                "bytes": write_text(base_dir / "platform-stack.xml", "\n".join(platform_parts) + "\n"),
            }
        )

    shared_onus = ""
    if template_blocks:
        shared_onus = onus_body
        for block in onu_blocks:
            shared_onus = shared_onus.replace(block, "")
        for block in template_blocks:
            shared_onus = shared_onus.replace(block, "")
        shared_onus = shared_onus.strip()

    if template_blocks or shared_onus:
        templates_dir = base_dir / "onu-templates"
        templates_dir.mkdir(parents=True, exist_ok=True)
        if shared_onus:
            shared_rel = "onu-templates/00-onu-template-shared.xml"
            manifest["base"].append(
                {
                    "file": shared_rel,
                    "bytes": write_text(
                        base_dir / shared_rel,
                        wrap_onus(shared_onus),
                    ),
                }
            )
        for idx, block in enumerate(
            sorted(template_blocks, key=lambda b: element_name(b) or ""),
            start=1,
        ):
            tname = element_name(block) or f"unknown-{idx}"
            fname = f"{idx:02d}-template-{template_slug(tname)}.xml"
            rel = f"onu-templates/{fname}"
            manifest["base"].append(
                {
                    "file": rel,
                    "template": tname,
                    "bytes": write_text(
                        base_dir / rel,
                        wrap_onus(f"  {block.strip()}"),
                    ),
                }
            )

    if modules.get("forwarding"):
        manifest["base"].append(
            {
                "file": "forwarding-shell.xml",
                "bytes": write_text(
                    base_dir / "forwarding-shell.xml",
                    build_forwarding_shell(modules["forwarding"], serials),
                ),
            }
        )

    if modules.get("xpongemtcont"):
        manifest["base"].append(
            {
                "file": "xpongemtcont-base.xml",
                "bytes": write_text(
                    base_dir / "xpongemtcont-base.xml",
                    build_xpongemtcont_base(modules["xpongemtcont"], serials),
                ),
            }
        )

    per_xpon: dict[str, list[str]] = {s: [] for s in serials}
    if modules.get("xpongemtcont"):
        xbody = re.sub(r"^<xpongemtcont\b[^>]*>|</xpongemtcont>\s*$", "", modules["xpongemtcont"], flags=re.DOTALL)
        for tag in ("tcont", "gemport"):
            for item in extract_elements(xbody, tag):
                hits = serial_hits(item, serials)
                if len(hits) == 1:
                    per_xpon[hits[0]].append(item)

    per_fwd: dict[str, list[tuple[str, str]]] = {s: [] for s in serials}
    if modules.get("forwarding"):
        fbody = re.sub(r"^<forwarding\b[^>]*>|</forwarding>\s*$", "", modules["forwarding"], flags=re.DOTALL)
        for fw in extract_elements(fbody, "forwarder"):
            fw_name = element_name(fw) or "unknown"
            for port in extract_elements(fw, "port"):
                hits = serial_hits(port, serials)
                if len(hits) == 1:
                    per_fwd[hits[0]].append((fw_name, port))

    onu_by_serial = {}
    for block in onu_blocks:
        name = element_name(block)
        if not name:
            continue
        onu_by_serial[name.replace("-vani", "")] = block

    provision_count = 0
    service_count = 0
    for idx, serial in enumerate(sorted(serials), start=1):
        onu_block = onu_by_serial.get(serial)
        if not onu_block:
            continue
        prefix = f"{idx:04d}-{serial}"

        # RPC 1 — provision: hardware + v-ani + onu meta (initial template)
        provision_parts = [
            f'<hardware xmlns="{IETF_HW_NS}"/>',
        ]
        create_ifaces = per_iface.get(serial, {}).get("create", [])
        if create_ifaces:
            provision_parts.append(
                f'<interfaces xmlns="{IETF_IF_NS}">\n'
                + "\n".join(f"  {b.strip()}" for b in create_ifaces)
                + "\n</interfaces>"
            )
        provision_parts.append(
            f'<onus xmlns="{BBF_ONUS_NS}">\n{onu_create_body(onu_block)}\n</onus>'
        )
        provision_path = provision_dir / f"{prefix}.xml"
        manifest["provision"].append(
            {
                "file": str(provision_path.relative_to(out)),
                "serial": serial,
                "bytes": write_text(provision_path, "\n".join(provision_parts) + "\n"),
            }
        )
        provision_count += 1

        # RPC 2 — service: hardware + eth/vlan + vani shaper + tcont/gem + fwd port + template replace
        service_parts: list[str] = [f'<hardware xmlns="{IETF_HW_NS}"/>']
        iface_bucket = per_iface.get(serial, {})
        svc_ifaces = iface_bucket.get("service", []) + iface_bucket.get("service_extra", [])
        if svc_ifaces:
            service_parts.append(
                f'<interfaces xmlns="{IETF_IF_NS}">\n'
                + "\n".join(f"  {b.strip()}" for b in svc_ifaces)
                + "\n</interfaces>"
            )
        xpon_items = per_xpon.get(serial, [])
        if xpon_items:
            service_parts.append(wrap_xpongemtcont_service(xpon_items).strip())
        service_parts.append(
            f'<onus xmlns="{BBF_ONUS_NS}" xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">\n'
            f"{onu_service_meta_body(onu_block)}\n</onus>"
        )
        fwd_items = per_fwd.get(serial, [])
        if fwd_items:
            by_fw: dict[str, list[str]] = {}
            for fw_name, port in fwd_items:
                by_fw.setdefault(fw_name, []).append(port)
            for fw_name, ports in by_fw.items():
                service_parts.append(wrap_forwarder_ports(fw_name, ports).strip())

        has_voip = onu_service_voip_instance(onu_block) is not None
        if len(service_parts) <= 2 and not fwd_items and not xpon_items and not svc_ifaces and not has_voip:
            continue
        service_path = service_dir / f"{prefix}.xml"
        manifest["service"].append(
            {
                "file": str(service_path.relative_to(out)),
                "serial": serial,
                "bytes": write_text(service_path, "\n".join(service_parts) + "\n"),
            }
        )
        service_count += 1

    emit_rpc_wrappers(out, base_dir, provision_dir, service_dir, manifest)

    manifest["summary"] = {
        "onu_total": len(serials),
        "provision_files": provision_count,
        "service_files": service_count,
        "base_files": len(manifest["base"]),
        "onu_template_files": sum(1 for e in manifest["base"] if e["file"].startswith("onu-templates/")),
        "rpc_base_files": len(manifest["rpc"]["base"]),
        "rpc_provision_files": len(manifest["rpc"]["provision"]),
        "rpc_service_files": len(manifest["rpc"]["service"]),
    }
    write_text(out / "manifest.json", json.dumps(manifest, indent=2) + "\n")

    print(json.dumps(manifest["summary"], indent=2))
    print(f"configs written under {out}")
    print(f"RPC review files: {out / 'rpc'}/ (see rpc/README.txt)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
