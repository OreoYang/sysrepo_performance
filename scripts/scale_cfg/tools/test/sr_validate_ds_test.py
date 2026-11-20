#!/usr/bin/env python3
# Copyright Vecima Networks Inc. as an unpublished work.
# All Rights Reserved.
#
# The information contained herein is confidential property of
# Vecima Networks Inc. The use, copying, transfer or disclosure of
# such information is prohibited except by express written agreement
# with Vecima Networks Inc.

"""Unit test of sr_validate_ds. Exit 0 if every case passes, 77 (skipped) if sysrepoctl or sysrepocfg is missing.

usage: sr_validate_ds_test.py BINARY FIXTURE_DIR [unittest options]
env:   SYSREPOCTL, SYSREPOCFG  full paths of the sysrepo tools (default: from PATH)

Every case builds its own small sysrepo database in a temp directory: it installs fixtures/vds-test.yang (a leafref
and a must) and stores fixtures/good.xml in running and startup. Nothing outside the temp directory is touched.
Bad stored data is written straight into the datastore files, because sysrepo refuses to store it through its own
API, which is exactly how bad data gets in without validation.
"""

import glob
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

BIN = None
FIX = None
SYSREPOCTL = os.environ.get("SYSREPOCTL") or shutil.which("sysrepoctl")
SYSREPOCFG = os.environ.get("SYSREPOCFG") or shutil.which("sysrepocfg")


