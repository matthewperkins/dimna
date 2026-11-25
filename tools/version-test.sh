#!/bin/bash
# What meta.toml says about the software that wrote it, for three builds of dimna-headless
# (-Dgui=false, ReleaseSafe, each into its own prefix) recording one second from the simulator:
#   - a normal build: `software = "dimna <build.zig.zon's .version>"`, and
#     `software_commit = "<git rev-parse HEAD>"`, with "-dirty" when a tracked file differs;
#   - -Dgit=false: the same `software`, and no software_commit;
#   - git not on PATH: the same.
#
#   tools/version-test.sh          (from anywhere; needs zig, git and a git checkout)
#
# Simulator only (--sim): never touches the board. Files go to /tmp/dimna-version-test-<pid>/
# and are removed afterwards. Exit status 0 if every check passed.
set -u

here=$(cd "$(dirname "$0")/.." && pwd -P)
tmp="/tmp/dimna-version-test-$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",[[:space:]]*$/\1/p' "$here/build.zig.zon")
head=$(git -C "$here" rev-parse --verify HEAD) || exit 2
commit=$head
[[ -n $(git -C "$here" status --porcelain --untracked-files=no) ]] && commit=$head-dirty
echo "version-test: build.zig.zon says $version; the tree is at $commit"

# A folder holding zig and sh alone, for a PATH without git.
mkdir "$tmp/nogit"
ln -s "$(command -v zig)" "$tmp/nogit/zig"
ln -s "$(command -v sh)" "$tmp/nogit/sh"

fail=0
check() { # check DESCRIPTION CONDITION-EXIT-STATUS
    if [[ $2 -eq 0 ]]; then echo "  pass: $1"; else echo "  FAIL: $1"; fail=1; fi
}

# run NAME [ENV...] -- [BUILD-ARGS...]: builds into $tmp/NAME, records, leaves $tmp/NAME.meta
run() {
    local name=$1
    shift
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    if ! (cd "$here" && env "${envs[@]}" zig build --release=safe -Dgui=false --prefix "$tmp/$name" "$@") >"$tmp/$name.build" 2>&1; then
        echo "version-test: the $name build failed:" >&2
        cat "$tmp/$name.build" >&2
        exit 1
    fi
    mkdir -p "$tmp/$name.rec"
    if ! DIMNA_TEST_DISK_RESERVE_GB=1 "$tmp/$name/bin/dimna-headless" --sim 32 --seconds 1 --record "$tmp/$name.rec" >"$tmp/$name.log" 2>&1; then
        echo "version-test: dimna-headless ($name) failed:" >&2
        cat "$tmp/$name.log" >&2
        exit 1
    fi
    cp "$tmp/$name.rec"/*/meta.toml "$tmp/$name.meta"
}

run git --
grep -qxF "software = \"dimna $version\"" "$tmp/git.meta"
check "normal build: software = \"dimna $version\"" $?
grep -qxF "software_commit = \"$commit\"" "$tmp/git.meta"
status=$? # before the description's $(...), which sets $? itself
check "normal build: software_commit = \"$commit\" (meta.toml: $(grep '^software_commit' "$tmp/git.meta" || echo none))" $status

run off -- -Dgit=false
grep -qxF "software = \"dimna $version\"" "$tmp/off.meta"
check "-Dgit=false: software = \"dimna $version\"" $?
! grep -q '^software_commit' "$tmp/off.meta"
check "-Dgit=false: no software_commit" $?

run nogit "PATH=$tmp/nogit" --
grep -qxF "software = \"dimna $version\"" "$tmp/nogit.meta"
check "git not on PATH: software = \"dimna $version\"" $?
! grep -q '^software_commit' "$tmp/nogit.meta"
check "git not on PATH: no software_commit" $?

exit $fail
