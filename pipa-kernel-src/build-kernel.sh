#!/bin/bash
# Builds the pmOS-style xiaomi-pipa kernel (vanilla + patch stack) and stages
# it in the layout Fedora's kernel-install (BLS) expects, matching what
# build.sh's `kernel-install add "$kver" "${kernel_path}/vmlinuz"` looks for:
#
#   /usr/lib/modules/<kver>/vmlinuz
#   /usr/lib/modules/<kver>/{kernel/,modules.*,...}   <- normal modules_install output
#   /usr/lib/modules/<kver>/dtb/...                   <- dtbs_install output
#
# Run this on your build machine (needs the aarch64 cross toolchain / clang+lld
# per the APKBUILD's makedepends). Not run in this sandbox -- a full kernel
# build takes far too long here and needs your actual cross toolchain.

set -euo pipefail

PKGVER="7.1.4"
FLAVOR="xiaomi-pipa"
CARCH="arm64"
WORKDIR="$(pwd)/pipa-kernel-build"
STAGEDIR="$WORKDIR/stage"
SRCDIR="$WORKDIR/src"
PATCHDIR="$(pwd)"   # expects the 0001..0016 patches + config-xiaomi-pipa.aarch64 alongside this script

mkdir -p "$WORKDIR" "$STAGEDIR"

echo "==> Fetching linux-$PKGVER"
mkdir -p "$SRCDIR"
cd "$SRCDIR"
if [ ! -f "linux-$PKGVER.tar.xz" ]; then
    curl -LO "https://cdn.kernel.org/pub/linux/kernel/v${PKGVER%%.*}.x/linux-$PKGVER.tar.xz"
fi
rm -rf "linux-$PKGVER"
tar xf "linux-$PKGVER.tar.xz"
cd "linux-$PKGVER"

echo "==> Applying patch stack"
for p in "$PATCHDIR"/000*.patch "$PATCHDIR"/001*.patch; do
    [ -f "$p" ] || continue
    echo "  - $(basename "$p")"
    patch -p1 < "$p"
done

echo "==> Installing config"
cp "$PATCHDIR/config-$FLAVOR.$CARCH" .config
make ARCH="$CARCH" olddefconfig

echo "==> Building (this is the long part)"
unset LDFLAGS
make ARCH="$CARCH" LLVM=1 -j"$(nproc)"

KVER="$(cat include/config/kernel.release)"
echo "==> Kernel release: $KVER"

echo "==> Staging into Fedora/BLS layout"
MODDIR="$STAGEDIR/usr/lib/modules/$KVER"
mkdir -p "$MODDIR"

make modules_install dtbs_install \
    ARCH="$CARCH" LLVM=1 \
    INSTALL_MOD_PATH="$STAGEDIR/usr" \
    INSTALL_MOD_STRIP=1 \
    INSTALL_DTBS_PATH="$MODDIR/dtb"

# kernel-install (BLS) looks for vmlinuz directly under /usr/lib/modules/<kver>/
cp arch/arm64/boot/Image.gz "$MODDIR/vmlinuz" 2>/dev/null || \
cp arch/arm64/boot/Image    "$MODDIR/vmlinuz"

rm -f "$MODDIR"/build "$MODDIR"/source

echo "==> Done. Staged tree: $STAGEDIR"
echo "    Kernel release: $KVER"
echo "    Next: rpmbuild against this stage dir with the .spec, or"
echo "    rsync $STAGEDIR/usr/lib/modules/$KVER onto the mounted image and"
echo "    run kernel-install add $KVER $MODDIR/vmlinuz --verbose"
