#!/bin/sh
# The release workflow's tests (.github/workflows/release.yml). The `run` and `tarball`
# modes need no root and can be run on any machine against an unpacked release:
#
#   ci-test-install.sh run BINDIR [--headless-only]
#       BINDIR/dimna --help (every library loads; ldd -r finds every symbol), then
#       BINDIR/dimna-headless --sim 32,16 for 5 s recording into a temporary folder, and
#       checks that the recording is complete. --headless-only skips dimna.
#   ci-test-install.sh tarball FILE.tar.gz [--headless-only]
#       unpacks a release tarball into a temporary folder and does `run` on its bin/.
#
# Only in a throwaway container, as root (it installs and removes packages):
#
#   ci-test-install.sh package DIR
#       installs the .deb (apt) or .rpm (dnf) found in DIR, with that distribution's own
#       repositories resolving the dependencies; checks the installed files and groups;
#       does `run /usr/bin`; removes the package and checks its files are gone.
#   ci-test-install.sh xbps-libs
#       installs, with xbps (Void), the libraries the GUI needs, for `run` on the musl build.
#
# The recording check: the headless run exits 0 and ends with CLEAN; meta.toml has [final];
# samples.i16, index.bin and the TTL files are exactly as long as [final]'s counts say; no
# gaps; the sample count is 5 s at the sample rate, within 2 %; then, where Python 3.11+
# with numpy is available, tools/dimna_read.py (every chunk's CRC) must print OK.
# DIMNA_REQUIRE_READER=1 makes a missing Python or numpy a failure; DIMNA_PYTHON picks the
# interpreter (default python3); DIMNA_READ the reader (default: BINDIR/../tools, then
# /usr/share/dimna/tools, then the checkout's tools/).
#
# Nothing here touches a board: dimna is run only with --help, dimna-headless only with --sim.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
seconds=5
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dimna-ci-$$-XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
say() { echo "== $*"; }

size() { wc -c <"$1" | tr -d ' '; }
# The same bytes (cksum is POSIX and in every base image; cmp is not).
same() { [ "$(cksum <"$1")" = "$(cksum <"$2")" ]; }

# A top-level value of meta.toml (the top-level keys come before every table).
meta_top() { sed -n "/^\[/q; s/^$2 = //p" "$1"; }
# A value of meta.toml's [final] table (the last table).
meta_final() { sed -n "/^\[final\]\$/,\$ s/^$2 = //p" "$1"; }

