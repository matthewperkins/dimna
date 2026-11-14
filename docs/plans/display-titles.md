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

## Report

Branch `worktree-agent-af926797b5411a6b4`. Code commit: see `git log` (first commit after main); this report is the second.

**What changed**
- `panels.zig`: `Panel.short` (set by `shortSource` in `default`/`fromConfig`; static text: A1 / A / all / AUX / ADC / TTL), `shortLabel`, `headerPx`/`bodyRect` (triggered strip = line_h + 10), `rowAtBelow`, `usesPanelScale`, `Panel.hidden`, `hideAdc` (stretch, 1e-4 tolerance, all four sides, computed from the original places each time), `Set.at` skips hidden panels.
- `display.zig`: `Display.line_h` (from the last frame) and `adc_hidden`; `bodyRect`/`rowAtPointer` used for traces, row labels, sweep draws, trigger marks, threshold lines, drag and line grabbing, and row picking by the pointer. Title uses the short label and `400µV/row` (V panels `2.5V/row`, trailing zeros trimmed; mV panels `250mV`); scale omitted when every shown row has its own. Triggered titles drop the window and are right-aligned (8 px). `timeAxis`/`axisLeft`. `toggleAdc`, `adcKey` (reads the typed `~` from `in.text` like `helpKey`, removes the paired backtick keys so no note stamps; without a keymap, Shift+backtick). Hidden panels are not drawn. `reset` (r) keeps a panel's place and hidden flag. `~` in `key_help`.
- `main.zig`: one call, `display.adcKey(&input)`, next to `helpKey`.
- `docs/display.md`. README has no text on titles or keys, so unchanged.
- Rows-to-pixels places found: traces/draw rect, `traceParams` (cols, half_px), row labels, `triggerMarks` (trigger line, tint, level line), `thresholdLine`, `dragTo`, `lineAtPointer`, pointer row picking (`rowAt` x5). Note marks, tint pulses and the sweep cursor are not drawn for triggered panels, so need no change.
- ADC-hide and rect changes: trace draws take the rect each frame; the review session makes its overview columns from `pixelRect(...).w` each turn and memoises on (span, cols), i.e. the same path a window resize takes. Stored sweeps/pulses are in sample time. No GPU buffers or feed touched. Columns above `column_region` (4096) fall back as on a very wide window.

**Deviation (rule 4)**: `src/gui/args.zig` got one usage line for `~`, because the existing test "the key summary agrees with the usage text" fails otherwise and the plan requires the key in `key_help`. Revert it if unwanted (then that test must change).

**Decisions where the plan was open**
- Left axis label, when even "-10.0" does not fit: placed at the panel's left edge (px+4), overlapping the row labels. With `pre_ms = 0` there is no left label or "0" (as before).
- A triggered title wider than the panel is clamped to start at px+4 (runs off the right) instead of off the left edge. Other panels' behaviour unchanged.
- Electrode scales >= 1000 µV read `1.50mV/row` (fmtScale with its space removed).
- `short` for an electrode range inside one headstage but not the whole of it is also the headstage name.

**Tests** (`zig build test --summary all`: 213/213, core 133 + gui 80; before: 198). `zig build --release=safe` clean; `zig fmt --check src build.zig` silent.
New tests: panels (short label, scale named, header strip + rowAtBelow, hide owner layout, hide non-spanning + four sides + tolerance, no ADC); display (titles, triggered title/strip/draw rect, row 0 centre + pointer, level line grab in the reduced rect, axisLeft, axis in a frame, `~` hide/show in a frame, `~` key handling + reset, non-spanning neighbour in a frame). Existing threshold-line test: state 22 panel 0 expectation changed 123 to 144, derived by hand (strip 26, R = 674/32 = 21.0625, centre 141.84, +2.63 = 144.47); the sweep panel stays 123.
Break-it, one change each, each run failed in the expected tests: short label returns name (panels short-label test + 3 display); scale-named check (panels + display); strip +10 removed (6 tests); rowAtBelow ignores header (2); hide above-stretch (3); x_within always true (2: non-spanning, panels + display); tolerance 1e-2 (non-spanning/tolerance test); no-ADC returns true (2); compactScale keeps space (3); title not right-aligned (2); bodyRect ignores strip (2); lineAtPointer uses full rect (drag test); axisLeft edge placement (axis unit test + stored frame); axis unit never dropped (3); "0" label offset (2); hidden panels drawn (hide test); `~` removal off (2); every backtick a tilde (plain-backtick test); reset not keeping place (1). The "title window shown again" case was not broken separately (covered by the `-10.0/+40.0` absence assert and the stored output).

**Stored output** `display_frame.txt`: 2014 changed lines, all explained: (a) every title: short label, `µV` space gone, `5.00 V` to `5V` (states 0,1,4,8-13,15-25,28-29 etc.; 4 lines per title: rect+text); (b) triggered panels (states 2, 3, 5-7, 13, 22, 26, 27, 30): draw y/h by the 26 px strip, `half_px` follows, tint/trigger rects start at y 26, right-aligned title without the window, time axis labels (`-10.0`, `0`, `+40.0 ms`), row labels re-positioned (row 0 label now present where the title used to hide it), dashed level line y 101 to 123 (consistent with the strip); (c) states 28/29: the key summary has one more line (`~`), so the overlay grows. State 14 (no font): unchanged (no strip without a font). I checked non-triggered states differ only by title lines; I did not read every one of the 2014 lines.

**Not covered**: no GUI run (rule); `~` on a real keyboard/layout (only the in.text pairing logic is tested); behaviour at ADC-hidden widths above 4096 px; review with a stretched panel only checked through the `pixelRect` path by reading, not by a test; per-view/config saving of hidden state (deliberately none).
