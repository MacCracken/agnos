# `sys_reboot()` is nullary but agnos syscall #13 now takes four arguments

**Filed**: 2026-07-19 · **Reporter**: agnos (kernel 1.55.25+) · **Severity**: medium — no crash today, but the
stale wrapper is a live foot-gun aimed at a power-control syscall.

Cross-filed in both repos per the agnos↔cyrius issue convention:
- `cyrius/docs/development/issues/2026-07-19-sys-reboot-nullary-vs-agnos-4arg-abi.md` (this file)
- `agnos/docs/development/issues/2026-07-19-sys-reboot-nullary-vs-agnos-4arg-abi.md`

## Summary

`lib/syscalls_x86_64_agnos.cyr` exposes agnos syscall #13 as a **nullary** wrapper:

```cyrius
var SYS_REBOOT = 13;                            # reboot() -> halts
fn sys_reboot(): i64 { return syscall(SYS_REBOOT); }
```

That matched the old kernel, where #13 was effectively a stub — it printed a line and called `arch_halt()`.

**agnos 1.55.25 replaced it with a real implementation** that runs an orderly shutdown (filesystem flush,
device quiesce across storage/net/USB/audio/GPU, then platform reset or ACPI S5 soft-off). The new signature
is:

```
reboot(magic1, magic2, cmd, arg)
    magic1 = 0x50575231   # "PWR1"
    magic2 = 0x50575232   # "PWR2"
    cmd    = 1 halt | 2 power off | 3 reboot
```

## Why this is worth fixing rather than ignoring

The cyrius `syscall()` builtin pops exactly the argument registers the **call site** names. A nullary
`syscall(13)` therefore leaves `rdi`/`rsi`/`rdx` holding **whatever the caller happened to have there** — so
every already-compiled consumer of `sys_reboot()` now delivers garbage into a syscall that can power off the
machine.

agnos deliberately guards against this rather than trusting callers: the magic pair exists precisely so that
garbage **fails closed** (returns `-1`, does nothing). This is the same reason Linux's `reboot(2)` carries
magic numbers, and it means **there is no correctness emergency** — a stale caller is inert, not dangerous.

But the wrapper is still wrong, and the current situation is that the only correct way to reach agnos's
power control from Cyrius userland is to bypass the stdlib and call by raw number. agnoshi 1.8.5 does exactly
that today:

```cyrius
syscall(13, 0x50575231, 0x50575232, 3, 0);   # reboot
```

That works, but every consumer re-deriving the magic constants is how they end up mistyped somewhere.

## Requested change

Widen the agnos wrapper to the four-argument form, and expose the constants so callers do not hand-roll them:

```cyrius
var SYS_REBOOT   = 13;
var PWR_MAGIC1   = 0x50575231;   # "PWR1"
var PWR_MAGIC2   = 0x50575232;   # "PWR2"
var PWR_HALT     = 1;
var PWR_OFF      = 2;
var PWR_REBOOT   = 3;

fn sys_reboot(magic1, magic2, cmd, arg): i64 {
    return syscall(SYS_REBOOT, magic1, magic2, cmd, arg);
}
```

Convenience wrappers (`sys_power_off()`, `sys_power_reboot()`) would be welcome but are not required — the
constants are the part that matters, since those are what get miscopied.

## Compatibility note

This is a **signature change to an existing wrapper**, so it is a breaking change for anything calling
`sys_reboot()` today. In practice the blast radius looks empty: the old wrapper only ever halted, so there is
little reason for existing code to call it. Worth a `grep` across the ecosystem before landing.

## Not a cyrius bug

To be explicit: nothing here is cyrius behaving incorrectly. `syscall()`'s pop-what-you-name behavior is
working as designed, and the wrapper was accurate when written. This is **agnos changing an ABI underneath a
stdlib wrapper**, and the follow-up belongs on the cyrius side only because that is where the wrapper lives.

## References

- agnos `kernel/core/power.cyr` — `power_sys()`, the magic gate and command codes
- agnos `kernel/core/syscall.cyr` — the `#13` dispatch row
- agnos `CHANGELOG.md` 1.55.25 (reset ladder + the #13 rebuild) and 1.55.26 (ACPI S5 soft-off)
- agnoshi 1.8.5 — `reboot` / `poweroff` / `halt` builtins, the current raw-number caller
