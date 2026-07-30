#!/usr/bin/env python3
"""Verify running sysrepo has platform + template refs required before ONU create edits."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def sysrepocfg_export_module(executable: str, module: str) -> str:
    with tempfile.NamedTemporaryFile(mode="w+", suffix=".xml", delete=False) as tmp:
        path = tmp.name
    try:
        proc = subprocess.run(
            [executable, f"--export={path}", "-m", module, "-d", "running", "-f", "xml"],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"export {module} failed")
        return Path(path).read_text(encoding="utf-8", errors="replace")
    finally:
        Path(path).unlink(missing_ok=True)


def collect_create_refs(create_dir: Path) -> dict[str, set[str]]:
    chparts: set[str] = set()
    chpairs: set[str] = set()
    templates: set[str] = set()
    for path in sorted(create_dir.glob("*.xml")):
        text = path.read_text(encoding="utf-8", errors="replace")
        chparts.update(re.findall(r"<channel-partition>([^<]+)</channel-partition>", text))
        chpairs.update(re.findall(r"<preferred-channel-pair>([^<]+)</preferred-channel-pair>", text))
        templates.update(re.findall(r"<template>([^<]+)</template>", text))
    return {"chpart": chparts, "chpair": chpairs, "template": templates}


def interface_names(ifaces_xml: str) -> set[str]:
    return set(re.findall(r"<interface>\s*<name>([^<]+)</name>", ifaces_xml))


def template_names(onus_xml: str) -> set[str]:
    return set(
        re.findall(
            r'<template xmlns="urn:bbf:yang:bbf-onu-management">\s*<name>([^<]+)</name>',
            onus_xml,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--configs",
        type=Path,
        default=Path(__file__).resolve().parent / "work" / "configs",
    )
    parser.add_argument(
        "--sysrepocfg",
        default=os.environ.get("SYSREPOCFG_EXECUTABLE", "sysrepocfg"),
    )
    args = parser.parse_args()

    create_dir = args.configs / "onu-provision"
    if not create_dir.is_dir():
        create_dir = args.configs / "onu-create"
    if not create_dir.is_dir():
        print(f"error: missing onu-provision/ or onu-create/ under {args.configs}", file=sys.stderr)
        return 1

    refs = collect_create_refs(create_dir)
    if not refs["chpart"]:
        print("error: no channel-partition refs found in onu-provision/*.xml", file=sys.stderr)
        return 1

    print(f"preflight: {len(refs['chpart'])} unique chpart, {len(refs['chpair'])} chpair, {len(refs['template'])} templates from create files")

    try:
        ifaces_xml = sysrepocfg_export_module(args.sysrepocfg, "ietf-interfaces")
        onus_xml = sysrepocfg_export_module(args.sysrepocfg, "bbf-onus")
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    present_if = interface_names(ifaces_xml)
    present_tpl = template_names(onus_xml)

    missing_chpart = sorted(refs["chpart"] - present_if)
    missing_chpair = sorted(refs["chpair"] - present_if)
    missing_tpl = sorted(refs["template"] - present_tpl)

    ok = True
    if missing_chpart:
        ok = False
        print(f"MISSING channel-partition interfaces ({len(missing_chpart)}): {missing_chpart[:8]}", file=sys.stderr)
        if len(missing_chpart) > 8:
            print(f"  ... and {len(missing_chpart) - 8} more", file=sys.stderr)
    else:
        print("ok: all channel-partition refs present in running/ietf-interfaces")

    if missing_chpair:
        ok = False
        print(f"MISSING channel-pair interfaces ({len(missing_chpair)}): {missing_chpair[:8]}", file=sys.stderr)
        if len(missing_chpair) > 8:
            print(f"  ... and {len(missing_chpair) - 8} more", file=sys.stderr)
    else:
        print("ok: all channel-pair refs present in running/ietf-interfaces")

    if missing_tpl:
        ok = False
        print(f"MISSING onu templates ({len(missing_tpl)}): {missing_tpl[:8]}", file=sys.stderr)
        if len(missing_tpl) > 8:
            print(f"  ... and {len(missing_tpl) - 8} more", file=sys.stderr)
    else:
        print("ok: all template refs present in running/bbf-onus")

    print(f"running ietf-interfaces: {len(present_if)} interfaces exported")
    print(f"running bbf-onus: {len(present_tpl)} templates exported")

    if not ok:
        print(
            "error: base not ready for ONU provision — fix base import (platform-stack, onu-templates) before timed provision",
            file=sys.stderr,
        )
        return 1

    print("preflight: base ready for ONU provision")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
