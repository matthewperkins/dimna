#!/bin/sh
# Writes dimna's .deb and .rpm from an unpacked glibc release folder, with nfpm
# (packaging/nfpm.yaml). Run by packaging/ci-build.sh; works anywhere nfpm is installed.
#
#   packaging/make-packages.sh RELEASE_DIR OUT_DIR
#
# RELEASE_DIR is zig-out/release/dimna-<version>-x86_64-linux-gnu (`zig build release`).
# The package version is <version> (build.zig.zon's, from the folder's name). With
# DIMNA_TAG set (the workflow sets it for a pushed tag), the tag must be v<version>, or this
# fails: a release's packages and tarballs carry the same version. Without it the build is
# not a release and the version gets a pre-release suffix, <version>-dev.g<commit>, which
# apt and dnf sort before <version> itself.
set -eu
fail() {
    echo "make-packages: $*" >&2
    exit 1
}
[ $# -eq 2 ] || fail "usage: $0 RELEASE_DIR OUT_DIR"
here=$(cd "$(dirname "$0")" && pwd -P)
rel=$(cd "$1" && pwd -P)
mkdir -p "$2"
out=$(cd "$2" && pwd -P)

name=$(basename "$rel")
case "$name" in
dimna-*-x86_64-linux-gnu) ;;
*) fail "$rel is not a dimna-<version>-x86_64-linux-gnu release folder" ;;
esac
version=${name#dimna-}
version=${version%-x86_64-linux-gnu}

if [ -n "${DIMNA_TAG:-}" ]; then
    [ "$DIMNA_TAG" = "v$version" ] || fail "the tag is $DIMNA_TAG but the release is $version (build.zig.zon)"
    DIMNA_VERSION=$version
else
    commit=${GITHUB_SHA:-$(cat "$rel/COMMIT" 2>/dev/null || echo unknown)}
    commit=$(printf '%s' "$commit" | cut -c1-12 | tr -c 'A-Za-z0-9' '.')
    DIMNA_VERSION=$version-dev.g$commit
fi
export DIMNA_VERSION
echo "make-packages: dimna $DIMNA_VERSION from $rel"

# nfpm.yaml's paths are relative to the release folder.
cd "$rel"
nfpm package --config "$here/nfpm.yaml" --packager deb --target "$out/"
nfpm package --config "$here/nfpm.yaml" --packager rpm --target "$out/"
ls -l "$out"
