#!/bin/bash
# Recompute the coverage matrix: unit-test evidence against the production schemas.
# usage: coverage.sh [extra matrix.py args, e.g. --extra-evidence out/sweep_cover.txt]
set -e
cd "$(dirname "$0")"
LY=${LY_TREE:-/home/oreo/works/private/libyang-3.9.13}
W=${PROD_WORK:-/home/oreo/works/private/sysrepo_performance/scripts/scale_cfg/work_voip}
mkdir -p out/ty
./build.sh >/dev/null
./bin/inv $W/db_1230_voip/upper/sysrepo/yang modules.txt out/rules.csv out/struct.csv 2>/dev/null
python3 extract_test_schemas.py $LY/tests/utests/data/test_validation_incr.c out/ty
./bin/inv out/ty out/ty/modules.txt out/ty/rules.csv out/ty/struct.csv 2>/dev/null
(cd $LY/build && make utest_validation_incr -j8 >/dev/null && DL_COVER=1 ./tests/utest_validation_incr > $OLDPWD/out/unit_cover.txt 2>&1) || true
tail -3 out/unit_cover.txt
python3 matrix.py --prod out --test out/ty --evidence out/unit_cover.txt --out out "$@"
