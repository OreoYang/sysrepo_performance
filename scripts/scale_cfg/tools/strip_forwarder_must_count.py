#!/usr/bin/env python3
"""Remove the forwarder-port sub-interface uniqueness must from a sysrepo repo copy.

Used only by the scale_cfg A/B harness (STRIP_FORWARDER_MUST_COUNT=1). The
canonical YANG cache is unchanged; only FRESH_REPO after cp -a is patched.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MODULE = "bbf-l2-forwarding-forwarders@2022-03-01.yang"
MUST_BLOCK = re.compile(
    r'              must\n                "count\(/bbf-l2-fwd:forwarding.*?< 2" \{.*?\n              \}\n',
    re.DOTALL,
)


def strip_file(path: Path) -> None:
    text = path.read_text()
    new, n = MUST_BLOCK.subn("", text)
    if n != 1:
        raise SystemExit(f"{path}: expected 1 must block, got {n}")
    path.write_text(new)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <sysrepo_repo_root>")
    root = Path(sys.argv[1])
    yang = root / "yang" / MODULE
    if not yang.is_file():
        yang = next((p for p in root.glob(f"yang/**/{MODULE}") if p.is_file()), None)
    if yang is None:
        raise SystemExit(f"{MODULE} not found under {root}")
    strip_file(yang)
    print(f"stripped forwarder must count in {yang}")


if __name__ == "__main__":
    main()