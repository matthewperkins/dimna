# Feasibility: dimna on Windows

Written 2026-11-26, from a reading of `main` at v0.3.0. Nothing was built for Windows and
nothing was run on a Windows machine: every statement about Windows below is from its
documentation or from memory, and the ones that decide something are marked **to check**.
This is an analysis, not a plan to hand out; the rules in `docs/plans/README.md` would
apply to any work that follows from it.

## Verdict

A Windows port is feasible, and the Mac port has already done the part that makes it so:
every system-specific piece sits behind a compile-time seam with a written contract. About
two thirds of the source needs no change.

Three things cannot be carried over as they are, and each needs the owner's decision
before any code:

1. **How dimna reaches the board.** On Windows a USB device has exactly one driver. FTDI's
   own driver is the one the Open Ephys GUI uses; dimna's own FT600 code needs a different
   one (WinUSB). One board on one machine cannot serve both programs without switching the
   driver by hand. Decided: FTDI's DLL. See "The USB decision".
2. **The latency figure.** 1.6 to 2.6 ms from sample to screen was measured on Hyprland
   with tearing. Windows may reach it fullscreen; it cannot be promised before it is
   measured, and in a window it will very probably be a frame later.
3. **The guarantees that rest on Linux scheduling**: `SCHED_FIFO`, `mlockall`, and a
   machine that does nothing by itself. Windows has near-equivalents for the first two and
   none for the third (updates, Defender, a reboot that the system schedules).

Size, by analogy with the Mac port: about 3,500 to 5,000 new lines in six or seven backend
files, against 6,500 for macOS (which needed a second GPU backend; Windows does not). The
Mac port's steps took the order core, USB, window and GPU, text, audio; the same order fits.

## What "current capabilities" means here

The list the rest of this document is judged against:

- acquisition from the ONI/FT600 board with no lost samples, at 0.76 ms per block;
- recordings in format v1, crash-safe (data synced before its index), verified by
  `tools/dimna_read.py`;
- the display at 1.6 to 2.6 ms, with the control and tile windows on their own threads;
- live settings, the reopen after a read error, disk-space alarms;
- the spike audio monitor at about 16 ms;
- seven languages, Persian right to left;
- the hardware-safety rule: no chip-configuration write can reach the FT600
  (`src/ft600.zig` refuses it);
- the test suite (318 tests) and the CI that builds, installs and runs every release.

## What already helps

| seam | file | Linux | macOS | lines of the macOS backend |
|---|---|---|---|---|
| system calls | `src/os.zig` | `os_linux.zig` | `os_darwin.zig` | 330 |
| USB | `src/usb.zig` | `usb_linux.zig` (usbfs) | `usb_darwin.zig` + `usb_iokit.c` | 689 |
| window | `src/gui/window.zig` | `window_wayland.zig` | `window_appkit.zig` + shim | 2,331 |
| GPU | `src/gui/gpu.zig` | `gpu_vulkan.zig` | `gpu_metal.zig` + shim | 2,024 |
| sound | `src/gui/audio_out.zig` | `audio_alsa.zig` | `audio_coreaudio.zig` | 334 |
| text | `src/gui/text_backend.zig`, `fontfind.zig` | FreeType, fontconfig | `text_coretext.zig` | 1,143 |

- Each seam file states what a backend must keep. `os.zig` and `usb.zig` end in
  `@compileError` for any other system, so a Windows build fails at exactly the places
  that need writing.
- A test in `os.zig` fails if any file outside the backends calls the system directly, so
  there are no hidden Linux calls in the shared code.
- `zig build -Dgui=false` builds `dimna-headless` alone, which is the natural first
  milestone, as it was on the Mac.
- The recorder writes through `std.Io` (create, write, sync, rename), which Zig
  implements for Windows.
- Zig cross-compiles to `x86_64-windows` from the rig, so a Windows build can be checked
  for compile errors here before anyone has a Windows machine. It cannot be run here.

## Easy

Work of the same kind the Mac port already did, with a direct Windows equivalent.

