#!/usr/bin/env python3
"""Differential check on real XPON data: flip the type of every interface to every other type.

Each case is applied to a private copy of one populated repository, once with full validation and once
with incremental validation. A case where the two disagree (full rejects, incremental accepts, or the
reverse) is a validation miss. Cases are independent, so they run in parallel.

The validator is chosen when sysrepo is built (-DENABLE_VALIDATE_INCREMENTAL=ON|OFF), so the two arms use two
staged runtimes: --runtime is the incremental build, --runtime-full the full one. A runtime built before that
switch (it reads SR_VALIDATE_INCREMENTAL) can serve both arms, omit --runtime-full then.

usage: flip_diff_check.py --runtime DIR [--runtime-full DIR] --repo POPULATED_REPO [--jobs N] [--limit N]
"""
import argparse
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
import tempfile

TYPES = {
    "ethernetCsmacd": ("ianaift", "urn:ietf:params:xml:ns:yang:iana-if-type"),
    "ieee8023adLag": ("ianaift", "urn:ietf:params:xml:ns:yang:iana-if-type"),
    "vlan-sub-interface": ("bbfift", "urn:bbf:yang:bbf-if-type"),
    "l2-termination": ("bbfift", "urn:bbf:yang:bbf-if-type"),
    "channel-group": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
    "channel-partition": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
    "channel-pair": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
    "channel-termination": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
    "ani": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
    "v-ani": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
    "onu-v-enet": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
    "olt-v-enet": ("bbf-xponift", "urn:bbf:yang:bbf-xpon-if-type"),
}


def build_kind(runtime):
    """incr, full, legacy (reads SR_VALIDATE_INCREMENTAL) or unknown, from the text compiled into libsysrepo."""
    so = os.path.realpath(os.path.join(runtime, "usr/lib/libsysrepo.so"))
    try:
        with open(so, "rb") as f:
            data = f.read()
    except OSError:
        return "unknown"
    if b"not compiled in (ENABLE_VALIDATE_INCREMENTAL=OFF)" in data:
        return "full"
    if b"compiled in (ENABLE_VALIDATE_INCREMENTAL=ON)" in data:
        return "incr"
    if b"SR_VALIDATE_INCREMENTAL" in data:
        return "legacy"
    return "unknown"


def runtime_for(args, incremental):
    """Runtime of an arm, refusing one that would silently run the other validator."""
    runtime = args.runtime if incremental or not args.runtime_full else args.runtime_full
    kind = build_kind(runtime)
    want = "incr" if incremental else "full"
    if kind not in (want, "legacy"):
        sys.exit("error: runtime %s is a '%s' build, the %s arm needs '%s' (use --runtime-full)"
                 % (runtime, kind, want, want))
    return runtime


def env_for(runtime, repo, shm, incremental):
    env = dict(os.environ)
    env["SYSREPO_REPOSITORY_PATH"] = repo
    env["SYSREPO_SHM_DIR"] = shm
    env["LD_LIBRARY_PATH"] = os.path.join(runtime, "usr/lib") + ":" + env.get("LD_LIBRARY_PATH", "")
    if os.path.isdir(os.path.join(runtime, "usr/lib/libyang/extensions")):
        env["LIBYANG_EXTENSIONS_PLUGINS_DIR"] = os.path.join(runtime, "usr/lib/libyang/extensions")
    env.pop("SR_VALIDATE_INCREMENTAL", None)
    if incremental:
        env["SR_VALIDATE_INCREMENTAL"] = "1"
    return env


def run_case(args, work, name, typ, incremental, idx):
    pfx, ns = TYPES[typ]
    repo = os.path.join(work, "repo_%d_%d" % (idx, incremental))
    shm = os.path.join(work, "shm_%d_%d" % (idx, incremental))
    shutil.copytree(args.repo, repo, symlinks=True)
    os.makedirs(shm)
    xml = os.path.join(work, "edit_%d_%d.xml" % (idx, incremental))
    with open(xml, "w") as f:
        f.write('<interfaces xmlns="urn:ietf:params:xml:ns:yang:ietf-interfaces"><interface><name>%s</name>'
                '<type xmlns:%s="%s">%s:%s</type></interface></interfaces>' % (name, pfx, ns, pfx, typ))
    runtime = runtime_for(args, incremental)
    sysrepocfg = os.path.join(runtime, "usr/bin/sysrepocfg")
    p = subprocess.run([sysrepocfg, "--edit=" + xml, "-d", "running", "-f", "xml"],
                       env=env_for(runtime, repo, shm, incremental), capture_output=True, text=True)
    shutil.rmtree(repo, ignore_errors=True)
    shutil.rmtree(shm, ignore_errors=True)
    os.unlink(xml)
    msg = ""
    m = re.search(r"(Must condition|When condition|Invalid leafref|Unique data|Mandatory|Invalid.*?)[^\n]*",
                  p.stdout + p.stderr)
    if m:
        msg = m.group(0)[:200]
    return p.returncode, msg


def interface_names(args, work):
    shm = os.path.join(work, "shm_names")
    os.makedirs(shm)
    runtime = runtime_for(args, False)
    p = subprocess.run([os.path.join(runtime, "usr/bin/sysrepocfg"), "-X", "-d", "running", "-m",
                        "ietf-interfaces", "-f", "xml"],
                       env=env_for(runtime, args.repo, shm, False), capture_output=True, text=True)
    return re.findall(r"<interface>\s*<name>([^<]+)</name>", p.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", required=True, help="staged runtime of the incremental build")
    ap.add_argument("--runtime-full", default="", help="staged runtime of the full-validation build")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--csv", default="")
    args = ap.parse_args()
    for incremental in (0, 1):  # fail now, not inside a worker thread
        print("%s arm: %s" % ("incr" if incremental else "full", runtime_for(args, incremental)), file=sys.stderr)

    work = tempfile.mkdtemp(prefix="flipdiff_", dir=os.path.dirname(os.path.abspath(args.repo)))
    names = interface_names(args, work)
    print("interfaces:", len(names), file=sys.stderr)
    cases = [(n, t) for n in names for t in TYPES]
    if args.limit:
        cases = cases[:args.limit]
    stats = {"both_reject": 0, "both_accept": 0, "miss": 0, "over_reject": 0}
    rows = []

    def job(item):
        idx, (name, typ) = item
        full = run_case(args, work, name, typ, 0, idx)
        incr = run_case(args, work, name, typ, 1, idx)
        return name, typ, full, incr

    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, typ, full, incr in ex.map(job, enumerate(cases)):
            f_ok, i_ok = full[0] == 0, incr[0] == 0
            if f_ok and i_ok:
                kind = "both_accept"
            elif not f_ok and not i_ok:
                kind = "both_reject"
            elif not f_ok and i_ok:
                kind = "miss"
            else:
                kind = "over_reject"
            stats[kind] += 1
            rows.append((kind, name, typ, full[1], incr[1]))
            if kind in ("miss", "over_reject"):
                print("%s: %s -> %s | full: %s | incr: %s" % (kind.upper(), name, typ, full[1], incr[1]))
    print("cases=%d %s" % (len(cases), stats))
    if args.csv:
        with open(args.csv, "w") as f:
            f.write("kind,interface,new_type,full_msg,incr_msg\n")
            for r in rows:
                f.write(",".join('"%s"' % x.replace('"', "'") for x in r) + "\n")
    shutil.rmtree(work, ignore_errors=True)
    return 1 if stats["miss"] or stats["over_reject"] else 0


if __name__ == "__main__":
    sys.exit(main())
