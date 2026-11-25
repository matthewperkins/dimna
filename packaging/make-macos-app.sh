#!/bin/sh
# Makes dimna.app and dimna-macos-arm64.zip from built programs, on a Mac:
#
#   zig build --release=safe && packaging/make-macos-app.sh zig-out/bin OUT_DIR
#
# The bundle: Contents/MacOS/dimna-app (the launcher, packaging/macos/dimna-app), dimna
# and dimna-headless; Contents/Info.plist (packaging/macos/Info.plist with the version of
# build.zig.zon and the macOS the programs were built for); Contents/Resources/dimna.icns
# (from packaging/icon/dimna-1024.png), tools/dimna_read.py and licenses/. Signed ad hoc
# (Apple silicon runs no unsigned code; this names nobody, so a copy downloaded with a
# browser is still held back by Gatekeeper: docs/install.md). Zipped with ditto, which
# keeps the signature intact. Then checked: the signature, that nothing in it needs a
# library outside macOS, `dimna --help`, and `dimna-headless --sim` recording 5 s from
# inside the bundle. Needs only what macOS has (sips, iconutil, codesign, ditto, otool).
set -eu

fail() {
    echo "make-macos-app: $*" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail "usage: make-macos-app.sh BIN_DIR OUT_DIR"
[ "$(uname -s)" = Darwin ] || fail "this is for macOS"
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
for p in dimna dimna-headless; do [ -x "$bin/$p" ] || fail "$bin/$p is not there (zig build --release=safe first)"; done

version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",[[:space:]]*$/\1/p' "$root/build.zig.zon")
case "$version" in
'' | *[!0-9.]*) fail "could not read the version from build.zig.zon: '$version'" ;;
esac
# The newest macOS either program was built for.
minos=$(for p in dimna dimna-headless; do otool -l "$bin/$p" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="minos"{print $2; f=0}'; done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
case "$minos" in
'' | *[!0-9.]*) fail "could not read the programs' minimum macOS: '$minos'" ;;
esac

app=$out/dimna.app
zip=$out/dimna-macos-arm64.zip
case "$app" in
*/dimna.app) rm -rf "$app" ;;
esac
rm -f "$zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/licenses"

cp "$bin/dimna" "$bin/dimna-headless" "$root/packaging/macos/dimna-app" "$app/Contents/MacOS/"
chmod 755 "$app/Contents/MacOS/dimna" "$app/Contents/MacOS/dimna-headless" "$app/Contents/MacOS/dimna-app"
sed -e "s/VERSION/$version/g" -e "s/MINOS/$minos/g" "$root/packaging/macos/Info.plist" >"$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null || fail "Info.plist is not a valid property list"

# The icon: an .iconset of the sizes macOS asks for, each from the 1024 px render.
work=$(mktemp -d "${TMPDIR:-/tmp}/dimna-app-XXXXXX")
cleanup() {
    case "$work" in
    */dimna-app-*) rm -rf "$work" ;;
    esac
}
trap cleanup EXIT
set_dir=$work/dimna.iconset
mkdir "$set_dir"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$root/packaging/icon/dimna-1024.png" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$root/packaging/icon/dimna-1024.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$app/Contents/Resources/dimna.icns"

cp "$root/tools/dimna_read.py" "$app/Contents/Resources/"
cp "$root/LICENSE" "$app/Contents/Resources/licenses/dimna.LICENSE"
cp "$root/vendor/liboni/LICENSE" "$app/Contents/Resources/licenses/liboni.LICENSE"
cp "$root/vendor/stb/LICENSE" "$app/Contents/Resources/licenses/stb.LICENSE"
cp "$root/packaging/icon/ICON-CREDITS.md" "$app/Contents/Resources/licenses/ICON-CREDITS.md"

codesign --force -s - "$app/Contents/MacOS/dimna-headless"
codesign --force -s - "$app/Contents/MacOS/dimna"
codesign --force -s - "$app"
codesign --verify --strict --verbose=2 "$app" 2>&1 | sed 's/^/  /'

# Nothing in the bundle may need a library that macOS does not have.
for p in dimna dimna-headless; do
    bad=$(otool -L "$app/Contents/MacOS/$p" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
    [ -z "$bad" ] || fail "$p needs a library outside macOS: $bad"
done

ditto -c -k --keepParent "$app" "$zip"

# The zip as a user gets it: unpacked elsewhere, its signature still good, the programs run.
mkdir "$work/unzipped"
ditto -x -k "$zip" "$work/unzipped"
got=$work/unzipped/dimna.app
codesign --verify --strict "$got" || fail "the unpacked bundle's signature does not verify"
"$got/Contents/MacOS/dimna" --help >/dev/null 2>&1 || fail "dimna --help failed from the bundle"
mkdir "$work/rec"
"$got/Contents/MacOS/dimna-headless" --sim 32,16 --seconds 5 --record "$work/rec" >"$work/headless.log" 2>&1 || {
    cat "$work/headless.log"
    fail "dimna-headless --sim failed from the bundle"
}
grep -q '^CLEAN' "$work/headless.log" || fail "the bundle's simulator run was not CLEAN"

echo "dimna.app $version, for macOS $minos and newer: $(du -sh "$app" | awk '{print $1}')"
echo "$zip: $(wc -c <"$zip" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$zip" | awk '{print $1}')"
echo "PASS: dimna.app"
