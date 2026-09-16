#!/usr/bin/env python3
"""Clone existing ONU provision/service XML with new serials (scale extrapolation)."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Reuse RPC wrapper from split_export when available
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))
try:
    from split_export import wrap_edit_config
except ImportError:
    def wrap_edit_config(config_body: str) -> str:
        lines = config_body.strip().splitlines()
        indented = "\n".join(f"        {line}" if line.strip() else "" for line in lines)
        return (
            "<edit-config>\n"
            "    <target>\n        <running/>\n    </target>\n"
            "    <test-option>test-then-set</test-option>\n"
            "    <error-option>rollback-on-error</error-option>\n"
            '    <config xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">\n'
            f"{indented}\n    </config>\n</edit-config>\n"
        )


FILENAME_RE = re.compile(r"^(\d+)-(.+)\.xml$")


def serial_from_filename(path: Path) -> str | None:
    m = FILENAME_RE.match(path.name)
    return m.group(2) if m else None


def index_from_filename(path: Path) -> int:
    m = FILENAME_RE.match(path.name)
    return int(m.group(1)) if m else 0


def replace_serial(text: str, old_serial: str, new_serial: str) -> str:
    if old_serial == new_serial:
        return text
    return text.replace(old_serial, new_serial)


def make_serial(prefix: str, seq: int) -> str:
    """12-char serial: prefix (4) + 8 hex digits."""
    return f"{prefix}{seq:08X}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--configs",
        type=Path,
        default=_SCRIPT_DIR / "work" / "configs",
    )
    parser.add_argument("--count", type=int, default=500, help="Number of synthetic ONUs to add")
    parser.add_argument(
        "--serial-prefix",
        default="SCLE",
        help="4-char serial prefix for synthetic ONUs (default: SCLE)",
    )
    parser.add_argument(
        "--start-seq",
        type=int,
        default=1,
        help="Starting sequence for serial suffix (hex in serial name)",
    )
    parser.add_argument(
        "--emit-rpc",
        action="store_true",
        help="Also write rpc/provision and rpc/service edit-config wrappers",
    )
    args = parser.parse_args()

    if len(args.serial_prefix) != 4:
        print("error: --serial-prefix must be exactly 4 characters", file=sys.stderr)
        return 1

    configs = args.configs
    prov_dir = configs / "onu-provision"
    svc_dir = configs / "onu-service"
    if not prov_dir.is_dir() or not svc_dir.is_dir():
        print(f"error: missing {prov_dir} or {svc_dir}; run split_export.py first", file=sys.stderr)
        return 1

    provision_donors = sorted(prov_dir.glob("*.xml"), key=index_from_filename)
    service_donors = sorted(svc_dir.glob("*.xml"), key=index_from_filename)
    if not provision_donors or not service_donors:
        print("error: no donor provision/service files", file=sys.stderr)
        return 1

    max_idx = max(index_from_filename(p) for p in provision_donors)
    max_idx = max(max_idx, max(index_from_filename(p) for p in service_donors))

    manifest_path = configs / "manifest.json"
    manifest: dict = {}
    if manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest.setdefault("provision", [])
    manifest.setdefault("service", [])
    manifest.setdefault("synthetic", [])

    rpc_prov_dir = configs / "rpc" / "provision"
    rpc_svc_dir = configs / "rpc" / "service"
    if args.emit_rpc:
        rpc_prov_dir.mkdir(parents=True, exist_ok=True)
        rpc_svc_dir.mkdir(parents=True, exist_ok=True)

    created: list[dict] = []
    for i in range(args.count):
        idx = max_idx + 1 + i
        seq = args.start_seq + i
        new_serial = make_serial(args.serial_prefix.upper(), seq)

        prov_donor = provision_donors[i % len(provision_donors)]
        svc_donor = service_donors[i % len(service_donors)]
        old_prov_serial = serial_from_filename(prov_donor)
        old_svc_serial = serial_from_filename(svc_donor)
        if not old_prov_serial or not old_svc_serial:
            print(f"error: cannot parse donor serial from {prov_donor} / {svc_donor}", file=sys.stderr)
            return 1

        prov_body = replace_serial(
            prov_donor.read_text(encoding="utf-8"), old_prov_serial, new_serial
        )
        svc_body = replace_serial(
            svc_donor.read_text(encoding="utf-8"), old_svc_serial, new_serial
        )

        prov_name = f"{idx:04d}-{new_serial}.xml"
        svc_name = f"{idx:04d}-{new_serial}.xml"
        prov_path = prov_dir / prov_name
        svc_path = svc_dir / svc_name
        prov_path.write_text(prov_body, encoding="utf-8")
        svc_path.write_text(svc_body, encoding="utf-8")

        entry = {
            "index": idx,
            "serial": new_serial,
            "provision": str(prov_path.relative_to(configs)),
            "service": str(svc_path.relative_to(configs)),
            "donor_provision": prov_donor.name,
            "donor_service": svc_donor.name,
        }
        created.append(entry)

        manifest["provision"].append(
            {"file": entry["provision"], "serial": new_serial, "synthetic": True}
        )
        manifest["service"].append(
            {"file": entry["service"], "serial": new_serial, "synthetic": True}
        )

        if args.emit_rpc:
            rpc_prov = rpc_prov_dir / prov_name.replace(".xml", ".edit-config.xml")
            rpc_svc = rpc_svc_dir / svc_name.replace(".xml", ".edit-config.xml")
            rpc_prov.write_text(wrap_edit_config(prov_body), encoding="utf-8")
            rpc_svc.write_text(wrap_edit_config(svc_body), encoding="utf-8")

    manifest["synthetic"].extend(created)
    if "summary" in manifest:
        manifest["summary"]["provision_files"] = len(list(prov_dir.glob("*.xml")))
        manifest["summary"]["service_files"] = len(list(svc_dir.glob("*.xml")))
        manifest["summary"]["synthetic_added"] = args.count
        manifest["summary"]["onu_total"] = manifest["summary"].get("onu_total", 0) + args.count

    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(
        json.dumps(
            {
                "added": args.count,
                "provision_total": len(list(prov_dir.glob("*.xml"))),
                "service_total": len(list(svc_dir.glob("*.xml"))),
                "index_range": f"{max_idx + 1:04d}-{max_idx + args.count:04d}",
                "serial_prefix": args.serial_prefix.upper(),
                "first_serial": make_serial(args.serial_prefix.upper(), args.start_seq),
                "last_serial": make_serial(args.serial_prefix.upper(), args.start_seq + args.count - 1),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
