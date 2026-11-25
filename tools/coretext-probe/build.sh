#!/bin/sh
# Builds coretext_probe with `zig cc`. FreeType is compiled from vendor/freetype (as
# build.zig does), HarfBuzz and FriBidi are Homebrew's (for comparison only).
# usage: build.sh OUTDIR       (OUTDIR is created; the program is OUTDIR/coretext_probe)
# Zig is taken from $ZIG, else ~/.local/opt/zig-aarch64-macos-0.17.1/zig.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:?usage: build.sh OUTDIR}
zig=${ZIG:-$HOME/.local/opt/zig-aarch64-macos-0.17.1/zig}
brew=${HOMEBREW_PREFIX:-/opt/homebrew}
mkdir -p "$out/ft"
ft=$root/vendor/freetype
objs=
for f in base/ftbase base/ftinit base/ftsystem base/ftdebug base/ftbitmap base/ftglyph base/ftmm \
         base/ftbbox base/ftsynth base/ftgasp base/ftfstype base/ftstroke sfnt/sfnt truetype/truetype \
         cff/cff psaux/psaux psnames/psnames pshinter/pshinter autofit/autofit smooth/smooth \
         raster/raster gzip/ftgzip; do
    o=$out/ft/$(echo "$f" | tr / _).o
    [ -f "$o" ] || "$zig" cc -c -O2 -w -fno-sanitize=undefined -DFT2_BUILD_LIBRARY '-DFT_CONFIG_MODULES_H=<dimna_ftmodule.h>' -DNDEBUG \
        -I"$ft/include" -I"$ft/dimna" "$ft/src/$f.c" -o "$o"
    objs="$objs $o"
done
# shellcheck disable=SC2086
"$zig" cc -O2 -Wall -Wno-deprecated-declarations -I"$ft/include" -I"$brew/include" \
    "$here/coretext_probe.c" $objs -L"$brew/lib" -lharfbuzz -lfribidi \
    -framework CoreText -framework CoreGraphics -framework CoreFoundation \
    -o "$out/coretext_probe"
echo "built $out/coretext_probe"
