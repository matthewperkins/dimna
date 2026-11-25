# Linux and macOS: what each uses, and how far each has been tried

The programs, the config file, the keys and the recording format are the same on both.
What differs is what draws, sounds and talks to the board:

| | Linux | macOS |
|---|---|---|
| machines | x86_64, any distribution with glibc 2.34+ or musl | Apple silicon (tried on macOS 27, a MacBook Air M4) |
| windows and graphics | Wayland directly, Vulkan | AppKit, Metal |
| sound | ALSA (PipeWire behind it on most desktops) | Core Audio |
| the board's USB | the kernel's usbfs; a udev rule gives access | IOKit; no driver, no rule, no permission asked |
| text | fontconfig finds fonts, FreeType draws them; HarfBuzz and FriBidi, if installed, for Persian | Core Text for all of it; nothing to install for any language |
| how to get it | `.deb`, `.rpm`, tarballs, or from source | `dimna.app` (ad-hoc signed, not notarized), or from source |
| sample to screen | 1.6 to 2.6 ms, fullscreen with tearing | about 20 ms by default (waits for the refresh, an even scroll); 6 to 7 ms with `--tearing`, fullscreen, on a 60 Hz screen, as macOS reports it |
| a block's delivery from the board | 0.76 ms on average | 0.73 ms on average |

On a Mac the display is quickest fullscreen (`--monitor "Built-in Retina Display"`, or
another screen's name as macOS shows it); Cmd-Tab, Cmd-H and Cmd-M work from there. With
no `scheme_image` in the config, the Mac takes its colours from dimna's icon.

## How far each has been tried

Linux: used on one rig (RHD2132 and RHD2216 headstages, 30 kHz), for recordings from
animals. macOS: newer and less tried. The same board and headstages ran on a MacBook Air
through Apple's USB-C Digital AV Multiport Adapter at 5 Gb/s: ten minutes recorded and
verified with nothing lost, and the display, tiles and sound from the board. Not yet done
there: a soak of hours, a recording compared against the rig's, a latency measurement that
is not macOS's own report, and a build for a macOS older than the one the app was made
on. Until the first three are done, record animals on Linux.

The Mac port's record, step by step with what was measured, is
[plans/macos-port.md](plans/macos-port.md); the board's first sessions on a Mac are in
[plans/macos-step8-usb.md](plans/macos-step8-usb.md). Building on each system is in
[install.md](install.md).
