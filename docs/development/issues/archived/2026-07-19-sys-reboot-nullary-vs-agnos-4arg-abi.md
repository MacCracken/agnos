# `sys_reboot()` is nullary but agnos syscall #13 now takes four arguments — OPEN

**Discovered:** 2026-07-19 while building the **agnos** 1.55.x shutdown arc (orderly
filesystem flush + device quiesce + platform reset / ACPI S5 soft-off, both iron-validated
on the AMD Zen dev box).
**Severity:** Medium — hard mismatch with a known workaround already shipping. No crash
today, because agnos's magic-token gate makes stale callers fail closed by design, but the
stdlib wrapper can no longer reach the syscall it names, and the consumer workaround is to
bypass the stdlib entirely.
**Affects:** `lib/syscalls_x86_64_agnos.cyr` (all versions to date; observed on cycc
**6.4.67**). agnos kernel **1.55.25+**.

**⚠ NOT A CYRIUS BUG.** `syscall()`'s pop-exactly-what-the-call-site-names behavior is
working as designed, and the wrapper was accurate when written. This is **agnos changing an
ABI underneath a stdlib wrapper**; it is filed here only because the wrapper lives here.
Cross-filed at `agnos/docs/development/issues/` per the agnos↔cyrius convention.

## Summary

`lib/syscalls_x86_64_agnos.cyr` exposes agnos syscall #13 as a **nullary** wrapper:

```cyrius
var SYS_REBOOT = 13;                            # reboot() -> halts
fn sys_reboot(): i64 { return syscall(SYS_REBOOT); }
```

That matched the old kernel, where #13 was effectively a stub — it printed a line and
called `arch_halt()`. agnos 1.55.25 replaced it with a real implementation whose signature
is `reboot(magic1, magic2, cmd, arg)`. The nullary wrapper can no longer express a valid
call, so the only correct way to reach agnos power control from Cyrius userland today is to
bypass the stdlib and call by raw number.

## Reproduction

Any `--agnos` build calling the stdlib wrapper, against agnos ≥ 1.55.25:

```cyrius
sys_reboot();       # compiles; kernel returns -1 and does nothing
```

The cyrius `syscall()` builtin pops exactly the argument registers the **call site** names,
so a nullary `syscall(13)` leaves `rdi`/`rsi`/`rdx` holding whatever the caller happened to
have there. The kernel sees garbage in the magic/cmd slots, rejects it, and returns `-1`.

Expected: a reboot, or a compile-time signature mismatch.
Actual: silent no-op return.

## Root cause

Not a defect — a stale wrapper signature. agnos's `#13` handler now reads four arguments
(`kernel/core/power.cyr`, `power_sys()`; dispatch row in `kernel/core/syscall.cyr`):

```
reboot(magic1, magic2, cmd, arg)
    magic1 = 0x50575231   # "PWR1"
    magic2 = 0x50575232   # "PWR2"
    cmd    = 1 halt | 2 power off | 3 reboot
```

The magic pair exists **specifically** to make stale nullary callers fail closed rather
than reset the machine on register garbage — the same rationale as Linux's `reboot(2)`
magics. So the current mismatch is inert, not dangerous.

## Proposed fix

Widen the agnos wrapper and export the constants, so consumers stop hand-rolling them:

```cyrius
var SYS_REBOOT = 13;
var PWR_MAGIC1 = 0x50575231;   # "PWR1"
var PWR_MAGIC2 = 0x50575232;   # "PWR2"
var PWR_HALT   = 1;
var PWR_OFF    = 2;
var PWR_REBOOT = 3;

fn sys_reboot(magic1, magic2, cmd, arg): i64 {
    return syscall(SYS_REBOOT, magic1, magic2, cmd, arg);
}
```

The **constants are the part that matters** — those are what get miscopied. Convenience
wrappers (`sys_power_off()`, `sys_power_reboot()`) would be welcome but are not required.

⚠ This is a **breaking signature change** to an existing wrapper. Blast radius looks empty
in practice — the old wrapper only ever halted, so there is little reason for existing code
to call it — but worth a `grep` across the ecosystem before landing.

## Consumer-side workaround (shipping now)

agnoshi **1.8.5** calls by raw number from its `reboot` / `poweroff` / `halt` builtins:

```cyrius
syscall(13, 0x50575231, 0x50575232, 3, 0);   # 3 = reboot, 2 = power off, 1 = halt
```

This works and is the correct call shape until the wrapper is widened. The cost of leaving
it is that every consumer re-derives the magic constants by hand, which is how they end up
mistyped somewhere.

## References

- agnos `kernel/core/power.cyr` — `power_sys()`, the magic gate and command codes
- agnos `kernel/core/syscall.cyr` — the `#13` dispatch row
- agnos `CHANGELOG.md` **1.55.25** (reset ladder + the `#13` rebuild), **1.55.26** (ACPI S5 soft-off)
- agnoshi **1.8.5** — the current raw-number caller
