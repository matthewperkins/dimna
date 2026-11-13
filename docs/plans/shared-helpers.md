# Plan: one of each: the published snapshot, the clock, the channel name, the row list

Read `docs/plans/README.md` first. This is a refactoring plan (rule 8): behaviour must not
change.

## Why

`docs/readability-review.md` item 3: the same thing is written several times, and the
copies can drift apart.

## What to build

1. **`src/published.zig`: `Published(T)`.** A value one thread publishes and other threads
   read without a lock, detecting a torn read by a sequence counter and retrying. Today
   this is written three times, each as fields and two methods of a `Shared` struct:
   - `src/gui/control.zig` `Shared.publish` / `Shared.read` (a `Snapshot`; `read` returns
     whether there was something new),
   - `src/gui/audio_out.zig` `Shared.publish` / `read` (`audio.Settings`),
   - `src/gui/tiles.zig` `Shared.publish` / `read` (`Config`).

   Read all three first and write down, in your report, every way they differ (return
   value, memory orderings, what "seen" means, whether a reader can spin). `Published(T)`
   must serve all three without changing what any of them does. Keep the three
   `Shared.publish`/`read` methods and their signatures as they are (other code calls
   them); they become one-line calls into a `Published(T)` field. The explanation of why a
   torn read is detected goes in `published.zig`, once.
   Export it from `src/root.zig` (`pub const published = @import("published.zig");`) so
   its tests run, and write tests: a value published is read back; `read` reports nothing
   new when nothing was published since; and a two-thread test in which a writer publishes
   a large struct whose fields are all the same counter value, as fast as it can, while a
   reader checks that every value it reads has all fields equal (a torn read would not).
2. **`src/clock.zig`: one monotonic clock.** `nowNs` is defined in
   `src/gui/audio_out.zig`, `src/gui/tiles.zig`, `src/gui/main.zig` (this one takes an
   `Io`), and as `nowSeconds` in `src/gui/control.zig`. Check first that they read the
   same clock (which `clockid`, or which `Io.Clock`); if they do not, stop and report
   instead of unifying them, because latency figures are differences between these. If
   they do, one `pub fn nowNs() i128` in `src/clock.zig` (exported from `root.zig`), and
   the four call it. `main.zig`'s callers pass an `io` they no longer need for this; drop
   the argument at the call sites. `src/gui/session.zig`, `pacing.zig`, `display.zig` and
   `notes.zig` may have callers or copies too: search.
3. **One `channelName`.** `src/gui/display.zig` `channelName` and `src/gui/tiles.zig`
   `channelName` name a channel ("A1-5"). Check that they produce the same text for every
   kind of channel (electrode, aux, adc); report any difference and keep the display's
   text. Move it to a method on `Layout` in `src/types.zig` with a test there, and make
   both call it. `rowLabel` in `display.zig` stays (it labels a panel's row, which is a
   different thing) but should call the same function for the part that names a channel,
   if it has such a part.
4. **`panels.zig`: the row lists.** `fromConfig` parses `car_ref`, `car_subtract`,
   `raw_rows` and `hide` in two `inline for` loops that use `comptime std.mem.eql` on the
   key to decide which field to assign. Replace them by one ordinary function, something
   like `fn rowSetFrom(doc, table, i, key, p) !?RowSet`, called four times, with the
   reference's extra rules (naming rows turns `car` on, and so on) written out after the
   two calls they belong to. The error messages must stay word for word. The existing
   tests in `panels.zig` must pass unchanged; add one for a list that names a row out of
   range for each of the four keys, checking the message.

## Files you may change

`src/published.zig` (new), `src/clock.zig` (new), `src/root.zig` (the two exports),
`src/types.zig` (the naming method and its test), `src/panels.zig`,
`src/gui/control.zig`, `src/gui/audio_out.zig`, `src/gui/tiles.zig`, `src/gui/main.zig`,
`src/gui/display.zig`, `src/gui/session.zig`, `src/gui/pacing.zig`, `src/gui/notes.zig`
(only for callers of the things above).

Another agent is adding tests at the **end** of `src/gui/notes.zig`, `src/gui/tiles.zig`
and `src/gui/ui.zig` at the same time, and changing `build.zig`. Do not touch `build.zig`
or `ui.zig`, and keep your changes in `tiles.zig` and `notes.zig` to the lines the items
above need.

## You may not run the GUI

No windows (rule 2). The GUI's own code is not covered by `zig build test` yet, so for
the GUI files your evidence is: `zig build --release=safe` compiles, and a careful
side-by-side reading. Say so in your report; the lead will run the GUI.

## Done means

`zig build --release=safe` builds; `zig build test --summary all` passes with the new
tests; `zig fmt --check src build.zig` prints nothing; break-it-on-purpose for the
`Published` torn-read test (remove the sequence check in `read`: the two-thread test must
fail, and say how many runs out of how many), for the `channelName` test, and for one of
the new `panels` tests; the report lists the differences you found between the copies
of each thing.
