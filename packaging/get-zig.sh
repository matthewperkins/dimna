#!/bin/sh
# Downloads the Zig that build.zig.zon asks for (minimum_zig_version) from ziglang.org,
# checks its minisign signature against Zig's public key, and unpacks it into
# ~/.local/opt/zig-<arch>-linux-<version>/. No root; several versions can sit side by side.
#
#   packaging/get-zig.sh            then: export PATH=~/.local/opt/zig-...:$PATH
#
# Needs curl (or wget), tar with xz, and minisign (packaged as minisign by Debian, Ubuntu,
# Fedora, Arch and Void; EPEL on Rocky/RHEL). Nothing is unpacked unless the signature is
# good AND its trusted comment names the file that was asked for (so an older, also signed,
# tarball cannot be passed off as this one).
set -eu

# Zig's release-signing public key, as published on https://ziglang.org/download/
# ("minisign ... public key"), copied 2026-11-14.
zig_pubkey=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

fail() {
    echo "get-zig: $*" >&2
    exit 1
}

root=$(cd "$(dirname "$0")/.." && pwd -P)
version=$(sed -n 's/^[[:space:]]*\.minimum_zig_version = "\([^"]*\)",[[:space:]]*$/\1/p' "$root/build.zig.zon")
case "$version" in
'' | *[!0-9.]* | .* | *. | *..*) fail "could not read a release version (like 0.17.1) from build.zig.zon's minimum_zig_version: '$version'" ;;
esac

case "$(uname -m)" in
x86_64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*) fail "no Zig release for this machine's architecture ($(uname -m)) is handled here" ;;
esac
name=zig-$arch-linux-$version
tarball=$name.tar.xz
url=https://ziglang.org/download/$version/$tarball
dest_parent=$HOME/.local/opt
dest=$dest_parent/$name

if [ -x "$dest/zig" ]; then
    echo "get-zig: $dest/zig is already there ($("$dest/zig" version))"
    echo "  export PATH=$dest:\$PATH"
    exit 0
fi

command -v minisign >/dev/null 2>&1 ||
    fail "minisign is needed to check the download's signature: install the minisign package"
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -O "$2" "$1"; }
else
    fail "neither curl nor wget is installed"
fi

# Downloaded and unpacked beside the destination, so the last step is a rename: an
# interrupted run never leaves a half-unpacked Zig where the check above would accept it.
mkdir -p "$dest_parent"
work=$(mktemp -d "$dest_parent/.get-zig-XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM

echo "get-zig: downloading $url"
fetch "$url" "$work/$tarball"
fetch "$url.minisig" "$work/$tarball.minisig"

# minisign -V checks the file's signature and the signature over the trusted comment, so
# once it succeeds the .minisig's "trusted comment:" line is authentic. Zig's reads
# "timestamp:<n><TAB>file:<name><TAB>hashed".
minisign -V -P "$zig_pubkey" -m "$work/$tarball" -x "$work/$tarball.minisig" ||
    fail "the signature of $tarball does not verify against Zig's public key; nothing was unpacked"
comment=$(sed -n 's/^trusted comment: //p' "$work/$tarball.minisig" | tr '\t' ' ')
case " $comment " in
*" file:$tarball "*) ;;
*) fail "the signature is good but its trusted comment does not name $tarball ('$comment'); nothing was unpacked" ;;
esac

tar -xJf "$work/$tarball" -C "$work"
[ -x "$work/$name/zig" ] || fail "the tarball has no $name/zig"
mv "$work/$name" "$dest"
echo "get-zig: Zig $("$dest/zig" version) is in $dest"
echo "  export PATH=$dest:\$PATH"