| what | Windows equivalent | note |
|---|---|---|
| monotonic clock | `QueryPerformanceCounter` | |
| free disk space | `GetDiskFreeSpaceExW` | the 10 GB reserve and the alarms are shared code |
| sync to disk | `FlushFileBuffers` | what `std.Io`'s `sync` does on Windows; **to check** that it reaches the drive on NTFS as `fsync` does on Linux |
| zeroed pages, unmap | `VirtualAlloc`, `VirtualFree` | releasing part of a mapping needs `MEM_DECOMMIT`, not a partial free: the overview store unmaps in 2 MiB pieces |
| positional read, append | `ReadFile` with an offset, `FILE_APPEND_DATA` | |
| keep the machine awake | `SetThreadExecutionState` | the seam exists already (`keepAwake`), added for the Mac |
| Vulkan surface | `VK_KHR_win32_surface` | `gpu_vulkan.zig` names Wayland in three places (the surface, the extension list, one comment about size); the rest, 1,260 lines and all the shaders, is shared |
| config and state paths | `%APPDATA%\dimna`, `%LOCALAPPDATA%\dimna` | today `$XDG_CONFIG_HOME`, `$HOME/.config`, `~/.local/state` in `main.zig`, `env.zig`, `notes.zig`: four places |
| filters, spikes, tiles, thresholds, review, pyramid, TOML, i18n, probes, the recording format | none needed | pure computation |
| `tools/dimna_read.py`, `dimna_compare.py`, `band_power.py` | none needed | numpy and the standard library; they already use explicit little-endian types |
| window placement | `SetWindowPos` | easier than on Wayland: a program may place its own windows, so the Hyprland rule for the control window has no counterpart to write |

Also easy, but each a small decision:

- **Test folders.** About ten tests write under `/tmp/dimna-...-<pid>`. They need the
  system's temporary folder.
- **Ctrl-C and shutdown.** `SIGINT`, `SIGTERM` and `SIGHUP` become
  `SetConsoleCtrlHandler` (headless) and `WM_CLOSE` / `WM_QUERYENDSESSION` (GUI). Windows
  gives a console program about 5 s after the console is closed and then kills it, so
  "the recording is closed properly first" holds only if closing takes less than that.
  It does today.
- **`dimna-headless --driver d3xx`** goes through liboni's `dlopen`. liboni builds on
  Windows (the Open Ephys GUI uses it there), but see "The USB decision".

## Difficult

New backends, or behaviour that has to be measured before it can be claimed.

### The window (about 1,000 to 1,400 lines)

A Win32 backend for `window.zig`. The contract is specific, and four of its points are
work on Windows:

- **Three windows on three threads, each pumping its own events.** Win32 allows this (a
  window belongs to the thread that made it), which AppKit did not; this is easier than
  on the Mac.
- **Keys as the character on the key cap, without modifiers**, plus the typed text, with
  no key repeat: `WM_KEYDOWN` with `MapVirtualKeyW`, and `WM_CHAR` for the text.
- **Presentation times**: `takePresented()` reports when each frame reached the screen, on
  the clock `nowNs` reads. Wayland gives this (presentation-time). On Windows there is
  `VK_EXT_present_timing` (new, driver support **to check**) or DXGI frame statistics,
  which a Vulkan swapchain does not expose. Without one of them the latency read-out, a
  central feature, shows an estimate and not a measurement. The Mac backend had the same
  problem and solved it with `MTLDrawable.presentedTime`.
- **Pinch and smooth scroll** from a touchpad (`WM_POINTER`, or `WM_GESTURE`), and
  per-monitor DPI awareness, since the contract says pointer units are pixels.

### Tearing and the 1.6 to 2.6 ms

- Fullscreen, Vulkan's `IMMEDIATE` present mode normally tears on Windows (the swapchain
  is given the screen directly, "independent flip"). That is the Hyprland case, and the
  same figure is plausible. **To check, by measurement.**
- In a window, frames go through the desktop compositor (DWM), which shows them at the
  next refresh. Tearing in a window needs the driver to put the Vulkan swapchain on DXGI
  with "allow tearing"; NVIDIA has a setting for it, and it is not under dimna's control.
- The rig's number was checked against the compositor's own report. The Mac's is "as
  macOS reports it". Windows would at first have neither (see presentation times above),
  so the first honest figure needs a photodiode or high-speed video.

### Text (two routes)

