# 2026-10-12 — A live modeset changes the console grid, but no running program is told: the kernel never raises SIGWINCH

**Status:** 🟡 **OPEN** — filed from darshana **1.2.0** (the 1.1.4 audit of its AGNOS signalfd peers).
**Checked against:** agnos **1.57.11** — `kernel/arch/x86_64/fb_console.cyr` (`fb_set_geom` :452,
`fb_width`/`fb_height` :470/:476, `fb_scale` :657, `fb_winsize` :673), `kernel/core/syscall.cyr`
(`mdo_native`, the success path ~7407; `winsize#60` arm; `gpu_modeset_op#93` → `gpu_modeset_op_sys` ~11079),
`kernel/core/proc.cyr` (`SIG_*` :198-202), `kernel/core/sched.cyr` (`proc_sig_locked` ~1651).
**Severity:** correctness, low. Nothing is corrupted; a full-screen program keeps drawing to the old grid
after a modeset until it happens to re-read `winsize#60`.

## What happens

The console grid is not fixed for the life of a boot:

- `winsize#60` answers `fb_winsize()`, which derives cols × rows from `fb_width()`, `fb_height()` and
  `fb_scale()` — and `fb_scale()` itself depends on the height (scale 2 above 1200 lines).
- `fb_width()` / `fb_height()` return the `fb_geom_*` overrides once `fb_set_geom` has set them, and
  `fb_set_geom` is called on a **live modeset**: `mdo_native()`'s success path does
  `fb_set_geom(t_w, t_h, t_pitch * 4); fb_console_clear();` ("Move the console to the geometry that is now
  live"). That path is reachable at runtime through `gpu_modeset_op#93` (`/bin/modeset`, behind the H2
  arm-once latch), as well as at boot. `gpu_scanout_matchgeom` also calls `fb_set_geom`, from "an early AND a
  late call site".

So after a modeset, every subsequent `winsize#60` returns a different grid. But nothing tells a program that
is already running. The kernel posts a pending signal from exactly three places — `kill#16`
(`proc_sig_locked`), SIGCHLD at a child's death, and SIGCONT — and defines no SIGWINCH (`proc.cyr` names
only `SIG_KILL`, `SIG_CHLD`, `SIG_CONT`, `SIG_STOP`, `SIG_XCPU`). Confirmed by reading.

## Who it affects

darshana's AGNOS `tty_open_signalfd` accepts `TTY_SIGMASK_WINCH` (`1 << 28`) exactly as on Linux, and its
consumers open one to learn of a resize — chakshu holds an EXIT and a WINCH signalfd at once; cyim and thoth
watch WINCH too. On agnos that fd opens and never fires. Since darshana 1.2.0 its docs tell consumers to
**poll `tty_winsize`** on agnos instead; this issue is the kernel half.

## The fix (agnos's call)

Raise SIGWINCH (28) when the console grid actually changes — at the end of `fb_set_geom`, or wherever the
modeset commits, comparing the old and new `fb_winsize()` so an unchanged grid stays silent.

⚠ **Who receives it matters.** Under agnos's D3 rule a signal is "a bit, no default action", and `pause#14`
returns immediately while a deliverable signal is pending. A SIGWINCH bit posted to every process would
therefore stay pending forever in every process that never consumes it, and turn each of their `pause#14`
loops into a spin. Two shapes avoid that:

- **Proposed:** post bit 28 only to processes holding a signalfd whose mask includes it (the consumers that
  asked), via the existing atomic OR.
- **Alternative:** give SIGWINCH a "discard when not watched or blocked" disposition at post time.

## Related observation (not a defect claim)

No console key raises a signal either: there is no SIGINT, SIGTERM or SIGHUP constant, and no keyboard path
posts one, so a Ctrl-C at the console reaches a program only as whatever byte its line read delivers. That is
an agnos design choice rather than a bug, recorded because darshana's `TTY_SIGMASK_EXIT` (HUP | INT | TERM) can
therefore only ever see a `kill#16` on agnos — never an interactive interrupt. If agnos grows console job
control, the same "deliver only to watchers" question applies.
