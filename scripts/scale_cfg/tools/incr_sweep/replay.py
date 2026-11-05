#!/usr/bin/env python3
"""Replay sampled sweep edits through the two sysrepo builds (full and incremental validation).

Each edit file written by sweep (SWEEP_EMIT_DIR) is applied with "sysrepocfg --edit" to a private copy of one
repository that holds the starting dataset, once per build. The verdicts of the two builds, the verdict of the
libyang sweep and the resulting running datastores are compared. A case where the builds disagree is a miss
(full rejects, incremental accepts) or an over-reject.

usage: replay.py --repo BASE_REPO --edits DIR [--sr-tree DIR] [--ly-tree DIR] [--jobs N] [--limit N] [--csv FILE]
"""
import argparse
import concurrent.futures as cf
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

SR = "/home/oreo/works/private/sysrepo-3.7.11"
LY = "/home/oreo/works/private/libyang-3.9.13"


def env_for(args, install, repo, shm):
    env = dict(os.environ)
    env["SYSREPO_REPOSITORY_PATH"] = repo
    env["SYSREPO_SHM_DIR"] = shm
    env["LD_LIBRARY_PATH"] = os.path.join(args.sr_tree, install, "lib") + ":" + os.path.join(args.ly_tree, "install/lib")
    env.pop("SR_VALIDATE_INCREMENTAL", None)
    return env


def run_arm(args, work, idx, edit, install):
    repo = os.path.join(work, "repo_%s_%s" % (idx, install))
    shm = os.path.join(work, "shm_%s_%s" % (idx, install))
    shutil.copytree(args.repo, repo, symlinks=True)
    os.makedirs(shm)
    cfg = os.path.join(args.sr_tree, install, "bin/sysrepocfg")
    env = env_for(args, install, repo, shm)
    p = subprocess.run([cfg, "--edit=" + edit, "-d", "running", "-f", "xml"], env=env, capture_output=True, text=True)
    out = p.stdout + p.stderr
    digest = ""
    if p.returncode == 0:
        q = subprocess.run([cfg, "-X", "-d", "running", "-f", "xml"], env=env, capture_output=True, text=True)
        digest = hashlib.md5(q.stdout.encode()).hexdigest()
    msg = ""
    m = re.search(r"(Must condition|When condition|Invalid leafref|Unique data|Mandatory|Too (?:few|many)|Invalid|"
                  r"Failed|Node)[^\n]*", out)
    if m:
        msg = m.group(0)[:200]
    shutil.rmtree(repo, ignore_errors=True)
    shutil.rmtree(shm, ignore_errors=True)
    return p.returncode, msg, digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--edits", required=True)
    ap.add_argument("--sr-tree", default=SR)
    ap.add_argument("--ly-tree", default=LY)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--csv", default="")
    args = ap.parse_args()

    cases = []
    for line in open(os.path.join(args.edits, "index.csv")):
        i, cls, rc = line.strip().split(",")
        cases.append((i, cls, int(rc), os.path.join(args.edits, "e%06d.xml" % int(i))))
    if args.limit:
        cases = cases[:args.limit]
    work = tempfile.mkdtemp(prefix="replay_", dir=os.path.dirname(os.path.abspath(args.repo)))
    stats = {"both_accept": 0, "both_reject": 0, "miss": 0, "over_reject": 0, "tree_diff": 0, "ly_disagree": 0}
    rows = []

    def job(c):
        i, cls, ly_rc, edit = c
        return c, run_arm(args, work, i, edit, "install-off"), run_arm(args, work, i, edit, "install-on")

    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for (i, cls, ly_rc, edit), full, incr in ex.map(job, cases):
            f_ok, i_ok = full[0] == 0, incr[0] == 0
            if f_ok and i_ok:
                kind = "both_accept"
                if full[2] != incr[2]:
                    kind = "tree_diff"
            elif not f_ok and not i_ok:
                kind = "both_reject"
            elif not f_ok and i_ok:
                kind = "miss"
            else:
                kind = "over_reject"
            stats[kind] += 1
            if f_ok != (ly_rc == 0):
                stats["ly_disagree"] += 1
                print("sysrepo full vs libyang sweep differ: edit %s rc %d vs %d | %s" % (i, full[0], ly_rc, full[1]))
            rows.append((kind, i, cls, str(full[0]), str(incr[0]), full[1], incr[1]))
            if kind in ("miss", "over_reject", "tree_diff"):
                print("%s: edit %s (%s) | full: %s | incr: %s" % (kind.upper(), i, cls, full[1], incr[1]))
    print("cases=%d %s" % (len(cases), stats))
    if args.csv:
        with open(args.csv, "w") as f:
            f.write("kind,edit,class,rc_full_build,rc_incr_build,full_msg,incr_msg\n")
            for r in rows:
                f.write(",".join('"%s"' % x.replace('"', "'") for x in r) + "\n")
    shutil.rmtree(work, ignore_errors=True)
    return 1 if stats["miss"] or stats["over_reject"] or stats["tree_diff"] else 0


if __name__ == "__main__":
    sys.exit(main())
