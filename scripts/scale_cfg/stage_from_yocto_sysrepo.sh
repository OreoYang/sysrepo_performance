#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/repo_paths.sh
source "${SCRIPT_DIR}/lib/repo_paths.sh"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${BUILDDIR}" ]] || die "build-xpon not found (conf/bblayers.conf). Run: . setup-env from repo root"
[[ -d "${SYSREPO_NATIVE_ROOT}/usr/bin" ]] || die "sysrepo-native missing. Run: bitbake sysrepo"
[[ -d "${LIBYANG_NATIVE_ROOT}/usr" ]] || die "libyang-native missing. Run: bitbake sysrepo"

echo "Staging sysrepo-native + libyang-native -> ${RUNTIME_DIR}"
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}"

cp -a "${SYSREPO_NATIVE_ROOT}/usr/." "${RUNTIME_DIR}/usr/"
# Merge libyang (libs, plugins, headers) without clobbering sysrepo bins
if command -v rsync >/dev/null 2>&1; then
    rsync -a "${LIBYANG_NATIVE_ROOT}/usr/" "${RUNTIME_DIR}/usr/"
else
    cp -a "${LIBYANG_NATIVE_ROOT}/usr/lib/." "${RUNTIME_DIR}/usr/lib/" 2>/dev/null || true
    cp -a "${LIBYANG_NATIVE_ROOT}/usr/share/." "${RUNTIME_DIR}/usr/share/" 2>/dev/null || true
fi
# sysrepo-native may omit libyang headers; needed to compile sr_edit_files against this runtime.
if [[ -d "${LIBYANG_NATIVE_ROOT}/usr/include/libyang" ]]; then
    mkdir -p "${RUNTIME_DIR}/usr/include"
    cp -a "${LIBYANG_NATIVE_ROOT}/usr/include/." "${RUNTIME_DIR}/usr/include/"
fi

[[ -x "${RUNTIME_DIR}/usr/bin/sysrepocfg" ]] || die "sysrepocfg not staged"
[[ -f "${RUNTIME_DIR}/usr/lib/libyang.so" || -f "${RUNTIME_DIR}/usr/lib/libyang.so.3" ]] || die "libyang not staged"

if [[ ! -d "${YANG_ROOT}/exs1610" ]]; then
    echo "warning: YANG tree not found at ${YANG_ROOT}" >&2
    echo "         bitbake xpon-yang or check workspace externalsrc" >&2
fi

mkdir -p "${LOCAL_BIN_DIR}"
# Yocto pyang uses #!/usr/bin/env nativepython3 — stub vecima OD-360 lint for host harness.
# sysrepoctl -i still validates modules via libyang on install.
cat > "${LOCAL_BIN_DIR}/pyang" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${LOCAL_BIN_DIR}/pyang"

echo "Staged runtime OK:"
echo "  sysrepocfg: ${RUNTIME_DIR}/usr/bin/sysrepocfg"
"${RUNTIME_DIR}/usr/bin/sysrepocfg" --version | head -1
