#!/bin/sh
# The release workflow's build job (.github/workflows/release.yml), as root in a Rocky
# Linux 9 container, so the release is compiled against the oldest supported distribution's
# own headers and libraries. From the checkout's top folder:
#
#   ZIG_VERSION=... ZIG_SHA256=... NFPM_VERSION=... NFPM_SHA256=... packaging/ci-build.sh OUT_DIR
#
# Installs the development packages, downloads Zig and nfpm and checks each against the
# sha256 the workflow gives, runs `zig build test` and `zig build release` (whose
# check-release.sh must pass), then writes the .deb and .rpm (make-packages.sh) and copies
# both tarballs into OUT_DIR. Not for a workstation: it installs packages system-wide.
set -eu
: "${ZIG_VERSION:?}" "${ZIG_SHA256:?}" "${NFPM_VERSION:?}" "${NFPM_SHA256:?}"
[ $# -eq 1 ] || {
    echo "usage: $0 OUT_DIR" >&2
    exit 2
}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$1"
out=$(cd "$1" && pwd -P)

# Every -devel package is in Rocky 9's AppStream (checked 2026-11-14), so CRB stays off.
command -v curl >/dev/null 2>&1 || dnf install -y curl-minimal
dnf install -y --setopt=install_weak_deps=False \
    tar gzip xz binutils findutils pkgconf-pkg-config \
    wayland-devel vulkan-loader-devel freetype-devel fontconfig-devel \
    libxkbcommon-devel alsa-lib-devel

tools=$(mktemp -d /tmp/dimna-tools-XXXXXX)
zig_tar=zig-x86_64-linux-$ZIG_VERSION.tar.xz
curl -fsSL --retry 3 -o "$tools/$zig_tar" "https://ziglang.org/download/$ZIG_VERSION/$zig_tar"
(cd "$tools" && echo "$ZIG_SHA256  $zig_tar" | sha256sum -c -)
tar -xJf "$tools/$zig_tar" -C "$tools"
nfpm_tar=nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz
curl -fsSL --retry 3 -o "$tools/$nfpm_tar" "https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION/$nfpm_tar"
(cd "$tools" && echo "$NFPM_SHA256  $nfpm_tar" | sha256sum -c -)
mkdir "$tools/nfpm"
tar -xzf "$tools/$nfpm_tar" -C "$tools/nfpm" nfpm
PATH=$tools/zig-x86_64-linux-$ZIG_VERSION:$tools/nfpm:$PATH
export PATH
zig version
nfpm --version

cd "$repo"
zig build test --summary all
zig build release --summary all
cat zig-out/release/*/CHECK

set -- zig-out/release/dimna-*-x86_64-linux-gnu
[ $# -eq 1 ] && [ -d "$1" ] || {
    echo "expected one unpacked glibc release in zig-out/release" >&2
    exit 1
}
sh packaging/make-packages.sh "$1" "$out"
cp zig-out/release/dimna-*.tar.gz "$out/"
for rpm in "$out"/*.rpm; do
    rpm -qip "$rpm"
    rpm -qp --requires "$rpm"
    rpm -qp --scripts "$rpm"
    rpm -qplv "$rpm"
done
ls -l "$out"
