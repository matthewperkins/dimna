#!/bin/bash
# Crash test of the recorder: record from the simulator, kill -9 the recorder mid-way, and
# check what a crash leaves behind with the reference reader (tools/dimna_read.py):
#   - the indexed part verifies (every CRC, offsets, gap flags): dimna_read.py says OK;
#   - the recording is reported as interrupted (meta.toml has no [final]);
#   - the unverified tail after the last index record is under 1.5 s of data
#     (the recorder syncs and writes the index about once a second).
#
#   tools/crash-test.sh [KILL_AFTER_SECONDS]      (default 4; build first: zig build --release=safe)
#
# Simulator only (--sim): never touches the board. Files go to /tmp/dimna-crash-test-<pid>/ and
# are removed afterwards. Exit status 0 if every check passed.
#
# Note: /tmp is often a tmpfs, and kill -9 ends only the process, not the kernel: data the
# process wrote is still in the page cache. So this tests the process dying, not power loss.
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
bin="$here/zig-out/bin/dimna-headless"
reader="$here/tools/dimna_read.py"
kill_after=${1:-4}
max_tail_s=1.5

if [[ ! -x "$bin" ]]; then
    echo "crash-test: $bin not found; run 'zig build --release=safe' first" >&2
    exit 2
fi

tmp="/tmp/dimna-crash-test-$$"
mkdir -p "$tmp/rec"
trap 'rm -rf "$tmp"' EXIT

"$bin" --sim 32,16 --seconds 30 --record "$tmp/rec" >"$tmp/headless.log" 2>&1 &
pid=$!
sleep "$kill_after"
if ! kill -0 "$pid" 2>/dev/null; then
    echo "crash-test: dimna-headless exited before the kill; its output:" >&2
    cat "$tmp/headless.log" >&2
    exit 1
fi
kill -9 "$pid"
wait "$pid" 2>/dev/null
echo "crash-test: killed dimna-headless (kill -9) after ${kill_after} s"

dirs=("$tmp"/rec/*/)
if [[ ${#dirs[@]} -ne 1 || ! -d "${dirs[0]}" ]]; then
    echo "crash-test: expected one recording folder under $tmp/rec, found: ${dirs[*]}" >&2
    cat "$tmp/headless.log" >&2
    exit 1
fi
rec="${dirs[0]%/}"

out=$(python3 "$reader" "$rec")
status=$?
echo "$out"

fail=0
check() { # check DESCRIPTION CONDITION-EXIT-STATUS
    if [[ $2 -eq 0 ]]; then echo "  pass: $1"; else echo "  FAIL: $1"; fail=1; fi
}

[[ $status -eq 0 ]] && grep -q '^  OK$' <<<"$out"
check "the indexed part verifies (dimna_read.py exit $status)" $?

grep -q 'INTERRUPTED (no \[final\])' <<<"$out" && ! grep -q '^\[final\]' "$rec/meta.toml"
check "reported as interrupted (no [final] in meta.toml)" $?

# "48 channels at 30000 Hz, 113152 samples (3.772 s) in ..." and "unverified tail: N bytes"
read -r nch rate rows < <(sed -nE 's/^  ([0-9]+) channels at ([0-9.]+) Hz, ([0-9]+) samples.*/\1 \2 \3/p' <<<"$out")
tail_bytes=$(sed -nE 's/.*unverified tail: ([0-9]+) bytes.*/\1/p' <<<"$out")
if [[ -z "${nch:-}" || -z "${tail_bytes:-}" ]]; then
    check "could parse the reader's output" 1
else
    [[ $rows -gt 0 ]]
    check "something was indexed ($rows samples)" $?
    tail_s=$(python3 -c "print(f'{$tail_bytes / ($nch * 2 * $rate):.3f}')")
    python3 -c "import sys; sys.exit(0 if $tail_bytes / ($nch * 2 * $rate) < $max_tail_s else 1)"
    check "unverified tail ${tail_s} s ($tail_bytes bytes) < ${max_tail_s} s" $?
fi

if [[ $fail -ne 0 ]]; then
    echo "crash-test: FAILED; dimna-headless output:" >&2
    cat "$tmp/headless.log" >&2
    exit 1
fi
echo "crash-test: passed"
