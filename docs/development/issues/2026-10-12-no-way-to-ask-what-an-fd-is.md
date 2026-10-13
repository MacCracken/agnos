# 2026-10-12 — Ring 3 cannot ask what an fd is: there is no `fstat` or fd-kind query, so `isatty(fd)` can only report whether the console is up

**Status:** 🟡 **OPEN** — filed from darshana **1.3.0** (its AGNOS `tty_isatty` has answered for the console rather than
the fd since v0.9.0).
**Checked against:** agnos **1.57.11** — `docs/development/agnos-userland-abi.md`'s syscall table: `stat#33` and
`lstat#102` take a **path**; no call takes an fd and reports what it is.
**Severity:** feature gap, low. Output that should be plain text gets terminal escapes when it is redirected.

## What happens

A Linux program asks `isatty(1)` — `TCGETS` or `TIOCGWINSZ` on the fd — to decide whether to emit colors, cursor
moves and alt-screen switches, or plain text. agnos has no ioctl and no call that reports an fd's kind, so darshana's
AGNOS `tty_isatty(fd)` uses the one signal available: `winsize#60` succeeds when the framebuffer console is up. That is
a fact about the console, not about the fd. With the console up, **every** fd answers 1, so on agnos:

- `prog > file` writes escape sequences into the file.
- `prog | other` sends them down the pipe or channel.

A program cannot tell these apart from writing to the screen, so it cannot degrade the way it does on Linux.

## The fix (agnos's call)

A call that takes an fd and returns its kind, minted under a new number. For example `fdkind(fd)` → console / file /
pipe / channel endpoint / tagged socket, or `-1` for a closed fd. Or an `fstat` that fills the §4.1 stat struct with a
type field. Either lets darshana's AGNOS `tty_isatty(fd)` answer per fd, as its Linux peer does; the kernel already
distinguishes these internally (`chan_fd_endpoint`, the pipe table, the vfs).
