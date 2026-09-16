#!/usr/bin/env python3
"""Pair onu-provision XML with onu-service XML by serial number.

N selects the first N provision files (ls / sorted name order). Service is
looked up by SN extracted from the filename (*-<SN>.xml). Index-N alignment
of the two directories is wrong: provision-only SNs shift the service list.

A provision with no matching service is still a pair: service path is '-'.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def serial_from_name(name: str) -> str:
    stem = Path(name).name
    if stem.lower().endswith(".xml"):
        stem = stem[:-4]
    if "-" in stem:
        return stem.split("-", 1)[1]
    return stem


def load_service_by_sn(svc_dir: Path) -> dict[str, Path]:
    by_sn: dict[str, Path] = {}
    dups: list[str] = []
    for path in sorted(svc_dir.glob("*.xml")):
        sn = serial_from_name(path.name)
        if sn in by_sn:
            dups.append(sn)
            continue
        by_sn[sn] = path
    if dups:
        print(f"warning: duplicate service SN skipped: {sorted(set(dups))}", file=sys.stderr)
    return by_sn


def build_pairs(configs: Path, n: int) -> list[tuple[int, str, Path, Path | None]]:
    prov_dir = configs / "onu-provision"
    svc_dir = configs / "onu-service"
    if not prov_dir.is_dir():
        raise SystemExit(f"missing {prov_dir}")
    if not svc_dir.is_dir():
        raise SystemExit(f"missing {svc_dir}")

    prov_files = sorted(prov_dir.glob("*.xml"))
    if n < 1:
        raise SystemExit("N must be >= 1")
    if n > len(prov_files):
        n = len(prov_files)

    svc_by_sn = load_service_by_sn(svc_dir)
    pairs: list[tuple[int, str, Path, Path | None]] = []
    for idx, prov in enumerate(prov_files[:n], start=1):
        sn = serial_from_name(prov.name)
        svc = svc_by_sn.get(sn)
        pairs.append((idx, sn, prov, svc))
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configs", type=Path, required=True)
    parser.add_argument("-n", type=int, required=True)
    parser.add_argument(
        "--format",
        choices=("tsv", "apply", "summary"),
        default="tsv",
        help="tsv: idx TAB rel_prov TAB rel_svc|-  apply: one abs path per line  summary: counts",
    )
    parser.add_argument("--preview", type=int, default=0, help="print first K pairs to stderr")
    args = parser.parse_args()

    configs = args.configs.resolve()
    pairs = build_pairs(configs, args.n)
    missing = [p for p in pairs if p[3] is None]
    if args.preview:
        for idx, sn, prov, svc in pairs[: args.preview]:
            svc_s = svc.name if svc is not None else "-"
            print(f"pair {idx} SN={sn} prov={prov.name} svc={svc_s}", file=sys.stderr)

    if args.format == "summary":
        print(f"n={len(pairs)} with_service={len(pairs) - len(missing)} missing_service={len(missing)}")
        if missing:
            print("missing_sn=" + ",".join(sn for _, sn, _, _ in missing))
        return 0

    if args.format == "apply":
        for _, _, prov, svc in pairs:
            print(prov)
            if svc is not None:
                print(svc)
        return 0

    for idx, _, prov, svc in pairs:
        rel_p = f"onu-provision/{prov.name}"
        rel_s = f"onu-service/{svc.name}" if svc is not None else "-"
        print(f"{idx}\t{rel_p}\t{rel_s}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
