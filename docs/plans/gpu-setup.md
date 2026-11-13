# Plan: `gpu.zig` without the repeated Vulkan boilerplate

Read `docs/plans/README.md` first. Refactoring plan (rule 8): what is drawn must not
change.

## Why

`docs/readability-review.md` item 10. `src/gui/gpu.zig` creates two graphics pipelines
(traces in `createPipeline`, text in `createText`) that repeat their viewport,
rasterization, multisample and dynamic state verbatim, and two history buffers
(`createHistory` for live, `createReview` for scroll-back) by two functions that differ in
a few lines. `Gpu.init` is long because it does instance, surface, device choice, device,
formats, present mode, render pass, command pool and sync objects in one body.

## What to build

1. **One place for the shared pipeline state.** A helper that the trace pipeline and the
   text pipeline both use for everything that is the same, taking what differs (shader
   stages, vertex input, topology, blend attachment, layout). Before writing it, list in
   your report, field by field, what the two pipelines set identically and what
   differently; only the identical part moves. If some field differs that looks as if it
   should not (a bug by copy), leave both as they are and report it.
2. **One history-buffer function.** `createHistory` and `createReview` share a helper
   (buffer, memory, mapping or staging, descriptor set), each keeping its own name and
   signature as callers use them. `destroyReview` and the re-creation of the live history
   must keep working as before: read how `feed`/`session` code calls them.
3. **`Gpu.init` in steps.** Split into private functions named for what each creates
   (`createInstance`, `pickDevice`, `createDevice`, `chooseSurfaceFormat`,
   `choosePresentMode`, ...), keeping the `errdefer` chain correct: every resource created
   before a failure must still be destroyed, in the same order as now. This is the part
   most likely to go wrong; write out, in your report, the order of creation and the
   matching destruction before and after.
4. Lines over 140 characters in this file: wrap them (a trailing comma makes `zig fmt`
   put one argument per line). Only in `gpu.zig`.

Do not change any Vulkan parameter, any shader, the push-constant layout (`TraceParams`),
or the `draw` path's order of commands.

## Files you may change

`src/gui/gpu.zig` only. Other agents are working in `src/gui/control.zig` and the config
parsers.

## Evidence

You may not open windows, so you cannot create a Vulkan surface (rule 2). Your evidence
is the compiler, a field-by-field account, and one thing you can run: check whether
Vulkan validation tooling exists on this machine (`vulkaninfo`, the
`VK_LAYER_KHRONOS_validation` layer under `/usr/share/vulkan/explicit_layer.d`); do not
install anything. Report what is there, so the lead can run the GUI with validation on
before merging. The lead will run the simulator and compare screenshots and frame times.

## Done means

`zig build --release=safe` builds; tests pass; `zig fmt --check src build.zig` prints
nothing; no function in `gpu.zig` over about 100 lines except `draw` (give the lengths
before and after); the report has the identical/different table for the two pipelines,
the creation/destruction order, and anything that looked like a copy bug.
