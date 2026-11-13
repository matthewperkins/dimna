# Plan: no line over 140 characters

Read `docs/plans/README.md` first. Formatting only: not one token of code changes.

## Why

`docs/readability-review.md` item 12. About 220 lines are longer than 140 characters; the
longest are log calls and struct literals several hundred characters wide. `zig fmt` does
not wrap a line, but it lays out one item per line when an argument list, struct literal
or array literal ends with a trailing comma, and it keeps line breaks placed before
binary operators.

## What to do

For every `.zig` file under `src/` and `build.zig` (not `vendor/`, not generated files):
bring every line to 140 characters or fewer by adding trailing commas and line breaks
only, then run `zig fmt`. Prefer, in order: a trailing comma in the outermost call or
literal; breaking a long condition before `and`/`or`; splitting a long comment line at a
word boundary (keeping `///` and `//!` markers). Where a format string itself is longer
than the limit, it may be split with `++` between two string literals **only at a place
that does not change the string**; if you are not certain, leave that line long and list
it in the report.

Do not rename, reorder, extract variables, or "improve" anything while you are there.

## Evidence

The check that nothing but layout changed is mechanical, and you must run it:

- `zig build --release=safe` before and after, and compare the two `oez` and
  `oez-headless` binaries (`cmp`). Zig builds are usually reproducible; an earlier agent
  saw 31 differing bytes between two builds of identical source, so first build the
  unchanged tree twice and see whether the binaries are identical. If they are, identical
  binaries after your change are strong evidence. If they are not, say so and fall back
  to the next check alone.
- Token comparison: write a small script (in your /tmp folder, not the repository) that
  strips whitespace and trailing commas before `)`, `}` and `]` from the before and
  after versions of each file (`git show main:<file>` against the working copy) and
  compares them. Comments must compare equal after joining their words. Report the
  result per file; any file that differs beyond that is a mistake to fix.
- `zig build test --summary all` passes with the same counts; `zig fmt --check src
  build.zig` prints nothing; `awk 'length > 140'` over the files prints nothing, or only
  the lines you listed as left long.

## Files you may change

Every `.zig` file under `src/` and `build.zig`, layout only.

## Done means

The three checks above, with their output, and the list of lines left long with the
reason for each.
