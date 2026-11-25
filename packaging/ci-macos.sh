#!/bin/sh
# What the release workflow's macOS job runs (.github/workflows/release.yml), on an Apple
# silicon runner; it can be run by hand on a Mac too:
#
#   ZIG_VERSION=... ZIG_MACOS_SHA256=... packaging/ci-macos.sh
#
# Needs nothing from Homebrew (text is Core Text's). Downloads Zig and
# checks it against the sha256 given, then builds and tests as docs/install.md's macOS
# section says: `zig build test` (the core's tests and the GUI's; no window is opened and
# nothing is played; the drawing tests need a Metal device and skip without one),
# `zig build --release=safe`, `dimna --help`, and `dimna-headless --sim` recording for 5 s.
# No board is touched: there is none. Nothing is packaged: Mac users build from source.
set -eu

: "${ZIG_VERSION:?}" "${ZIG_MACOS_SHA256:?}"

fail() {
    echo "ci-macos: $*" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail "this is for macOS"
[ "$(uname -m)" = arm64 ] || fail "dimna on macOS is for Apple silicon; this machine is $(uname -m)"

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dimna-ci-macos-XXXXXX")
cleanup() {
    case "$work" in
    */dimna-ci-macos-*) rm -rf "$work" ;;
    esac
}
trap cleanup EXIT

zig_tar=zig-aarch64-macos-$ZIG_VERSION.tar.xz
# ziglang.org first, then community mirrors (https://ziglang.org/download/community-mirrors.txt):
# from GitHub's macOS runner the download from ziglang.org hung for 19 minutes without a
# byte (2026-11-24), so every try has a time limit. Whatever serves the file, it is
# checked against the sha256 the workflow gives.
got=
for base in "https://ziglang.org/download/$ZIG_VERSION" "https://pkg.machengine.org/zig" "https://zigmirror.hryx.net/zig" "https://zig.linus.dev/zig"; do
    echo "ci-macos: fetching $base/$zig_tar"
    if curl -fsSL --connect-timeout 20 --max-time 180 -o "$work/$zig_tar" "$base/$zig_tar" &&
        (cd "$work" && echo "$ZIG_MACOS_SHA256  $zig_tar" | shasum -a 256 -c -); then
        got=1
        break
    fi
    rm -f "$work/$zig_tar"
done
[ -n "$got" ] || fail "could not download $zig_tar with the right checksum from ziglang.org or a mirror"
tar -xJf "$work/$zig_tar" -C "$work"
PATH=$work/zig-aarch64-macos-$ZIG_VERSION:$PATH
zig version
sw_vers

cd "$root"
zig fmt --check src build.zig
zig build test --summary all
zig build --release=safe

zig-out/bin/dimna --help >/dev/null 2>&1 || fail "dimna --help failed"

rec=$work/rec
mkdir "$rec"
zig-out/bin/dimna-headless --sim 32,16 --seconds 5 --record "$rec" >"$work/headless.log" 2>&1 || {
    cat "$work/headless.log"
    fail "dimna-headless --sim failed"
}
grep -E '^summary|^CLEAN' "$work/headless.log"
grep -q '^CLEAN' "$work/headless.log" || fail "the simulator run was not CLEAN"
grep -q 'dropped=0 gaps=0 bad=0' "$work/headless.log" || fail "the simulator run lost samples"

# The reference reader checks every chunk, where there is a Python that can run it.
session=$(find "$rec" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$session" ] || fail "no recording was written"
if python3 -c 'import sys, numpy; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    python3 tools/dimna_read.py "$session" | tail -n 3
else
    echo "ci-macos: no Python 3.11+ with numpy; the recording was not read back"
fi
echo "PASS: macOS"