check_recording() { # RECDIR (the folder given to --record)
    set -- "$1"/*/
    [ $# = 1 ] && [ -d "$1" ] || fail "expected one session folder in the recording folder, found: $*"
    rec=${1%/}
    for f in meta.toml samples.i16 index.bin ttl_sample.i64 ttl_word.u16 events.tsv; do
        [ -f "$rec/$f" ] || fail "the recording has no $f"
    done
    meta=$rec/meta.toml
    grep -q '^\[final\]$' "$meta" || fail "meta.toml has no [final]: the recording was not closed"
    nch=$(meta_top "$meta" num_channels)
    rate=$(meta_top "$meta" sample_rate)
    rate=${rate%.0}
    samples=$(meta_final "$meta" samples)
    chunks=$(meta_final "$meta" chunks)
    gaps=$(meta_final "$meta" gaps)
    edges=$(meta_final "$meta" ttl_edges)
    bytes=$(meta_final "$meta" bytes)
    for v in "$nch" "$rate" "$samples" "$chunks" "$gaps" "$edges" "$bytes"; do
        case "$v" in
        '' | *[!0-9]*) fail "meta.toml: num_channels, sample_rate or a [final] count is missing or not a whole number ('$v')" ;;
        esac
    done
    [ "$gaps" = 0 ] || fail "[final] gaps = $gaps"
    [ "$(size "$rec/samples.i16")" = "$bytes" ] || fail "samples.i16 is $(size "$rec/samples.i16") bytes, [final] says $bytes"
    [ "$bytes" = $((samples * nch * 2)) ] || fail "[final] bytes $bytes != $samples samples x $nch channels x 2"
    [ "$(size "$rec/index.bin")" = $((chunks * 48)) ] || fail "index.bin is $(size "$rec/index.bin") bytes, $chunks chunks need $((chunks * 48))"
    [ "$(size "$rec/ttl_sample.i64")" = $((edges * 8)) ] || fail "ttl_sample.i64 does not hold $edges edges"
    [ "$(size "$rec/ttl_word.u16")" = $((edges * 2)) ] || fail "ttl_word.u16 does not hold $edges edges"
    expected=$((rate * seconds))
    [ $((samples * 100)) -ge $((expected * 98)) ] && [ $((samples * 100)) -le $((expected * 102)) ] ||
        fail "$samples samples, expected $expected ($seconds s at $rate Hz) within 2 %"
    echo "recording: $nch channels, $samples samples in $chunks chunks, $edges TTL edges; sizes consistent, no gaps"

    reader=${DIMNA_READ:-}
    if [ -z "$reader" ]; then
        for r in "$bindir/../tools/dimna_read.py" /usr/share/dimna/tools/dimna_read.py "$here/../tools/dimna_read.py"; do
            if [ -f "$r" ]; then
                reader=$r
                break
            fi
        done
    fi
    py=${DIMNA_PYTHON:-python3}
    if [ -n "$reader" ] && command -v "$py" >/dev/null 2>&1 && "$py" -c 'import numpy, tomllib' 2>/dev/null; then
        status=0
        "$py" -I "$reader" "$rec" >"$tmp/reader.txt" 2>&1 || status=$?
        cat "$tmp/reader.txt"
        [ "$status" = 0 ] || fail "dimna_read.py found problems (exit status $status)"
        [ "$(tail -n 1 "$tmp/reader.txt")" = "  OK" ] || fail "dimna_read.py did not print OK"
    elif [ "${DIMNA_REQUIRE_READER:-0}" = 1 ]; then
        fail "no reader check: need tools/dimna_read.py and $py 3.11+ with numpy"
    else
        echo "reader check skipped: no tools/dimna_read.py, or no $py 3.11+ with numpy (the sizes were checked above)"
    fi
}

run_checks() { # BINDIR [--headless-only]
    bindir=$(cd "$1" && pwd -P)
    headless_only=false
    [ "${2:-}" = --headless-only ] && headless_only=true
    # Nothing of the caller's configuration or home is read or written.
    export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state" XDG_DATA_HOME="$tmp/data"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME"
    unset WAYLAND_DISPLAY

    if ! $headless_only; then
        say "dimna --help ($bindir/dimna)"
        status=0
        "$bindir/dimna" --help >"$tmp/help.txt" 2>&1 || status=$?
        if [ "$status" != 0 ]; then
            cat "$tmp/help.txt"
            fail "dimna --help exited with status $status"
        fi
        grep -q -- '--sim' "$tmp/help.txt" || {
            cat "$tmp/help.txt"
            fail "dimna --help did not print the options"
        }
        echo "dimna --help: $(wc -l <"$tmp/help.txt" | tr -d ' ') lines, exit status 0"
        if command -v ldd >/dev/null 2>&1; then
            # glibc's ldd -r also resolves every function symbol; musl's ldd has no -r.
            ldd -r "$bindir/dimna" >"$tmp/ldd.txt" 2>&1 || ldd "$bindir/dimna" >"$tmp/ldd.txt" 2>&1 || true
            if grep -E 'not found|undefined symbol|Error' "$tmp/ldd.txt"; then
                fail "ldd: a library or symbol of dimna is missing"
            fi
            echo "ldd: every library and symbol found"
        else
            echo "ldd is not installed: the symbols were not checked"
        fi
    fi

    say "dimna-headless --sim 32,16 --seconds $seconds --record ($bindir/dimna-headless)"
    status=0
    (cd "$tmp" && "$bindir/dimna-headless" --sim 32,16 --seconds "$seconds" --record "$tmp/rec") >"$tmp/headless.txt" 2>&1 || status=$?
    tail -n 4 "$tmp/headless.txt"
    [ "$status" = 0 ] || fail "dimna-headless exited with status $status"
    [ "$(tail -n 1 "$tmp/headless.txt")" = CLEAN ] || fail "dimna-headless did not end with CLEAN"
    check_recording "$tmp/rec"
}

# Files the package installs (packaging/nfpm.yaml), and the packaging/ files they must equal.
packaged_files="
/usr/bin/dimna
/usr/bin/dimna-headless
/usr/lib/udev/rules.d/60-dimna-ft60x.rules=60-dimna-ft60x.rules
/etc/security/limits.d/99-dimna-realtime.conf=99-dimna-realtime.conf
/usr/share/applications/dimna.desktop=dimna.desktop
/usr/libexec/dimna/dimna-desktop-launch=dimna-desktop-launch.sh
/usr/share/dimna/sim-config/dimna/config.toml=sim-config/dimna/config.toml
/usr/share/icons/hicolor/32x32/apps/dimna.png=icon/dimna-32.png
/usr/share/icons/hicolor/48x48/apps/dimna.png=icon/dimna-48.png
/usr/share/icons/hicolor/64x64/apps/dimna.png=icon/dimna-64.png
/usr/share/icons/hicolor/128x128/apps/dimna.png=icon/dimna-128.png
/usr/share/icons/hicolor/256x256/apps/dimna.png=icon/dimna-256.png
/usr/share/icons/hicolor/scalable/apps/dimna.svg=icon/dimna-icon.svg
/usr/share/dimna/tools/dimna_read.py=../tools/dimna_read.py
/usr/share/doc/dimna/README.md=../README.md
/usr/share/doc/dimna/licenses/README
/usr/share/doc/dimna/licenses/dimna.LICENSE
"

check_installed() {
    for entry in $packaged_files; do
        path=${entry%%=*}
        [ -f "$path" ] || fail "$path is not installed"
        if [ "$entry" != "$path" ]; then
            same "$path" "$here/${entry#*=}" || fail "$path differs from packaging/${entry#*=}"
        fi
    done
    for f in /usr/bin/dimna /usr/bin/dimna-headless /usr/libexec/dimna/dimna-desktop-launch; do
        [ -x "$f" ] || fail "$f is not executable"
    done
    for g in dimna realtime; do
        getent group "$g" >/dev/null || fail "the group $g does not exist after the install"
    done
    desktop-file-validate /usr/share/applications/dimna.desktop || fail "desktop-file-validate"
    echo "installed: every file in place and equal to the checkout's; groups dimna and realtime exist"
}

check_removed() {
    for entry in $packaged_files; do
        path=${entry%%=*}
        [ ! -e "$path" ] || fail "$path is still there after the removal"
    done
    for d in /usr/libexec/dimna /usr/share/dimna /usr/share/doc/dimna; do
        [ ! -e "$d" ] || fail "$d is still there after the removal"
    done
    for g in dimna realtime; do
        getent group "$g" >/dev/null || fail "the group $g was deleted on removal (it must be kept)"
    done
    echo "removed: no file left; groups dimna and realtime kept"
}

# What the checks use beyond the base image: desktop-file-validate, and Python 3.11+ with
# numpy for the reader where the distribution has them. Installed after dimna, so none of
# it can have supplied one of dimna's dependencies.
install_test_tools() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends desktop-file-utils
        apt-get install -y --no-install-recommends python3 python3-numpy >/dev/null || true
    else
        dnf install -y desktop-file-utils
        if dnf install -y python3.11 python3.11-numpy >/dev/null 2>&1; then
            DIMNA_PYTHON=python3.11 # Rocky 9: its python3 is 3.9, without tomllib
            export DIMNA_PYTHON
        else
            dnf install -y python3 python3-numpy >/dev/null || true
        fi
    fi
    # Only the size checks catch nothing inside samples.i16; the reader checks every
    # chunk's CRC. So it is required wherever the distribution has Python 3.11+ and numpy:
    # everywhere tested but Ubuntu 22.04 (Python 3.10, no tomllib).
    os=$(. /etc/os-release && echo "$ID $VERSION_ID")
    if [ "$os" != "ubuntu 22.04" ]; then
        DIMNA_REQUIRE_READER=1
        export DIMNA_REQUIRE_READER
    fi
}

package_test() { # DIR
    [ "$(id -u)" = 0 ] || fail "the package mode installs packages: run it as root in a container"
    for g in dimna realtime; do
        if getent group "$g" >/dev/null; then echo "note: the group $g exists before the install"; fi
    done
    dir=$(cd "$1" && pwd -P)
    if command -v apt-get >/dev/null 2>&1; then
        set -- "$dir"/dimna_*_amd64.deb
        [ $# = 1 ] && [ -f "$1" ] || fail "expected one .deb in $dir, found: $*"
        say "apt-get install $1"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y "$1"
        remove="apt-get purge -y dimna"
    elif command -v dnf >/dev/null 2>&1; then
        set -- "$dir"/dimna-*.x86_64.rpm
        [ $# = 1 ] && [ -f "$1" ] || fail "expected one .rpm in $dir, found: $*"
        say "dnf install $1"
        dnf install -y "$1"
        remove="dnf remove -y dimna"
    else
        fail "neither apt-get nor dnf"
    fi
    install_test_tools
    check_installed
    run_checks /usr/bin
    say "$remove"
    $remove
    check_removed
}

mode=${1:-}
[ $# -gt 0 ] && shift
case "$mode" in
run)
    [ $# -ge 1 ] || fail "usage: $0 run BINDIR [--headless-only]"
    run_checks "$@"
    ;;
tarball)
    [ $# -ge 1 ] || fail "usage: $0 tarball FILE.tar.gz [--headless-only]"
    mkdir "$tmp/unpacked"
    tar -xzf "$1" -C "$tmp/unpacked"
    option=${2:-}
    set -- "$tmp/unpacked"/*/
    [ $# = 1 ] && [ -d "$1/bin" ] || fail "the tarball does not hold one folder with a bin/"
    run_checks "${1%/}/bin" $option
    ;;
package)
    [ $# -eq 1 ] || fail "usage: $0 package DIR"
    package_test "$1"
    ;;
xbps-libs)
    [ "$(id -u)" = 0 ] || fail "xbps-libs installs packages: run it as root in a container"
    xbps-install -Syu xbps
    xbps-install -Sy wayland vulkan-loader freetype fontconfig libxkbcommon alsa-lib
    ;;
*)
    sed -n '2,/^set -eu/p' "$0" | sed '$d'
    exit 2
    ;;
esac
echo "PASS: $mode"
