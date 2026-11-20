#!/usr/bin/env bash
# Build sr_validate_ds.c against the sysrepo/libyang headers of the target image (x86_64 Yocto image or host).
# The binary links the image's own libsysrepo.so.7 / libyang at run time, so nothing else has to be installed there.
#
# usage: build_sr_validate_ds.sh <runtime_dir_with_usr/include+usr/lib> [out] [dynamic-linker]
#   Yocto image: dynamic linker is /lib/ld-linux-x86-64.so.2 (the host default /lib64/... does not exist there)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="$(readlink -f "${1:?usage: build_sr_validate_ds.sh <runtime_dir> [out] [dynamic-linker]}")"
OUT="${2:-${HERE}/sr_validate_ds}"
LD="${3:-/lib/ld-linux-x86-64.so.2}"

gcc -O2 -Wall -o "${OUT}" "${HERE}/sr_validate_ds.c" -I"${RT}/usr/include" -L"${RT}/usr/lib" -lsysrepo -lyang \
    -Wl,--dynamic-linker="${LD}"
echo "built ${OUT} (interpreter ${LD}); needs GLIBC <= $(objdump -T "${OUT}" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