- **FreeType, as on Linux.** `text_freetype.zig` (659 lines) is reused. FreeType,
  HarfBuzz and FriBidi are not on Windows: they would be built from source in
  `build.zig` and linked in, or shipped as DLLs. fontconfig is replaced by a small font
  finder over the installed fonts (DirectWrite's font collection, or the registry's font
  list), which must understand the fontconfig-style patterns the program asks for
  (`fontfind.zig` lists them: a family, `monospace`, `sans-serif:charset=<hex>`, the three
  named fallbacks). About 300 lines, and three new vendored libraries.
- **DirectWrite**, as Core Text on the Mac: font lookup, fallback, bidi and shaping from
  the system, nothing to ship. It is COM, so it needs a C or C++ shim as AppKit did.
  About 1,000 to 1,200 lines. Persian and Chinese then work with what Windows installs.

DirectWrite is the closer match to the Mac decision ("nothing to install for any
language"); FreeType is less new code. The stored layout outputs
(`src/gui/testdata/*.txt`) are per backend either way.

### Sound (about 400 lines)

WASAPI, in a C shim (it is COM). `audio_out.zig` already supports a device that takes one
period at a time. Shared mode adds the system mixer's 10 ms; exclusive mode can match the
rig's 16 ms total but takes the device from every other program. **To check** by the
same measurement the Mac's got.

### Scheduling, memory and the pacing sleep

- **Real-time priority.** `SCHED_FIFO` becomes `THREAD_PRIORITY_TIME_CRITICAL`, or MMCSS
  ("Pro Audio") for the audio thread. Neither is `SCHED_FIFO`: Windows still preempts for
  its own work. `realtimeLimit()` returns null, as on the Mac.
- **Locked memory.** There is no `mlockall`. `VirtualLock` locks named regions, up to the
  working-set size the process sets for itself. `lockMemory()` would lock the rings and
  the history, not "everything, including the future".
- **The pacing sleep** (`oni_usb.zig:316`) sleeps between 50 µs and 5 ms to let a block
  fill. Windows sleeps are 1 ms at best with the default timer and about 0.5 ms with a
  high-resolution waitable timer (Windows 10 1803 and later). The Mac turned pacing off
  (`pace_default`); Windows would start the same way, at the cost of more, smaller reads.
  The 0.76 ms block delivery is then **to check**, not assumed.

### Files that other programs hold open

- **Replacing `meta.toml` by rename.** On Linux a rename over a file someone is reading
  always works. On Windows it fails if a reader opened the file without
  `FILE_SHARE_DELETE`, which is the default in Python and most programs. A reader that
  keeps `meta.toml` open while dimna records would make the replacement fail. Needs a
  retry and a clear error, and a line in `docs/recording.md`.
- **Antivirus.** Defender scans files as they are written and can hold them open for a
  moment. The recorder's stall alarm would show it; excluding `record_dir` would be part
  of the install instructions.

### Tests and CI

- Three tests `fork` (`record_test.zig`, `reopen_test.zig`); one reads `/proc`
  (`acquisition.zig:409`, already skipped off Linux). Windows has no `fork`; these tests
  are skipped or rewritten to start a second process.
- `tools/crash-test.sh` and `version-test.sh` are shell scripts with `kill -9`. They run
  under Git Bash with changes, or are rewritten in Python.
- CI: a `windows-latest` job, as the `macos` job. GitHub's runners have no GPU and no
  board, so, as on the Mac, CI proves "builds and the tests pass", not "draws" or
  "records from a board".
- Packaging: a zip at first. An unsigned program gets a SmartScreen warning; a signing
  certificate costs money every year and is the owner's choice.

## Not possible as they are

These cannot be kept unchanged. Each has a substitute, named with it.

| capability on Linux | why not on Windows | substitute |
|---|---|---|
| The board works with dimna's own USB code **and** with FTDI's driver, with no setup beyond a udev rule | one driver per device; dimna's code needs WinUSB bound to the board | see "The USB decision" |
| `ft600.zig`'s guard is the only path to the chip, so a chip-configuration write cannot happen | true only on the WinUSB route; on the FTDI route the DLL has `FT_SetChipConfiguration` and dimna can only promise never to call it | the guard stays for WinUSB; for FTDI's DLL the promise is weaker and should be said so in `docs/hardware.md` |
| `current -> session` symbolic link, swapped atomically, for the camera recorder | making a symbolic link needs administrator rights or Developer Mode | a directory junction (no rights needed, absolute target, not swapped in one step) or a `current.txt` holding the path; either changes what `record.sh` reads |
| `mlockall`: nothing of dimna is ever paged out | no such call | `VirtualLock` on the big buffers |
| `SCHED_FIFO` for acquisition, audio and the display | no equivalent class for an ordinary process | time-critical priority, MMCSS |
| A machine that does nothing unasked during an experiment | Windows Update, scheduled reboots, Defender | machine setup: active hours, update pause, exclusions. Outside the program |
| `--driver d3xx` with D3XX 1.0.x, as measured on the rig | the Windows D3XX is another version and another code base | measured again on Windows, or dropped there |
| Tearing in a window, chosen by the program | the compositor decides | fullscreen for the lowest latency |
| Hyprland window rules, the `.desktop` entry, `.deb`/`.rpm`, the udev rule, the realtime group | Linux packaging | a Start-menu shortcut, a zip or installer |

Nothing in the recording format, the filters, the display's content or the control
window's behaviour is in this table.

## The USB decision

The board's FT600 can be reached three ways on Windows. This choice comes first, because
it decides whether the hardware-safety rule and the measured block timing carry over.

**A. WinUSB, with dimna's own FT600 code** (a `usb_windows.zig`, about 400 to 500 lines).

- Keeps `ft600.zig` as it is: the same requests as on Linux and the Mac, the guard, the
  tests.
- The contract's hard point is that a timed-out bulk read **reports the bytes that
  arrived**. With WinUSB that means an overlapped `WinUsb_ReadPipe`, `WinUsb_AbortPipe`
  when the time is up, and the count from `WinUsb_GetOverlappedResult`. Microsoft's
  documentation does not say what count an aborted read reports. **To check on a
  board, first**: the Mac port had the same question for IOKit and answered it in its
  step 8.
- The cost is the driver. The board must be bound to WinUSB with an INF file, which
  needs administrator rights and a signed driver package (the tool Zadig does this by
  installing a certificate of its own). While it is bound to WinUSB, the Open Ephys GUI
  on that machine does not see the board, and Windows has been reported to put the
  FTDI driver back by itself after an update.
- FTDI now ships a WinUSB-based D3XX of its own (`FTD3XXWU`, 1.4.x). If the board is
  installed with that package, the device is already bound to WinUSB, FTDI's signature
  covers the driver, and dimna's code could open it directly. **To check**: whether a
  second program can open a device FTDI's package bound, and whether Open Ephys's GUI
  works with that package. If both hold, this removes most of A's cost.

**B. FTDI's D3XX DLL, through liboni** (dimna's existing `--driver d3xx` path).