class SrValidateDs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = dict(os.environ)
        self.env["SYSREPO_REPOSITORY_PATH"] = os.path.join(self.tmp, "repo")
        self.env["SYSREPO_SHM_DIR"] = os.path.join(self.tmp, "shm")

    # ---- helpers -------------------------------------------------------------------------------------------

    def run_cmd(self, *cmd):
        p = subprocess.run(cmd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        return p.returncode, p.stdout

    def tool(self, *args):
        return self.run_cmd(BIN, *args)

    def new_db(self, connect=False):
        """Fresh database: schema installed, good.xml in running and startup. connect=True opens a connection
        once, so the shared memory running file exists, as on a running OLT."""
        for d in (self.env["SYSREPO_REPOSITORY_PATH"], self.env["SYSREPO_SHM_DIR"]):
            shutil.rmtree(d, True)
            os.makedirs(d)
        good = os.path.join(FIX, "good.xml")
        steps = [
            [SYSREPOCTL, "-i", os.path.join(FIX, "vds-test.yang")],
            [SYSREPOCFG, "-I" + good, "-d", "startup", "-m", "vds-test", "-f", "xml"],
            [SYSREPOCFG, "-I" + good, "-d", "running", "-m", "vds-test", "-f", "xml"],
        ]
        for cmd in steps:
            rc, out = self.run_cmd(*cmd)
            self.assertEqual(rc, 0, "could not build the test database: %s\n%s" % (cmd, out))
        if connect:
            self.tool()

    def running_file(self):
        return glob.glob(os.path.join(self.env["SYSREPO_SHM_DIR"], "*vds-test.running"))[0]

    def startup_file(self):
        return os.path.join(self.env["SYSREPO_REPOSITORY_PATH"], "data", "vds-test.startup")

    @staticmethod
    def corrupt(path):
        """Data in a datastore file that breaks the leafref and the must of y."""
        with open(path) as f:
            data = f.read()
        new = data.replace('"peer": "x"', '"peer":"no-such-item"').replace('"peer":"x"', '"peer":"no-such-item"')
        assert new != data, "nothing to corrupt in " + path
        with open(path, "w") as f:
            f.write(new)

    @staticmethod
    def md5(*paths):
        out = []
        for p in paths:
            with open(p, "rb") as f:
                out.append(hashlib.md5(f.read()).hexdigest())
        return out

    def check(self, expect, args, contains=None):
        rc, out = self.tool(*args)
        self.assertEqual(rc, expect, "expected exit %d, got %d\n%s" % (expect, rc, out))
        if contains is not None:
            self.assertIn(contains, out)

    def fx(self, name):
        return os.path.join(FIX, name)

    # ---- command line, no database needed ------------------------------------------------------------------

    def test_cli_bad_d(self):
        self.check(2, ["-d", "nonsense"])

    def test_cli_e_with_f(self):
        self.check(2, ["-e", self.fx("edit_good.xml"), "-f", self.fx("good.xml")])

    # ---- stored data ---------------------------------------------------------------------------------------

    def test_stored_good_both(self):
        self.new_db()
        self.check(0, ["-d", "both"], "VALID    running")

    def test_stored_bad_startup_only(self):
        self.new_db(connect=True)
        self.corrupt(self.startup_file())
        self.check(1, ["-d", "startup"], "INVALID  startup")
        self.check(0, ["-d", "running"], "VALID    running")

    def test_stored_bad_running_only(self):
        self.new_db(connect=True)
        self.corrupt(self.running_file())
        self.check(1, ["-d", "running"], "INVALID  running")
        self.check(0, ["-d", "startup"], "VALID    startup")
        self.check(1, ["-d", "both"])

    # ---- -e edit dry run -----------------------------------------------------------------------------------

    def test_edit_good(self):
        self.new_db(connect=True)
        self.check(0, ["-d", "running", "-e", self.fx("edit_good.xml")], "VALID    running")

    def test_edit_bad_leafref(self):
        self.new_db(connect=True)
        self.check(1, ["-d", "running", "-e", self.fx("edit_bad_leafref.xml")], "no-such-item")

    def test_edit_bad_must_on_other_item(self):
        self.new_db(connect=True)
        self.check(1, ["-d", "running", "-e", self.fx("edit_bad_must.xml")], "peer must be an item of kind b")

    def test_edit_unknown_leaf(self):
        self.new_db(connect=True)
        self.check(1, ["-d", "running", "-e", self.fx("edit_bad_schema.xml")], "no-such-leaf")

    def test_edit_missing_file(self):
        self.new_db(connect=True)
        self.check(2, ["-d", "running", "-e", self.fx("does-not-exist.xml")])

    def test_edit_good_startup(self):
        self.new_db(connect=True)
        self.check(0, ["-d", "startup", "-e", self.fx("edit_good.xml")])

    def test_edit_bad_both(self):
        self.new_db(connect=True)
        self.check(1, ["-d", "both", "-e", self.fx("edit_bad_must.xml")])

    def test_edit_leaves_stored_data_unchanged(self):
        self.new_db(connect=True)
        files = (self.running_file(), self.startup_file())
        before = self.md5(*files)
        self.tool("-d", "both", "-e", self.fx("edit_good.xml"))
        self.tool("-d", "both", "-e", self.fx("edit_bad_must.xml"))
        self.assertEqual(before, self.md5(*files), "stored data changed by a dry run")
        self.check(0, ["-d", "both"])

    # ---- -f copy-config source file ------------------------------------------------------------------------

    def test_file_good(self):
        self.new_db()
        self.check(0, ["-f", self.fx("good.xml")], "VALID    file")

    def test_file_broken_must(self):
        self.new_db()
        self.check(1, ["-f", self.fx("copy_bad.xml")], "peer must be an item of kind b")

    def test_file_unknown_leaf(self):
        self.new_db()
        self.check(1, ["-f", self.fx("edit_bad_schema.xml")], "no-such-leaf")

    def test_file_missing(self):
        self.new_db()
        self.check(2, ["-f", self.fx("does-not-exist.xml")])


def main():
    global BIN, FIX
    if len(sys.argv) < 3:
        sys.exit("usage: sr_validate_ds_test.py BINARY FIXTURE_DIR [unittest options]")
    BIN, FIX = sys.argv[1], sys.argv[2]
    if not SYSREPOCTL or not SYSREPOCFG:
        print("SKIP  sysrepoctl or sysrepocfg not found (set SYSREPOCTL and SYSREPOCFG)")
        sys.exit(77)
    unittest.main(argv=[sys.argv[0]] + sys.argv[3:], verbosity=2)


if __name__ == "__main__":
    main()
