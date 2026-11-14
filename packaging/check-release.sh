#!/bin/sh
# Checks release binaries; run by `zig build release` before it packs a tarball.
#
#   packaging/check-release.sh MAX_GLIBC FILE...
#
# Fails (exit status 1) if a FILE needs a shared library other than the ones below, or a
# GLIBC_ symbol version above MAX_GLIBC (e.g. 2.34). HarfBuzz and FriBidi must never be
# linked: dimna opens them at run time only when a text needs them. Needs readelf and
# objdump (binutils) and GNU sort (-V).
set -eu
allowed="libwayland-client.so.0 libvulkan.so.1 libfreetype.so.6 libfontconfig.so.1
libxkbcommon.so.0 libasound.so.2 libm.so.6 libc.so.6 ld-linux-x86-64.so.2 libc.so"
max=$1
shift
status=0
for f in "$@"; do
    needed=$(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
    for lib in $needed; do
        case " $(echo $allowed) " in
        *" $lib "*) ;;
        *)
            echo "$f: needs $lib, which a release must not link" >&2
            status=1
            ;;
        esac
    done
    # A static binary has no dynamic symbols; objdump says so on stderr.
    versions=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -u -V)
    for v in $versions; do
        if [ "$(printf '%s\n%s\n' "$v" "$max" | sort -V | tail -n 1)" != "$max" ]; then
            echo "$f: needs GLIBC_$v, above $max" >&2
            status=1
        fi
    done
    highest=$(echo "$versions" | tail -n 1)
    [ -n "$needed" ] || needed="none (static)"
    echo "$(basename "$f"): NEEDED $(echo $needed); highest GLIBC version: ${highest:-none}"
done
exit $status
