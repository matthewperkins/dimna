# Plan: `headless.zig`'s `main` in parts

Read `docs/plans/README.md` first. This is a refactoring plan (rule 8): behaviour must not
change.

## Why

`src/headless.zig` `main` is about 280 lines: argument handling, opening the source,
starting acquisition and the recorder, the soak loop with its once-a-second line, the
live-settings test steps, the verification of what was read, and the summary. It is the
tool the owner uses to soak-test the board, so its output is compared from run to run.

## What to build

Split `main` into functions (or small structs with their state) named for what they do,
so that `main` reads as the order of events. Suggested seams: opening the source
(simulator or board); the per-second report; the live-settings test steps (already a
table); the consumer that verifies sample continuity; the final summary and exit status.
You decide the exact cut after reading it; say in your report what you chose and why.
Moves only: no new options, no changed messages, no changed exit codes.

## Evidence

Before changing anything, build and capture reference output from the simulator (the
simulator is deterministic per sample; times and rates in the output are not):

    zig build --release=safe
    zig-out/bin/oez-headless --help    (or whatever prints the usage; capture it)
    zig-out/bin/oez-headless --sim 32,16 --seconds 5 --no-audio --record /tmp/<yours>/a

and one run for each option `parseArgs` accepts that changes what `main` does with the
simulator (read `parseArgs`; for example `--aux --adc`, `--16ch A1`, `--car`, the
live-settings test, a bad argument, `--seconds 0` if it means something). After the
change, run the same commands and compare: the lines must be the same in kind, order and
wording, the counts that are deterministic must be equal, and the exit statuses equal.
Put both sets side by side in your report for at least three of the runs. Verify one
recording from before and one from after with `python3 -I tools/oez_read.py <folder>`.

Never run it without `--sim` (rule 1): the board path cannot be exercised by you. Say so;
the lead will run a board soak before merging. Read the board branch especially carefully
for that reason, and list every line of it you moved.

`--no-audio` may not exist in headless (audio may be opt-in there): check `parseArgs`,
and make sure none of your runs plays sound.

## Files you may change

`src/headless.zig` only.

## Done means

`zig build --release=safe` builds; `zig build test --summary all` passes;
`zig fmt --check src build.zig` prints nothing; the before/after comparison is in the
report; `main` is under about 80 lines.
