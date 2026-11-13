# Display latency: what was measured, and how frames are paced

Design notes that used to sit at the top of `src/gui/main.zig`. The code is in
`src/gui/pacing.zig` (when to draw, the margin, the recovery skip) and `src/gui/window.zig`
(presentation feedback, the tearing request). Figures are from the rig: Hyprland 0.57,
NVIDIA RTX 2000 Ada, 60 Hz, measured with the program's own once-a-second log line (the
time from a sample's block reaching the ring to the frame showing it being presented, from
Wayland presentation feedback).

## Tearing (`--tearing`, the mode in use)

--tearing asks the compositor to show each frame at once, mid-scan, instead of at the
refresh; implies --present immediate and --free 2. The lowest latency under a compositor:
1.6 ms from a sample's arrival to the flip (measured, Hyprland 0.57.2), and since a new
frame is flipped every 3 ms, every scan line shows data at most a few ms old (with
refresh-locked frames the bottom of the screen is a whole refresh staler than the top).
Hyprland tears only when all of these hold:
    general.allow_tearing = true                     (config)
    the window is fullscreen                          (--monitor)
    the window asks for it (done here) or has a window rule `immediate = true`
    cursor.no_hardware_cursors = 1                    (config: no tearing while a hardware
                                                       cursor is visible on that monitor)
`hyprctl monitors` shows activelyTearing and tearingBlockedBy. ("next frame is not torn"
is listed whenever a frame is not being torn at that instant; it is not a blocker.)
--free MS draws whenever new samples have arrived, at most every MS milliseconds, instead
of once per refresh just before it.

## Refresh-locked frames

Frame timing (measured on Hyprland 0.57, NVIDIA, 60 Hz). Each frame is drawn `margin`
before the next refresh, predicted from the presentation timestamps:

  composited window        the compositor shows, one refresh later, what was committed
                           before a refresh: 20.2 ms (32.7 ms if drawn right after the
                           frame callback instead)
  fullscreen, direct scanout   the buffer goes to the screen at that refresh: 3.5 ms

Direct scanout has two stable states. While the output is idle when a commit arrives,
Hyprland flips it at once and it is on screen at the refresh aimed at. After a disturbance
(a flip still pending when the commit arrives), every commit waits for the previous flip
and is shown a refresh later, indefinitely. Leaving one refresh out lets the output go idle
again, so (fullscreen only) after 8 frames in a row a refresh late, one frame is skipped;
the wait before the next skip doubles each time (250 ms to 8 s) and resets after 2 s of
frames on time. The losses that remain come from the compositor's side (unverified guess:
it is busy drawing the other monitor when the commit arrives; only owning the display
would remove them).

The margin is 3 ms. It widens only while frames keep landing late (judged against the
best latency of the last seconds, so it works in either regime) and then returns;
--margin-ms fixes it. Direct scanout needs Hyprland's render.direct_scanout = 1, or = 2
(only surfaces declared as game content, which dimna does) and a fullscreen window
(--monitor, or `monitor` in the config file). Free-running (--free) without tearing
queues frames under direct scanout (33.6 ms).


## Driving the monitor with no compositor (removed)

`--direct DP-2` drove the monitor itself (VK_KHR_display with a DRM lease or from a text
console): 1.45 ms at a 1 ms margin. It needed the monitor to itself and was a second main
loop without the later features; tearing under the compositor reaches about the same
figure. Removed after commit `5112336` (`src/gui/direct.zig`).
