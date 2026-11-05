#!/bin/bash
# Build the inventory and sweep tools against the private libyang 3.9.x tree.
# validation_deps.c is compiled into inv (libyang hides its internals), everything else links libyang.so.
set -e
L=${LY_TREE:-/home/oreo/works/private/libyang-3.9.13}
INC="-I$L/install/include -I$L/src -I$L/build-rel -I$L/build-rel/libyang -I$(dirname $(find $L -name compat.h -not -path '*/install/*' | head -1))"
LIB="-L$L/install/lib -lyang -Wl,-rpath,$L/install/lib"
cd "$(dirname "$0")"
mkdir -p bin
gcc -O1 -g -Wall -o bin/inv inv.c $L/src/validation_deps.c $INC $LIB
[ -f shallow.c ] && gcc -O1 -g -Wall -o bin/shallow shallow.c $L/src/validation_deps.c $INC $LIB
[ -f sweep.c ] && gcc -O1 -g -Wall -o bin/sweep.tmp sweep.c $INC $LIB && mv -f bin/sweep.tmp bin/sweep
SR=${SR_TREE:-/home/oreo/works/private/sysrepo-3.7.11}
gcc -O1 -g -Wall -o bin/sr_setup sr_setup.c -I$L/install/include -I$SR/install-on/include -L$SR/install-on/lib -lsysrepo -L$L/install/lib -lyang -Wl,-rpath,$SR/install-on/lib -Wl,-rpath,$L/install/lib
echo built
