# 2026-10-12 — Ring 3 cannot change the console line discipline: no echo-off for a password prompt, no input flush

**Status:** ✅ **RESOLVED in agnos 1.57.13** — `console_mode#110(set, clear)` → the previous flags / -1 (a new
number, as the roadmap rule requires). **`CM_NOECHO` (1)** is a mode: the three console line readers (the CPU-holding
read, the waiting read, the NB accumulator — on fd 0 or any console fd) store and edit as before but echo nothing — no
printable byte, no `BS SP BS`, and no newline (Linux `n_tty` with ECHO and ECHONL clear — darshana's `tty_echo_off`
clears both and kybernet's `_prompt_password` writes its own `"\n"`); the hidden Enter still ends the operator's
framebuffer line (`fb_line_end`). **`CM_FLUSH` (2)** is an action (`set` only): it pulls the xHCI ring in, then empties
`kb_buf` and the NB partial line (`tcflush(TCIFLUSH)`; NOECHO|FLUSH in one call is `TCSETSF`), holding the line for the
flush only. Unknown bits → -1. **The mode is the CONSOLE's, held by its setter** (`syscall.cyr` above `kbd_mode_now`):
it applies to whoever reads (the setter's child included — `sudo`'s shape), never takes, keeps or waits for the line,
and dies with its holder (`kbd_line_release_pid`, from `proc_death_release` — every death path, a death at the timer
tick included: that runs `proc_death_release` in the ISR, and only the orphan / zombie reap is owed to a process
context; a stale-epoch holder, and since the 1.57.13 merge a DYING one whose death is done — `lc_dying_done`, gated by
`kstack-smoke`'s `tick orphan` phase — counts as no mode), so a program that dies with echo off never leaves the console dark for anyone after it (prior
art: Linux `n_tty` keeps ECHO in the tty and Plan 9 `rawon` in the console; Plan 9 `consctl` reverts when its holder
closes it, while Linux termios ECHO outlives its setter). **Evidence:** `scripts/smoke/tty-smoke.sh` T1–T5 and T9–T11
(`-smp 1` + `-smp 4`), the echo read off COM1 with a positive control and the framebuffer by screendump; ktest T8g;
wait-kbd K6 (a production kernel refuses the TTY_SELFTEST knob bits); mutations M-TTY1 (echo not suppressed), M-TTY2
(mode not cleared at the holder's death), M-TTY6 (the first cut's line-holding mode), M-TTY8 (no `fb_line_end`) each
red. **What it broke, and what the review found:** the first cut tied the mode to EXCLUSIVE line ownership ("MODE-OWN"
— a set mode kept the line owned until cleared, cited as "POSIX job control's shape"). It is not POSIX's shape (a
background `tcsetattr` is stopped by SIGTTOU, it does not take the terminal), and it let any process — a background job
included — seize the console from the shell for its whole life (agnsh's NB poll -2 forever, no Ctrl-C), and deadlocked
a holder's child that read the console. It also left the framebuffer line live after a hidden Enter (a ghost prompt
replayed under every later print), and the review found a read of console fd 1/2 hung the CPU (a pre-existing IF=0
hlt in `serial_dev_read`, made discoverable by `fd_kind`#111) and that FLUSH's new `kb_tail` store could make a
racing consumer step `kb_tail` past `kb_head` (255 old scancodes replayed). All four were fixed in the same cut,
before release. Raw (per-key) mode remains out of scope, as this issue left it.
**Checked against:** agnos **1.57.11** — `kernel/core/syscall.cyr`, the fd-0 line readers (the block comment at ~1117 and
the three echo sites: the CPU-holding read ~1443, the waiting read, and the non-blocking accumulator ~1538), and
`docs/development/agnos-userland-abi.md` (O1; the syscall table).
**Severity:** feature gap. Nothing is broken; a program that needs a secret typed at the console has no way to keep it
off the screen.

## What happens

`read#5` on fd 0 is the kernel's canonical-lite line discipline (ABI O1, revised 1.41.15): the kernel collects a whole
line, handles backspace, and **echoes every printable byte** as it arrives — `kputc(ch)` at each echo site, with no
condition on it. There is no call that changes that, and none that discards keys already queued in `kb_buf` or in
the non-blocking reader's partial line. So on agnos:

- **A password typed at the console is shown.** The reader cannot ask for echo off, the way a Linux program clears
  `ECHO` with `TCSETS`.
- **Typeahead cannot be discarded.** A program that asks "kill pid 1234? [y/N]" cannot drop keys pressed before the
  question, the way a Linux program issues `TCFLSH`/`TCIFLUSH`, so a stray `y` already in `kb_buf` answers it.

`roadmap.md` already carries this as a row — **`tcsetattr`/`ioctl` no-op stub** | *"May be needed by darshana-class TTY
tools. Distinct from `winsize`#60, which shipped — do not conflate."* | unslotted | waiting on: *a consumer*.
**darshana 1.3.0 is that consumer.** Its `tty_echo_off(fd)` and
`tty_flush_input(fd)` are Linux termios on Linux and return `-1` on agnos today, deliberately: a `0` would tell the
caller its password is hidden when it is not.

## Who it affects

- **kybernet** — the emergency shell's password prompt (`_prompt_password`, `src/main.cyr`) turns echo off with
  `TCSETSF` and, when that fails, logs *"could not disable echo - password will be VISIBLE"* and carries on; on the
  agnos console there is nothing that call could reach.
- **chakshu** — flushes typeahead before its kill-confirmation prompt on Linux, and skips it on agnos
  (`#ifndef CYRIUS_TARGET_AGNOS`).
- **shakti** — echo-off passphrase entry, Linux only.
- Any consumer of darshana's two new calls.

## The fix (agnos's call)

A new number rather than a widened arm (the roadmap's own rule: *"Mint a number; do not widen an arm"*) — for
example `console_mode(set, clear)` returning the previous flags:

- **`NOECHO`** — the line readers store and edit as now, but skip the `kputc` echo of printable bytes (and of
  backspace's `BS SP BS`), so a hidden line still edits.
- **`FLUSH`** — an action rather than a mode: empty `kb_buf` and the non-blocking reader's partial line.

⚠ **Whose mode it is matters.** If `NOECHO` were console-global, a program that dies between setting and clearing it
would leave the console echoing nothing for everyone after it. The line already has an owner (`kbd_line_*`, with a
dead owner reclaimed on every death path), so tying `NOECHO` to that owner — cleared when the owner releases the line
or dies — makes the failure mode the same one the kernel already handles.

Raw mode (per-key reads) is a separate question: ABI O1 records why whole-line reads were the only shape that worked
on iron when it was written (ring 3 ran IF=0 between syscalls). Whether 1.57.7's blocking-only-the-caller read has
lifted that is not claimed here. darshana's AGNOS `tty_raw` returns `-1` either way, and would wrap a raw switch if
one appeared.