- No driver work: it is what a Windows Open Ephys user already has, and both programs
  work on the same machine (not at the same time).
- dimna's FT600 code and its guard are not used. The differences measured on the rig
  between `usb` and `d3xx` (`docs/install.md`: reads in dozens of pieces, a 200 ms wait
  on every abort) were for D3XX 1.0.14 on Linux; the Windows DLL is other code and would
  be measured again.
- FTDI's 1.3.0.8 Windows driver delivered packets out of order with `FT_ReadPipeEx`
  (fixed in 1.3.0.10, by its release notes). dimna would need to state a minimum driver
  version and check it at open.
- The DLL is closed and is FTDI's to distribute.

**C. Both**, as on Linux: B as the default because it needs no setup, A for those who
install WinUSB. Twice the testing on a system with the least testing.

**Decided with the owner (2026-11-26): B.** dimna on Windows uses FTDI's DLL, so that it
works beside the Open Ephys GUI with no driver switching. The GUI's Windows setup binds
the board to FTDI's kernel driver (`FTDIBUS3.sys`): its driver page asks for the "FTD3XX
driver", and liboni's FT600 driver has a workaround named for that driver line's 1.3.0.8
(not seen in Device Manager on a real machine). Switching to WinUSB and back needs
administrator rights each time, and Windows Update may undo it. What follows from B:

