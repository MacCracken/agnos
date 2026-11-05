# 2026-10-30 — A terminal emulator's channel has no window size, so a program in puka can only learn the console's grid

**Status:** ✅ **RESOLVED in agnos 1.57.17** (operator decision 2026-11-04: the issue's first proposal — two ops in
`#97`'s band, no new syscall number). **`CH_WINSZ_SET` (op 0x06, caps bit 6)** on the emulator's OWN, non-terminal end
sizes its PEER — a terminal end, or one the emulator still owns, so a size set before `CH_ENDOW` + spawn is there when
the child is born — with one word `(xpix<<48)|(ypix<<32)|(cols<<16)|rows` (the pixel size is carried; 0 = unknown);
**`CH_WINSZ_GET` (op 0x07, caps bit 7)** on a PTY-mode end the caller may use answers `(cols<<16)|rows` (sel 0,
`winsize`#60's packing) or `(xpix<<16)|ypix` (sel 1), **-1** for any other fd — a display channel, an inert inherited
copy, the emulator's own end, a non-channel fd — or before any SET. A SET that changes the word posts **SIGWINCH 28**
to the terminal's holders (owner + PTY descendants holding it, by `chan_auth`) that watch bit 28; an unchanged size is
silent. `CH_OP_SUPPORTED` 0x3F → 0xFF. The size dies with the endpoint (zeroed at mint / `CH_CLOSE` / the owner's death).
`winsize`#60 and `fd_kind`#111 unchanged. Kernel: `kernel/core/syscall.cyr` (`chan_winsz[]`, `chan_auth_as`,
`chan_holds`, `chan_winch_post_locked`, `chan_winsz_set`, the two op arms). ABI: `agnos-userland-abi.md` row 97 + § 4.9.
**Proven** by `scripts/smoke/pty-winsize-smoke.sh` (`tests/chan/ptyws.cyr` as /bin/agnsh, plain kernel): 38/38 at
`-smp 1` + `-smp 4` — 13 phases (not-terminal fds, display channel, before-set, owner + grandchild GET 100×30 /
800×480 px, SET refused from inside the terminal and from a display client, PEERGONE after the owner's death, SIGWINCH
0,1,0,1,1 over same / change / same / pixels-only / change to the watching holder, none to a non-watching holder or a
non-holding watcher, a recycled terminal unsized); mutation-proven (GET without the PTY test, a post on every SET, a
post to every watcher — each red). The ring-3 peer (`CH_WINSZ_*` + `sys_chan_winsz*` wrappers) is filed in cyrius:
`cyrius/docs/development/issues/2026-11-04-agnos-chan-winsz-ops-peer.md`. puka / darshana / bannermanor adopt it in
their own repos. *(Was: 🟡 OPEN — puka already names the gap, "NO WINDOW SIZE. There is no TIOCSWINSZ equivalent …",
`puka/src/pty.cyr:290-292`; this file records the consumers it blocks.)*
*(Filed from bannermanor **1.9.0**: its roadmap item "terminal-emulator windows on AGNOS" is gated on this. Found
by reading the code, not in a QEMU run: nothing below was measured inside puka.)*
**Checked against:** agnos **bdc587d7** (kernel source unchanged since 1.57.14) — `winsize`#60 takes no argument and
answers the framebuffer console's grid (`kernel/core/syscall.cyr:12386`); `fd_kind`#111 answers `5` CHAN for every
`#97` endpoint, a PTY one or a display one; the kernel itself tells them apart (`chan_end_pty[]`,
`kernel/core/syscall.cyr:6364`). puka **0.6.25**: an 80 × 24 grid (`src/main.cyr:65-66`), and on agnos
`pty_set_winsize` is `return 0` (`src/pty.cyr:312`). darshana **1.7.0**: AGNOS `tty_winsize(fd)` reads `winsize`#60
whatever `fd` is, and `tty_isatty(fd)` is 1 for `FDK_CONSOLE` or `FDK_CHAN` (`src/termios.cyr:831`, `:920`).
**Severity:** feature gap, low. Nothing breaks or is lost. Output in a puka window is sized for the wrong screen.

## What happens

On Linux a terminal emulator sets its window size on the PTY master (`TIOCSWINSZ`), and a program asks for it on the
fd it holds (`TIOCGWINSZ` on fd 1). It gets the window it is drawn in, and `SIGWINCH` when that changes. The same call
also answers "is this fd a terminal at all": it fails on a file, a pipe or a socket.

On agnos a program in puka holds a `#97` endpoint endowed in PTY mode at fds 0/1/2. The only size it can ask for is
`winsize`#60, which is the console's. puka's window is 80 × 24. The console is wider: 125 columns in bannermanor's
1.7.0 QEMU run. So, by construction:

- **darshana consumers** (kii, cyim, chakshu and darshini each call `tty_winsize`) lay out for the console's grid
  inside an 80-column window. darshana counts the channel as a terminal (`tty_isatty` → 1), so those that gate on it
  decorate as well. darshana's own 1.6.0 notes say it: `tty_winsize` "on AGNOS reports the console's grid even on a
  terminal emulator's channel".
- **bannermanor** (`bnrmr`) chose the other side: it counts an `FDK_CHAN` stdout as *not* a terminal (its ADR 0004),
  so in puka it writes no color and does not cut the banner to the window. A banner wider than 80 columns wraps.
  Counting the channel would be worse today: it would cut to the console's width, not puka's.
- **No program can tell a PTY endpoint from a display channel.** `fd_kind` gives `5` for both, so "is fd 1 a
  terminal?" has no right answer from ring 3 when it is `5`. darshana answers yes for both. bnrmr answers no for both.

Resizing is the same gap: `SIGWINCH` (28, since 1.57.13) is raised for the console's grid only.

## The fix (agnos's call)

A window size that belongs to the PTY endpoint, set by the emulator and read by whoever holds the endpoint. For
example, two `#97` ops in the op-dispatched band (no new syscall number, a caps bit each):

- **set**, on the emulator's end (the endpoint's owner): `cols`, `rows`, and optionally the pixel size. puka's agnos
  `pty_set_winsize` would call it where it now returns 0.
- **get**, on a PTY-mode endpoint (the owner's descendants hold it, `chan_end_pty`): the same packing as
  `winsize`#60, `(cols << 16) | rows`, or `-1` when the fd is not a PTY endpoint or no size was ever set. That `-1`
  also answers the terminal question above, as a failing `TIOCGWINSZ` does on Linux.
- **Resize**: when the emulator sets a size that differs, post `SIGWINCH` 28 to the endpoint's holders that watch it
  (the console's rule from 1.57.13: watchers only, and an unchanged size stays silent).

A per-fd `winsize` under a new number (`winsize_fd(fd)`) would serve the readers equally well. The emulator still
needs a way to set it.

## What each consumer does once it exists

- **darshana**: the AGNOS arm of `tty_winsize(fd)` asks the endpoint when `fd_kind(fd) == 5`. Its roadmap lists "an
  AGNOS arm that becomes real when agnos grows the mechanism" as always eligible. `tty_isatty(fd)` could then count a
  PTY endpoint and not a display channel. `tty_winsize_px` could report the pixel size if the set op carries one.
- **puka**: `pty_set_winsize` on agnos stops being a stub, and its 80 × 24 reaches the child. Once its window can
  change size, it sets the new grid.
- **bannermanor**: counts a PTY endpoint whose size it can read as a terminal: color and the width cut, as on the
  console. Its roadmap item "route the AGNOS probe through darshana" is decided once darshana draws the same line.
