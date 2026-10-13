# 2026-10-12 — Ring 3 cannot change the console line discipline: no echo-off for a password prompt, no input flush

**Status:** 🟡 **OPEN** — filed from darshana **1.3.0**, whose AGNOS `tty_echo_off` and `tty_flush_input` return -1 for want of it.
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
