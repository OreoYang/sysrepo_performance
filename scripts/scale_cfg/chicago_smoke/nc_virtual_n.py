#!/usr/bin/env python3
"""Serial virtual provision on Chicago over ONE persistent NETCONF session.

Same ONU sequence as olt/run_virtual_n.sh (AA/BB serials, ports 1-16, mix XGS/GPON), but every edit is an
edit-config on a single SSH/NETCONF connection to netopeer2-server, so the sysrepo connection (and its
incremental-validation state) is reused. run_virtual_n.sh starts a new sysrepocfg process per edit, which pays
the per-connection full validation baseline on every edit.

Needs an SSH tunnel to the OLT loopback port 830:
    ssh -N -L 8830:127.0.0.1:830 root@<olt>
"""
import argparse
import os
import select
import subprocess
import sys
import tempfile
import time

EOM = b"]]>]]>"
HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "olt", "gen_provision.sh")


def read_msg(fd, timeout):
    buf = b""
    end = time.time() + timeout
    while EOM not in buf:
        left = end - time.time()
        if left <= 0:
            raise TimeoutError("no reply within %ss" % timeout)
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            continue
        chunk = os.read(fd, 1 << 20)
        if not chunk:
            raise EOFError("session closed")
        buf += chunk
    return buf.split(EOM, 1)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=1022)
    ap.add_argument("--start", type=int, default=1)
    ap.add_argument("--port", type=int, default=8830)
    ap.add_argument("--csv", required=True)
    ap.add_argument("--template", default="default-onu-template")
    ap.add_argument("--timeout", type=int, default=300)
    a = ap.parse_args()

    cmd = ["sshpass", "-p", "", "ssh", "-p", str(a.port), "-s",
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PubkeyAuthentication=no",
           "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
           "root@127.0.0.1", "netconf"]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    fd = p.stdout.fileno()
    hello = (b'<?xml version="1.0" encoding="UTF-8"?><hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">'
             b'<capabilities><capability>urn:ietf:params:netconf:base:1.0</capability></capabilities></hello>')
    p.stdin.write(hello + EOM)
    p.stdin.flush()
    read_msg(fd, 30)

    tmp = tempfile.mkdtemp()
    xml = os.path.join(tmp, "one.xml")
    new = not os.path.exists(a.csv) or a.start <= 1
    out = open(a.csv, "w" if new else "a")
    if new:
        out.write("timestamp,idx,serial,tech,pon,rc,ms\n")
    ok = fail = 0
    t0 = time.time()
    for i in range(a.start, a.n + 1):
        pon = (i - 1) % 16 + 1
        if i % 2 == 0:
            tech, serial = "xgs", "AA%010X" % i
        else:
            tech, serial = "gpon", "BB%010X" % i
        subprocess.run([GEN, serial, str(pon), a.template, xml], check=True, stdout=subprocess.DEVNULL,
                       env=dict(os.environ, PON_TECH=tech))
        body = open(xml).read()
        rpc = ('<?xml version="1.0" encoding="UTF-8"?><rpc message-id="%d" '
               'xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"><edit-config><target><running/></target>'
               '<config>%s</config></edit-config></rpc>' % (i, body)).encode()
        s = time.time()
        p.stdin.write(rpc + EOM)
        p.stdin.flush()
        rep = read_msg(fd, a.timeout)
        ms = int((time.time() - s) * 1000)
        rc = 0 if b"<ok/>" in rep else 1
        if rc:
            fail += 1
            print("FAIL idx=%d %s: %s" % (i, serial, rep[:400].decode(errors="replace")), flush=True)
        else:
            ok += 1
        out.write("%s,%d,%s,%s,%d,%d,%d\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), i, serial, tech, pon, rc, ms))
        out.flush()
        if i % 25 == 0 or i == a.start or i == a.n:
            print("[progress] %d/%d ok=%d fail=%d last_ms=%d elapsed=%ds" % (i, a.n, ok, fail, ms, time.time() - t0),
                  flush=True)
        if rc and i == a.start:
            print("FIRST edit failed - stop", flush=True)
            break
    print("DONE N=%d START=%d ok=%d fail=%d wall=%ds" % (a.n, a.start, ok, fail, time.time() - t0), flush=True)
    try:
        p.stdin.write(b'<rpc message-id="close" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"><close-session/></rpc>'
                      + EOM)
        p.stdin.flush()
    except Exception:
        pass
    p.terminate()


if __name__ == "__main__":
    main()
