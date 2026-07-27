# cyrius/AGNOS — agnos syscall peer omits signal-number constants (`SIGHUP`, …): `t-ron` fails to link on `--agnos`

**Status**: ✅ **RESOLVED — cyrius added the signal constants (closed 2026-06-30, archived).** `cyrius/lib/syscalls_x86_64_agnos.cyr` now defines the signal-number enum with the POSIX/Linux numbering the agnos kernel uses — `SIGHUP=1`, `SIGINT=2`, `SIGTERM=15`, `SIGCHLD=17`, … plus `SIG_BLOCK` and `SFD_NONBLOCK` (with a "agnos kernel uses POSIX/Linux numbering" comment confirming the values). So `sigset_add(mask, SIGHUP)` resolves on `--agnos` and t-ron/thoth's `--agnos` lane links — zero downstream change, exactly as predicted. (Original status below: *Filed — BLOCKS a downstream consumer's AGNOS target; the signal infrastructure exists, only the userland number constants are missing from the cyrius peer.*)
**Date**: 2026-06-23
**From**: thoth (the agentic-coding TUI) — found cross-verifying its `--agnos` lane on cyrius **6.2.37**.
**Affects**: `cyrius/lib/syscalls_x86_64_agnos.cyr` (the cyrius stdlib's agnos syscall
peer) — and, for value confirmation, `agnos/docs/development/agnos-userland-abi.md`.
**Related**: [`2026-06-16-cyrius-patra-lseek-syscall-gap.md`](2026-06-16-cyrius-patra-lseek-syscall-gap.md)
— same shape (a cyrius agnos-peer omission surfaced as a downstream link error); that
one is now RESOLVED (the 6.2.37 agnos peer defines `SYS_LSEEK=58` + `SYS_GETRANDOM=45`),
which is precisely why thoth's `--agnos` lane now advances far enough to hit *this* gap.

## Summary

AGNOS's **signal infrastructure is DONE** — the agnos peer already defines
`SYS_KILL=16`, `SYS_SIGPROCMASK=17`, `SYS_SIGNALFD=18` (with `sys_sigprocmask` /
`sys_signalfd` wrappers), and `syscall-additions.md` documents the `proc_signals[pid]
|= (1 << sig)` model with the standard signal *names* (SIGCHLD reaping, SIGTERM/SIGINT
shutdown, SIGPWR/SIGHUP power management). What's missing is the userland
**signal-number enum** — `SIGHUP`, `SIGINT`, `SIGTERM`, `SIGCHLD`, … as named
constants — which the Linux/macOS/aarch64 peers all define (`syscalls_x86_64_linux.cyr`:
`SIGHUP=1 … SIGPWR=30`) but `syscalls_x86_64_agnos.cyr` does not.

Because the bare `SIGHUP` constant is undefined on the AGNOS target, this is a
**compile-time link failure**:

```
$ cyrius build --agnos src/main.cyr build/thoth_agnos
error:src/vendor/t-ron.cyr:3436: undefined variable 'SIGHUP' (missing include or enum?)
FAIL
```

The offending consumer call (t-ron's signalfd-based policy hot-reload):

```cyr
fn sighup_init() {
    var mask = sigset_new();
    sigset_add(mask, SIGHUP);                 # <-- SIGHUP undefined on the agnos peer
    var rc = sys_sigprocmask(SIG_BLOCK, mask, 0);
    ...
    return sys_signalfd(0 - 1, mask, SFD_NONBLOCK);
}
```

Note the *mechanism* (`sys_sigprocmask` / `sys_signalfd`) resolves fine on agnos — only
the signal-number literal is missing. This is the same class as the Windows getrandom
gap (peer provides the mechanism but omits the constant), fixed downstream where a
wrapper exists; here the right home is the **floor**, since the other peers define the
signal numbers and agnos's signal model is Linux-shaped.

## Dependency chain (why thoth hits it)

```
thoth  →  t-ron (per-tool MCP authorization)  →  t-ron signal.cyr `sighup_init`
       →  sigset_add(mask, SIGHUP)  →  bare `SIGHUP`  ← undefined on the AGNOS peer
```

t-ron uses SIGHUP for policy hot-reload (block SIGHUP process-wide, route it to a
signalfd, reload the policy on drain). thoth itself needs **zero change** — its
`--agnos` lane lights up the instant the agnos peer defines the signal constants.

## Asked of cyrius/AGNOS

Add the signal-number constants to `cyrius/lib/syscalls_x86_64_agnos.cyr`, mirroring the
Linux peer's enum, **with the values AGNOS actually uses**. Given agnos's `1 << sig`
model and exclusive use of the Linux signal *names*, these are almost certainly the
POSIX/Linux numbers (`SIGHUP=1`, `SIGINT=2`, `SIGTERM=15`, `SIGCHLD=17`, `SIGPWR=30`, …)
— but the AGNOS ABI owner should confirm the numbering rather than have a downstream
guess it (the same care that distinguishes agnos `getrandom`#45 from Linux #318). Once
the constants land, the lane builds with no thoth/t-ron change.