- `--driver d3xx` is the default on Windows, and at first the only transport there.
- `ft600.zig` and its guard are not used on Windows. `docs/hardware.md` must say that
  there the rule "no chip-configuration write" is a promise not to call
  `FT_SetChipConfiguration`, with a test that no source file names it.
- dimna states a minimum driver version (1.3.0.10, for the out-of-order fix) and checks
  it at open.
- Block timing and CPU use are measured again on Windows; the rig's `d3xx` figures do not
  carry over.
- Route A (WinUSB, dimna's own code) is not planned. It could be added later as an option
  for a dedicated machine, and `usb_windows.zig` is then the only new file it needs.

## What cannot be known before a Windows machine has the board

- Whether an aborted WinUSB read reports its bytes (route A).
- Block delivery time and CPU use without the pacing sleep.
- Sample-to-screen latency, fullscreen and in a window, and whether it can be reported
  by the system at all.
- Audio latency in shared and exclusive mode.
- Whether a ten-minute and then a multi-hour recording verifies with nothing lost while
  Windows does its own work in the background.

Until the last one is done, the line in `docs/platforms.md` for the Mac would apply to
Windows too: record animals on Linux.

## A possible order

Each step ends with something that can be shown, as the Mac port's did.

1. **Builds for Windows from the rig**: `os_windows.zig`, paths, test folders, the
   `fork` tests skipped. `zig build -Dgui=false -Dtarget=x86_64-windows` compiles. No
   Windows machine needed.
2. **Headless on the simulator**, on a Windows machine or CI runner: `dimna-headless
   --sim --record`, verified by `dimna_read.py`; the unit tests pass. The `current` link
   decision is needed here.
3. **Headless on the board**, through FTDI's DLL (route B). The first step that
   touches hardware, so under the owner's hand, with the registers written stated as for
   any board run (they are the same as on Linux).
4. **Window and Vulkan**: the display on the simulator, then the latency measurement.
5. **Text**, then **sound**.
6. **A soak and a recording compared against the rig's**, then packaging.

Steps 1 and 2 are a few days of agent work and risk nothing. With the Windows machine
available for one day only, the backends of steps 4 and 5 are also written and compiled
before that day ("The day on Windows"), and steps 2 to 5 are tried on it together.

## Step 1, as done (2026-11-27, branch `windows-port`)

`zig build -Dgui=false -Dtarget=x86_64-windows` on the rig makes `dimna-headless.exe`, and
the core's tests compile for Windows. **Nothing of it has run**: there is no Windows here
(and no wine), so every Windows call below is as its documentation reads. On Linux the
tests are as before (314 of 319 pass, 5 skipped, debug and `--release=safe`).

- `src/os_windows.zig`: the system calls, through kernel32. Three of them do less than
  Linux's and say so: `lockMemory` is always false; `unmap` of part of a mapping gives the
  memory back but keeps the addresses; `swapLink` makes `current` a junction (decided
  with the owner, 2026-11-27: it reads as the link does, where a text file would be one
  more thing a program has to know about), which holds its target's whole path and
  exists only on a local NTFS disk.
- `src/usb_windows.zig`: no USB backend, in the contract's shape: nothing is found and
  every call fails. `board.Driver.default` is `d3xx` on Windows.
- `os.zig` gained `DirHandle`, `onInterrupt` (Windows: Ctrl-C, the console closed, a
  logoff, a shutdown; `dimna-headless` uses it where it used SIGINT) and `tempDir` (the
  tests' folders, `/tmp` elsewhere). `keepAwake` is now also Windows's.
- The driver search looks for `libonidriver_ft600.dll` in `%ONI_DRIVER_PATH%` (semicolons)
  and beside the program.
- Local time: Windows' `struct tm` has no UTC offset; `c.h` works it out.
- liboni is unchanged. The build gives it a `Windows.h` that includes `windows.h` (file
  names differ by case on Linux) and lets clang pass an `int *` where Windows wants a
  `long *`, which MSVC only warns of.
- The two tests that `fork` are skipped on Windows.

Not done, and the first things to look at on Windows:

- whether it starts at all, and `--sim --record` verifies;
- paths: the recorder joins folders with `/`, which Windows' own calls accept and `std.Io`
  is assumed to;
- test buffers sized for `/tmp` paths: the ones holding the folder itself were enlarged,
  ones built from them may still be short for a long `%TEMP%`;
- `libonidriver_ft600.dll` itself: liboni's FT600 driver built for Windows against FTDI's
  library. Not attempted; FTDI's files are not in this repository.

## The day on Windows

The Windows machine is the rig, booted the other way. That shapes the work:

- **The rig records nothing that day**, and a session running on the Linux side is not
  there: whoever works on Windows (an agent included) starts there with this file and the
  branch, and nothing else.
- **So everything that can be done from Linux is done first**: every Windows backend
  written and cross-compiled here (`-Dtarget=x86_64-windows`), the display included, since
  headless alone is not the goal. The day is for what only Windows can show: does it
  start, draw, find the board, record, and how late is a frame.
- **MSVC is not needed.** Zig brings its own Windows toolchain and C library (the `gnu`
  target), and builds the C and C++ shims too. To check: linking liboni's FT600 driver
  against FTDI's `FTD3XX.lib` with it, or loading `FTD3XX.dll` at run time instead.
- **What the Windows side needs beforehand**: Zig 0.17.1 (a zip, no installer), git,
  Python with numpy for `dimna_read.py`, the GPU's current driver, FTDI's D3XX driver
  (1.3.0.10 or later; the Open Ephys GUI's installer brings one), and a folder for
  recordings with room in it. If the Linux disk is to be read from Windows, or the
  reverse, Windows' fast startup must be off, or the shared disk can be damaged.
- **The board**: the same registers as on Linux are written, through FTDI's DLL. No
  animal connected, and the owner's go as for any board run.

## Handoff (2026-11-27): the session moves off the tower

"The tower" is the rig's computer (a Dell Precision 3620; Linux hostname `gallbladder`). It
boots Linux or Windows. While it is in Windows, the work is run from another Linux host in
the office, which reaches the tower by ssh. This section is what a session starting on
that host needs; it has this repository and nothing else from the earlier conversations.
Read `docs/plans/README.md` first, then this file from the top.

### Where things stand

- Branch `windows-port`, two commits on top of `main`: step 1 (above) and the junction.
  Decisions made, all by the owner: FTDI's DLL through liboni (route B); the display is the
  goal, headless only a milestone; `current` is a junction on Windows; Vulkan with
  `VK_KHR_win32_surface`, not Direct3D 12.
- Nothing has run on Windows. Steps 2 to 6 of "A possible order" are open. Not written at
  all: the Win32 window backend, the Vulkan win32 surface, text, WASAPI sound, the GUI's
  signal handling and config paths (`%APPDATA%`), `VirtualLock` of the rings and the
  display history, `libonidriver_ft600.dll`, a `windows-latest` CI job.
- Open questions for the owner: 5 (text: DirectWrite or FreeType) and 6 (is "record
  animals on Linux, Windows for looking and bench work" an acceptable first state).

### Switching the tower

Read from the tower's firmware on 2026-11-27; the round trip has not been tried.

- Linux to Windows: `sudo efibootmgr --bootnext 0000 && systemctl reboot`. Entry 0000 is
  Windows Boot Manager. It applies to one boot and skips rEFInd.
- Windows to Linux: restart. The boot order has rEFInd first (entry 0003, on the Linux
  disk), which waits 20 s and takes its last choice, expected to be Linux since the boot
  into Windows went round it. A power cycle of a hung Windows should end the same way.
- If a Windows update has put Windows first: `sudo efibootmgr -o 0003,0000` from Linux, or
  rEFInd from the firmware's F12 menu.

### The working loop

- **On the office host**: a clone of this repository with `windows-port` checked out, and
  Zig 0.17.1. Build there: `zig build -Dtarget=x86_64-windows` (add `-Dgui=false` until the
  display backends exist), and `zig build test` for Linux, which must stay as it is
  (313 of 318 pass, 5 skipped; one test more with `-Dgit=false`).
- **On the tower in Windows**, set up by the owner: the OpenSSH server
  (`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, then
  `Start-Service sshd` and `Set-Service sshd -StartupType Automatic`, in an administrator
  PowerShell), git, Zig 0.17.1, and the rest of the list under "The day on Windows". The
  office host gets an ssh alias `tower` for it, by address.
- **Running**: either copy `zig-out/bin/*.exe` to the tower with `scp`, or keep a clone on
  the tower and run `zig build test --summary all` there over ssh; the second is the only
  way to run the unit tests. Use a folder under `%TEMP%` or one the owner names for
  recordings made in tests.
- **Windows cannot be opened over ssh**: a program started that way is not on the desktop.
  The owner starts the display and says what is seen, as on Linux.
- If this loop proves clumsy, the fallback is a Claude Code session on Windows itself,
  starting from this file.

### First things to do on Windows

1. `dimna-headless.exe --sim --record` into a test folder for a minute; Ctrl-C; check it
   with `tools/dimna_read.py`. Then the unit tests.
2. The list under "Step 1, as done", and these from `os_windows.zig`: that setting a target
   on a junction that exists replaces it; `keepAwake` and `allowSleep` called on the same
   thread; that `nowNs` (QueryPerformanceCounter) and `Io.Clock.awake` are one clock.
3. Device Manager with the board plugged in: which driver holds it (`FTDIBUS3.sys` is
   expected) and its version, 1.3.0.10 or later. Looking only; this opens nothing.
4. Only then, and on the owner's go: the board through FTDI's DLL.

### Rules that hold on every machine

- Never touch the board without the owner's go. Before a change that touches hardware,
  say which registers or devices it writes.
- During the owner's recordings: no board access and no windows. Before a board run, check
  that nothing else has it: on Linux `pgrep -x` for `oers`, `kalila`, `kalila-headless`,
  `headless`, `oez`, `oez-headless`, `dimna`, `dimna-headless`, and
  `pgrep -fa 'examples/headless|[o]pen-ephys'`; on Windows `tasklist` for the same names
  and `open-ephys.exe`.
- Do not open windows; the owner tries the display. No `--present fifo` on the rig.
- Commit and push only when asked. Commits carry the owner's name and the co-author line
  the earlier ones do.
- On the office host, write only inside this repository's clone and a scratch folder.
  Other folders in that home are other work and are read-only at most.
- `docs/upstream/` and `packaging/icon/candidates/kalila-*` in the tower's main checkout
  are untracked on purpose: not to be touched or committed. The kalila repository belongs
  to another session.
- The rules for agents in `docs/plans/README.md`: `--sim` only unless told otherwise,
  temporary files in a temp folder, break every tested property once on purpose,
  `zig fmt --check src build.zig` clean.

## Questions for the owner

1. Answered (2026-11-26): labs that run the Open Ephys GUI on Windows and try dimna
   beside it, so route B.
2. Answered (2026-11-27): a headless recorder alone is not useful on Windows. The display
   is the point; headless is only the first thing that can be shown to work.
3. Answered (2026-11-27): the rig itself (gallbladder), which also boots Windows, for a
   day. See "The day on Windows".
4. Answered (2026-11-27): a junction. Linux keeps its link; no text file anywhere.
5. Text: DirectWrite (nothing to ship) or FreeType built in (less new code)?
6. Is "record animals on Linux; Windows for looking and for bench work" an acceptable
   first state, as it is for the Mac?

## Sources for the Windows facts

- FTDI, D3XX drivers (the `FTDIBUS3.SYS` and WinUSB packages):
  <https://ftdichip.com/?p=706>
- FTDI, D3XX driver 1.3.0.10 release notes (the out-of-order fix):
  <https://ftdichip.com/wp-content/uploads/2024/06/FTD3XXDriver_WHQLCertified_v1.3.0.10-ReleaseNotes.pdf>
- FTDI, AN_385 D3XX installation guide (the driver stack):
  <https://www.ftdichip.com/old2020/support/Documents/InstallGuides/AN_385%20FTDI%20D3XX%20Driver%20Installation%20Guide.pdf>
- Microsoft, `WinUsb_ReadPipe` and `WinUsb_GetOverlappedResult`:
  <https://learn.microsoft.com/en-us/windows/win32/api/winusb/nf-winusb-winusb_getoverlappedresult>
- A report of Windows replacing a WinUSB binding (probe-rs):
  <https://www.github.com/probe-rs/probe-rs/pull/2106>

The version numbers of FTDI's WinUSB package (1.4.x) come from driver-listing sites, not
from FTDI's own release notes, and should be read from ftdichip.com before they are
relied on.
