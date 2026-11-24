# Plan: the core and `dimna-headless --sim` on macOS (macOS port, step 7)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview; this is
its step 7, taken before steps 4 to 6 because it needs only steps 1 to 3, which are done).
This is the first step that adds macOS code. On Linux nothing may change: same program,
same instructions on the paths that matter.

## Where you work

On the owner's Mac (Apple silicon, macOS 27), in the git worktree you were started in, on
its own branch off `macos-port`. Zig 0.17.1 is
`~/.local/opt/zig-aarch64-macos-0.17.1/zig` (not on `PATH`). There is no board on this
machine and you may not look for one: nothing in this step opens, claims or sends anything
to a USB device. No windows: the GUI is not built here (`-Dgui=false` throughout).
Temporary files go in a new folder under `/private/tmp` with your process id in its name,
removed at the end (README rule 3's `/tmp`; recordings of a minute or two are fine there).
Do not use SSH; the rig is someone else's job. Do not install anything system-wide (no
Homebrew, no `sudo`); a Python virtual environment inside your temporary folder is fine if
`tools/dimna_read.py` needs numpy.

## Why

Steps 1 to 3 put the build, the operating system's calls and USB behind seams:
`zig build -Dgui=false`, `src/os.zig` (with `os_linux.zig`), `src/usb.zig` (with
`usb_linux.zig`). On the Mac both seams end in `@compileError`. This step fills them in so
that the core's tests pass on macOS and `dimna-headless --sim` records there. The board on
the Mac (IOKit) is the next step, not this one.

## What is known already

`macos-port.md`, "What Zig 0.17.1's standard library does on macOS", was read from std's
source and proved with small programs on this Mac. In short: `Io.Clock.awake` is
`CLOCK_UPTIME_RAW` here; `File.sync` is a plain `fsync` and does not flush the drive's
cache; `std.c` has `getpid`, `mmap`/`munmap` (through `std.posix`), `mlock`, `nanosleep`,
`clock_gettime`, `sigaction`, `fcntl` with `F.FULLFSYNC` and `F.BARRIERFSYNC`,
`pthread_set_qos_class_self_np`, `mach_absolute_time`; it lacks `statfs`,
`thread_policy_set`, `clock_gettime_nsec_np` (declare what you need as `extern "c"`). Most
`std.os.linux` calls compile for macOS and silently do the wrong thing, which is why
`os.zig`'s test searches the sources for them.

## What to build

1. **`src/os_darwin.zig`**, chosen by `os.zig` for `.macos`: every function `os.zig`
   offers, with the meaning its doc comment gives.
   - The clock: the one `Io.Clock.awake` reads (`clock.zig`'s test is the check, and must
     pass here).
   - Sleeps: `nanosleep`, retried or not as the two functions say.
   - `setThreadRealtime`: macOS has no `SCHED_FIFO` for ordinary processes. Use what it
     has for a thread that must run promptly and briefly, many times a second: the
     user-interactive QoS class (so it stays off the efficiency cores) and a Mach
     time-constraint policy. Choose the period, computation and constraint from what the
     acquisition thread does (a block every 1 to 2 ms, a fraction of a millisecond of work;
     read `acquisition.zig` and `oni_usb.readStream`) and say why. `priority` has no
     meaning here; say so in the comment. `setThreadIdle`: the background QoS class.
     Neither is reached by the simulator (`wantsRealtime` is false), so prove them with a
     test that calls each on a thread of its own and checks what the system then reports
     for that thread.
   - `lockMemory`: macOS has no `mlockall`. Return false, as the comment in `os.zig` allows
     ("False if refused"); do not pretend. What to lock instead (the ring) is the board
     step's question; note it in your report.
   - `freeBytes` (`statfs`, macOS's struct), `mapZeroed`/`unmap`, `swapLink`, `getpid`, the
     file calls.
2. **Syncing to the disk, for real.** The recorder's promise ("once a second
   `samples.i16` is synced, then the index records for it") rests on `sync` reaching the
   disk. On macOS that takes `fcntl(F_FULLFSYNC)`. Add one function to `os` for "make this
   file's data durable" and use it where `record.zig` syncs: on Linux it must be the very
   call made now (`file.sync(io)`), on macOS `F_FULLFSYNC`, falling back to `fsync` where
   the filesystem refuses it (say which errors). **Measure before settling**: on this
   Mac's internal disk, a `--sim` recording of 60 s each way (`fsync` only, and
   `F_FULLFSYNC`), and report `max sync`, the recorder's backlog, and whether anything was
   dropped. If `F_FULLFSYNC` once a second on five files costs so much that the recorder
   falls behind, stop and report the figures instead of choosing (`F_BARRIERFSYNC` is the
   middle way; measure it too).
