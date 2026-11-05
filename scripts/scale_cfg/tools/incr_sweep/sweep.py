#!/usr/bin/env python3
"""Driver of the incremental validation sweep on the production configuration.

Builds the dataset (base config, every ONU template, one ONU per template with provision and service), the list of
further ONUs, runs bin/sweep and leaves the verdict table and the cover lines in out/.

usage: sweep.py [--per-node N] [--mixed N] [--seed N] [--onus rep|all]
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.environ.get("PROD_WORK", os.path.join(HERE, "..", "..", "work_voip"))
CFG = os.path.join(W, "configs")
YANG = os.path.join(W, "db_1230_voip/upper/sysrepo/yang")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-node", type=int, default=4)
    ap.add_argument("--mixed", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--onus", default="rep")
    ap.add_argument("--bin", default=os.path.join(HERE, "bin/sweep"))
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    a = ap.parse_args()

    man = json.load(open(os.path.join(CFG, "manifest.json")))
    base = [os.path.join(CFG, "00-base", b["file"]) for b in man["base"]]
    prov = {p["serial"]: os.path.join(CFG, p["file"]) for p in man["provision"]}
    serv = {s["serial"]: os.path.join(CFG, s["file"]) for s in man["service"]}

    by_tmpl = {}
    for serial, f in prov.items():
        m = re.search(r"<template>([^<]+)</template>", open(f).read())
        by_tmpl.setdefault(m.group(1) if m else "-", []).append(serial)
    rep = []
    for t in sorted(by_tmpl):
        # prefer an ONU that has a service file
        cand = [s for s in by_tmpl[t] if s in serv] or by_tmpl[t]
        rep.append(cand[0])
    print("templates: %d, representative ONUs: %d" % (len(by_tmpl), len(rep)))

    os.makedirs(a.out, exist_ok=True)
    ds = os.path.join(a.out, "dataset.list")
    with open(ds, "w") as f:
        for b in base:
            f.write(b + "\n")
        for s in rep:
            f.write(prov[s] + "\n")
            if s in serv:
                f.write(serv[s] + "\n")
    onu = os.path.join(a.out, "onus.list")
    with open(onu, "w") as f:
        for s in sorted(prov):
            if a.onus == "rep" and s in rep:
                continue
            if s in serv and s not in rep:
                f.write("%s %s\n" % (prov[s], serv[s]))
    csv = os.path.join(a.out, "sweep_verdicts.csv")
    cov = os.path.join(a.out, "sweep_cover.txt")
    cmd = [a.bin, YANG, os.path.join(HERE, "modules.txt"), ds, onu, csv, cov,
           str(a.seed), str(a.per_node), str(a.mixed)]
    print(" ".join(cmd))
    r = subprocess.run(cmd)
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
