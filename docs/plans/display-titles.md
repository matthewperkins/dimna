# Plan: terser panel titles, triggered-panel header, hiding the ADC panel

Read `docs/plans/README.md` first; its rules apply. Display only: nothing here touches
acquisition, recording, the board or the feed.

## Files you may change

`src/gui/display.zig`, `src/panels.zig`, `src/gui/main.zig` (key handling only, if the
key is not handled in display.zig), `src/gui/testdata/display_frame.txt` (regenerated,
see below), `docs/display.md`, `README.md` (only where it describes titles or keys).

## Background

`panelTitle` (display.zig, around line 1406) draws a panel's title top left; `timeAxis`
draws a triggered panel's time labels along the bottom. A panel's `name()` is the config's
`name =` (on the owner's rig: "Port B", "Port A", "ADC"). The owner's layout:
Port B `rect = [0, 0, 0.5, 0.75]`, Port A `[0.5, 0, 0.5, 0.75]`, ADC `[0, 0.75, 1, 0.25]`.

## The changes

1. **Short source label in every title, all modes.** Replace `p.name()` in the title with
   a short label for what the panel shows: an electrode panel showing one headstage →
   its headstage name ("A1", "B1"); if that port has no second headstage in the current
   layout, just the port letter ("A"); a panel of all electrodes → "all"; aux → "AUX";
   adc → "ADC"; ttl → "TTL". Work out from `Panel` (`kind`, `first_ch`, `rows`) and the
   layout what the headstage is; if the panel does not keep enough to know, store the
   short label when the config is parsed (`fromConfig`). `name()` stays for everything
   else that uses it.
2. **Scale text.** Format as `400µV/row` (no space; V panels `2.5V/row`). Leave it out
   when every shown row of the panel uses its own per-row scale (no shown row uses the
   panel's scale). Find where per-row scale overrides live (`per_row`, `raw_scale`).
3. **Triggered panels (TTL or slope trigger, `p.mode == .triggered`):**
   - Drop the trigger window ("-10.0/+40.0 ms") from the title.
   - The time axis labels at the bottom use the same signs and format as that dropped
     text: `-10.0 ms` at the left, `0` at the trigger, `+40.0 ms` at the right. The left
     label is always shown; when it does not fit between the row labels and the trigger
     line, drop " ms" from it, and if it still does not fit, place it at the left edge
     anyway (overlap with the "0" is worse than missing; say what you chose).
   - The whole title is right-aligned: it ends 8 px from the panel's right edge.
   - **Reserve a header strip** so the title never lies over row 0: rows are laid out
     in the panel rect minus a strip of `line_h + 10` px at the top. Every place that
     maps rows to pixels for this panel must use the same reduced rect (traces, row
     labels, threshold / trigger-level lines and their dragging, notes markers). Find
     them all; a mismatch would put the draggable level off its trace.
   Scroll and sweep panels keep their header-less layout.
4. **`~` (Shift+` ; keys go by label, see docs/display.md) hides and shows ADC panels** on
   the neural display, live. While hidden, each other panel whose edge borders a hidden
   panel and whose extent along that edge lies within the hidden panel's extent grows
   to cover it (all four sides; compare fractions with a 1e-4 tolerance). With the
   owner's layout, Port A and Port B grow to the full height. Not saved; restart shows
   it again. Nothing happens if there is no ADC panel. Add it to the key list
   (display.zig around line 250, the help overlay) and to docs/display.md.
   Anything sized to a panel's pixel width or rect (stored triggered sweeps, the review
   session's column cache, row geometry) must cope with the rect changing; use the path a
   window resize already takes and say in the report which path that is. Do not
   reallocate GPU buffers or change the feed for this.

## Tests

- Unit tests in display.zig / panels.zig for: the short label (one-headstage port → "A",
  two-headstage port → "A1", adc, all); scale omitted when all rows are per-row; the
  triggered header strip (row 0's centre moves down by the strip); the ADC-hide stretch
  with the owner's three rects (Port A/B become height 1.0, the ADC panel is not drawn)
  and a layout where a neighbour does not span the edge (it does not grow).
- The stored display output `src/gui/testdata/display_frame.txt` will change (titles).
  Regenerate with `DIMNA_DISPLAY_FRAME_OUT=<path>` (see how the test reads it), and in the
  report list which lines changed and why; a change you cannot explain is a bug.
- Break each new test once on purpose (README rule).
- `zig build test --summary all`, `zig build --release=safe`, `zig fmt --check src build.zig`.

## Not in this plan

Colours (another plan runs at the same time and changes `theme.zig`, `gpu.zig`, the
shader; do not touch those files). Do not run the GUI.

## Report

Append a "Report" section here: what changed, the tests and their break-it results,
the stored-output diff explained, anything left open.
