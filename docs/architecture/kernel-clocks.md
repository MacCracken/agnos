# The kernel's clocks — invariants behind `uptime_ms`#40, `uptime_us`#95 and the log timebase

> **Last Updated**: 2026-09-23 (1.57.6 — first written for the TSC-calibration repair)
>
> Code: `tsc_calibrate` and its tiers in [`kernel/core/main.cyr`](../../kernel/core/main.cyr) (just after the
> boot body's `sti`) and its one retry (just before `sched_active = 1`) · the PM-timer decode in
> [`kernel/core/acpi.cyr`](../../kernel/core/acpi.cyr) `acpi_find_fadt` · `lapic_calibrate` /
> `lapic_reload_100hz` in [`kernel/arch/x86_64/apic.cyr`](../../kernel/arch/x86_64/apic.cyr) · the tick in
> [`kernel/arch/x86_64/pic.cyr`](../../kernel/arch/x86_64/pic.cyr) · the declarations in
> [`kernel/arch/x86_64/boot_data.cyr`](../../kernel/arch/x86_64/boot_data.cyr) · the `#40` / `#95` arms in
> [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr).
> Ring-3 contract: the `#40` and `#95` rows of [`../development/agnos-userland-abi.md`](../development/agnos-userland-abi.md).
> Gate: [`scripts/smoke/tsc-smoke.sh`](../../scripts/smoke/tsc-smoke.sh) (sweep row; `TSC_QUOTA=<pct>` is the
> manual CPU-quota reproduction). Origin: daimon's 2026-09-23 filing, "a refused TSC calibration leaves
> `uptime_us`#95 at -1 for the whole boot".
>
> Numbers below were measured on this repo's QEMU host at 1.57.6; re-measure, do not copy forward.

## Three clocks, three owners

| Clock | Written by | Valid from | Ring-3 face | Stops when |
|---|---|---|---|---|
| `timer_ticks` (100 Hz) | the timer ISR, **BSP only** (`pcpu_cpu() == 0`) | the boot body's `sti` | `uptime_ms`#40 = ticks × 10 | the BSP runs `IF=0` (every foreground `run`); runs slow when ticks are lost |
| `tsc_per_us` / `tsc_base` | `tsc_calibrate` (twice at most, both before `sched_active = 1`) | the calibration | `uptime_us`#95 = (rdtsc − base) / rate, or −1 | never, once calibrated — rdtsc needs no interrupts |
| `klog_tsc_per_us` / `klog_tsc_boot` | `lapic_calibrate`'s PIT window, ~4,400 statements before `sti` | near the top of the boot body | none (log timestamps only) | never; but see Limitation below |

They are deliberately separate (`boot_data.cyr` explains why `tsc_base` cannot be re-pointed at boot time
and why `tsc_per_us` must stay 0 until `tsc_calibrate`). `tsc_calibrate` cross-checks the late number
against the early one and prints `klog: log timebase OK` or `klog: TIMEBASE DISAGREES`.

## Invariant 1 — the calibration reference must not need interrupt delivery

Through 1.57.5 `tsc_calibrate` counted TSC cycles over one window of 5 delivered ticks. Under a host CPU
quota the vCPU's periodic ticks coalesce, so the window runs long and the answer is biased **high** —
daimon measured `8319` for a true `3192` at `CPUQuota=50%` (#95 at 38% of real time, every deadline 2.6×
long) and a refusal at 25%. A median of tick windows does not help: the bias always points one way.

Since 1.57.6 the reference is the **ACPI PM timer** (3.579545 MHz fixed hardware, `acpi_pm_tmr_port`,
decoded from FADT `PM_TMR_BLK`@76 when `PM_TMR_LEN`@91 == 4, overridden by a system-I/O `X_PM_TMR_BLK`@208;
none on a hardware-reduced platform). A throttle only lengthens a PM window, and the window measures its own
length. Each window is two **bracketed** samples (rdtsc / `inl` / rdtsc, tightest of 4) ~10 ms apart; the
answer is the median of 5, and 3 must agree within 0.5%. Readers mask the counter to 24 bits, correct for
both widths. Live ticks are the fallback tier only — screened for lost ticks (an interval > 1.25× another,
or the tick seen to jump by 2) and run only when `lapic_reload_measured` says the tick rate was measured.
The screen is gated twice in tsc-smoke: five synthetic `pred-tsc:` arms feed the pure predicates, and one
LIVE window with a 25 ms `IF=0` stall across an interval must come back rejected — the only check that the
predicate is actually wired into the window, since an unthrottled window is uniform either way.

Measured (tsc-smoke, TCG): unthrottled `3193`; at `CPUQuota=25%` and `50%` the PM tier still reads `3193`,
while the tick tier, run alongside, refuses with `measured 12275..19163` (25%) and `7898..11267` (50%)
cycles/us. q35 advertises the timer at port `0x608`, i440fx (rev-1, 116-byte FADT) at `0xb008`.

## Invariant 2 — −1 from `uptime_us`#95 is permanent once production ring 3 runs

`tsc_calibrate` runs right after `sti` and **once more immediately before `sched_active = 1`** if every tier
refused — the last point before kybernet and any production ring 3. **Nothing may call it after that.**
Only the second attempt's refusal says so in the log (`uptime_us#95 returns -1 for the rest of this boot`);
a refused first attempt says `one more attempt before userland`. The one ring-3 reader that runs between
the two attempts is a `TSC_SELFTEST` kernel's `/bin/tscp` probe, which can therefore see −1 and then a
valid clock; "permanent" is a promise to production ring 3, which starts at kybernet. A
clock that turned from −1 to valid mid-run would jump the epoch under every consumer that falls back to
`#40` per call (sakshi's clock, yeomans' session, daimon's http client), and a lazy retry inside a syscall
would hold a CPU for 50+ ms on the shared per-CPU kstack. Consumers may therefore latch their fallback.

⇒ **Kernel code keyed on `tsc_per_us` must handle 0** — it stays 0 for the whole boot on a refused
machine. `gpu_tsc_per_us()` / `hda_tsc_per_us()` fall back to a per-file estimate (every use there is a
multiply into a delay, so a larger number only buys patience); a deadline built on the TSC must fall back to
`timer_ticks`, never spin on a clock that is not there.

## Invariant 3 — a foreground `run` returns to its kernel caller with IF=0

A foreground program runs `IF=0` and returns to its kernel caller (`sh_cmd_run` → `exec_and_wait`) through
its exit syscall, which is entered with IF masked, so the caller resumes with interrupts OFF whatever IF it
had. Before the boot body's `sti` that is the norm (the exec, divz, fault … selftests). After it, the next
`arch_wait()` (`hlt`) halts forever, because a `hlt` with `IF=0` wakes only on NMI/SMI/INIT. The boot body
makes post-`sti` runs in two places, both compile-gated:

- **`TSC_SELFTEST`'s `/bin/tscp` probe** — the only one between the calibration and `sched_active = 1`, and the
  only one followed by an `arch_wait()` (the hlt pair before "Timer ticks before sched"). Through 1.57.5 its
  boot ended at `run: exit 1`, unseen because tsc-smoke asked nothing about what came after. It now restores
  `IF=1` (`asm { sti; }`), and the smoke checks that the boot reaches the shell.
- **`MODESET_TOOL_SELFTEST`'s twelve `/bin/modeset` runs**, after `sched_active = 1`. They handed `boot_finish`
  `IF=0`: harmless for the agnsh launch (`kybernet_exec_agnsh` masks anyway, and `enter_ring3`'s iretq sets
  `IF=1`), but that smoke seeds no `/bin/agnsh`, so kybernet's emergency-shell fallback ran its `hlt` with
  interrupts off. Since 1.57.6 the block ends with the same `sti`.

Any new post-`sti` boot-body `run` needs the same. (`smp_wait_ticks` documents the same hang for a trailing
`cli`.) ⚠ The rule is about the CALLER, not the boot body: `kybernet`'s emergency shell (`shell()`) reaches
`arch_wait()` after `sh_cmd_run` too, and after `kybernet_exec_agnsh` returns from a non-zero agnsh exit
(its own comment: "kernel_resume already returns here IF=0") — the same shape, found by reading the code at
1.57.6 and handed to the lead rather than fixed inside the TSC repair.

## Limitation — the early window is still polled (being fixed in 1.57.6 by S1b)

`lapic_calibrate` counts PIT channel-0 wraps by **polling**, with interrupts off. A vCPU descheduled for
longer than one 10 ms period misses a wrap, so under a host quota the LAPIC reload (hence the 100 Hz tick,
hence `uptime_ms`#40) and `klog_tsc_per_us` both come out high by the same factor: tsc-smoke measured
`klog: TIMEBASE DISAGREES -- early=8769 late=3193` at 25% and `early=7186` at 50%. `#95` no longer depends on
either. ⚠ **S1b**, the 1.57.6 follow-up step (operator decision 2026-09-23), fixes it by measuring the LAPIC
reload and the klog timebase against the PM timer — which needs the PM timer before `lapic_calibrate`, a boot
reorder (`acpi_init` runs after it) — and rewrites this section when it lands. Until then, for the same
reason, `lapic_reload_measured == 1` does not prove a true 100 Hz, which is why the tick tier is the fallback
and not the reference.