3. **Staying awake.** A Mac sleeps when idle and throttles programs it thinks are idle
   (App Nap). While acquisition runs, dimna must hold a power assertion that prevents idle
   sleep (IOKit's `IOPMAssertionCreateWithName`; the frameworks are linked for macOS
   targets only, in `build.zig`). One pair of functions in `os` ("keep the machine awake",
   "let it sleep"), called where acquisition starts and stops; on Linux they are empty and
   must compile to nothing. Show with `pmset -g assertions` that the assertion is there
   during a `--sim` run and gone after it, also when the run is interrupted. It does not
   stop a closed lid from sleeping the machine; say so in the docs.
4. **`src/usb_darwin.zig`, a stand-in**, chosen by `usb.zig` for `.macos`: the declarations
   the contract in `usb.zig` lists, with `find` returning 0 (so opening the board fails
   with `NotFound`, as with no board plugged in) and every `Device` function failing
   without doing anything. It must not link or call IOKit's USB interfaces. `ft600.zig`'s
   tests must pass with it (one builds its device as `.{ .fd = -1 }`; give the stand-in
   what that needs and note it for the real backend).
5. **`record_test.zig`'s write-failure test** uses Linux's `fork`, `dup2`, `wait4`, `kill`
   to run a scenario that logs an error in a child process. Make it run on macOS too if it
   can be done honestly (`std.c` has the same calls; but the child of a threaded process
   may be restricted on macOS: try it, and if it is flaky, say so). If it cannot, skip it
   on macOS with a message and write in your report that the write-failure path is then
   untested here. On Linux the test must still run and still be able to fail.
6. **Ctrl-C** (`headless.zig`'s `sigaction`): check that an interrupted `--sim` run on the
   Mac finishes its recording properly (`[final]` in `meta.toml`, `dimna_read.py` says
   complete). Change `headless.zig` only if it does not.
7. **`build.zig`**: whatever a macOS target needs for `-Dgui=false` (the frameworks). With
   a macOS target and the GUI not switched off, fail at once with a sentence saying the GUI
   is not ported yet, instead of failing in `pkg-config` or a header.
8. **`docs/install.md`**: a short section "macOS (so far: the simulator, no window, no
   board)": how to get Zig, the build command, what works and what does not yet.

## Linux must not change

You have no Linux machine, but Zig cross-compiles: `zig build -Dgui=false
-Dtarget=x86_64-linux-gnu --release=safe --prefix <dir>` builds the Linux `dimna-headless`
on the Mac. Build it from the tree before your change and after, and compare as step 2's
and step 3's reports did (`objdump -d` here is LLVM's and reads ELF; normalise addresses
and compiler-numbered names): no function added or removed, and the same instructions in
every function, or each difference shown and explained. In particular `record.zig`'s
recorder functions (the sync), `Acquisition.start`/`run`/`stop` (the keep-awake calls) and
everything under `os`. The lead runs the tests and a board soak on the rig before this is
merged.

## Evidence

1. On the Mac: `zig build test -Dgui=false --summary all` passes; give the count and name
   every test that is skipped on macOS and why. `os.zig`'s search test and `ft600.zig`'s
   control-transfer tests are among those that pass.
2. `zig build -Dgui=false --release=safe`, then `zig-out/bin/dimna-headless --sim 32,16
   --seconds 60 --record <tmp>`: `CLEAN`, exit 0; `tools/dimna_read.py` says `OK`. The
   once-a-second lines' `lat` and `delivery` figures, for the record (the simulator's
   timing on this machine).
3. The three sync measurements of item 2, side by side.
4. `tools/crash-test.sh` (read it first; if it needs Linux-only tools, say which, and do
   the same by hand: record from the simulator, `kill -9`, verify the indexed part).
5. Ctrl-C (item 6) and the power assertion (item 3), with the commands' output.
6. The Linux comparison above.
7. `zig fmt --check src build.zig` prints nothing.

Break it on purpose, once each: make `os_darwin.nowNs` read `CLOCK_MONOTONIC` and see
`clock.zig`'s test fail (if it does not, say so: on this machine the two clocks differ by
days, so it should); put a raw `std.os.linux.getpid()` in a core file and see `os.zig`'s
test fail on the Mac; make the durable sync a no-op and say which test notices, or that
none does.

## Files you may change

New: `src/os_darwin.zig`, `src/usb_darwin.zig`. Changed: `src/os.zig`, `src/usb.zig`,
`src/record.zig` (the sync calls only), `src/acquisition.zig` (the keep-awake calls only),
`src/record_test.zig` (the write-failure test only), `src/headless.zig` (only if item 6
needs it), `build.zig`, `docs/install.md`. A test that fails on macOS because it assumes
Linux (a path, a tool) and lives in another file: do not edit that file; list the test and
what it assumes. Anything else: stop and report.

## Done means

The evidence and the break-it results are in your report, with the commands and what they
printed; your recommendation on the sync, with its figures; the list of what the board
step inherits (real-time parameters untested under load, memory locking, the `.fd = -1`
stand-in); the work committed on your branch (rule 5's identity and the `Co-Authored-By`
line for the model you are), the branch named in the report, not pushed; the worktree
clean; your temporary folder gone.
