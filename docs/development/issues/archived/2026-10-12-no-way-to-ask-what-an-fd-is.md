# 2026-10-12 — Ring 3 cannot ask what an fd is: there is no `fstat` or fd-kind query, so `isatty(fd)` can only report whether the console is up

**Status:** ✅ **RESOLVED in agnos 1.57.13** — `fd_kind#111(fd)` → `1` CONSOLE · `2` FILE (initrd, ext2, FAT/exFAT
write-back, ZFS) · `3` DIR (ext2, ZFS) · `4` PIPE (either end) · `5` CHAN (a `#97` endpoint) · `6` SOCKET (a kernel
`VFS_SOCK` fd) · `7` SIGNALFD · `8` EPOLL · `9` TIMERFD · `10` DEVICE (another character device; none today) · `-1` a
closed fd, `fd < 0` or `>= 32` — including the cyrius stdlib's TAGGED socket handle (`AGNOS_SOCK_TAG | slot`), which is
a userland adapter over conn ids, not a kernel fd (the adapter knows its own sockets). Prior art: `fstat`'s
`st_mode & S_IFMT` and `isatty(3)`; agnos keeps its own enum because it has kinds POSIX folds together (a channel
endpoint, the three event fds). darshana's `tty_isatty(fd)` can answer `fd_kind(fd) == 1` per fd (whether a channel
endpoint is a terminal band is the caller's call). **Evidence:** `scripts/smoke/tty-smoke.sh` T6 (`-smp 1` + `-smp 4`):
fds 0/1/2, an ext2 file, an ext2 directory (`AO_DIRECTORY`), both pipe ends, a closed pipe end, signalfd/epoll/timerfd,
and -1, 32, 99, `0x40000000`; T11 a kernel memfile (`/fonts/default.ttf`, `VFS_MEMFILE` — the initrd's tag) = 2;
mutation M-TTY4 (a pipe reported as a file) red. **What it broke — the 1.57.13 review:** the number itself is
read-only, but it ADVERTISES fds 1/2 as CONSOLE ("the cooked keyboard line on read"), and a read of console fd 1/2 never
reached the cooked line: it fell to `serial_dev_read`, whose no-key wait was a hlt at IF=0 in syscall context — the
CPU never woke. Fixed in the same cut: read#5 routes every console fd (`fd_is_console`) to the owner- and
mode-aware cooked readers, and x86 `serial_dev_read` is `kbd_read_blocking` (tty-smoke T10, mutation M-TTY7 red: the
box wedged at the fd-1 NB read). Not gated here for want of a fixture in this row: ZFS file/dir, FAT/exFAT
`VFS_SEC_WFILE`, CHAN and SOCK fds (their tags are mapped in `fd_kind_sys`).
*(Filed from darshana **1.3.0** — its AGNOS `tty_isatty` had answered for the console rather than the fd since v0.9.0.)*
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
