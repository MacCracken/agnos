# The kernel's clocks — invariants behind `uptime_ms`#40, `uptime_us`#95 and the log timebase

> **Last Updated**: 2026-09-25 (1.57.7 — S1b: the tick and the log timebase on the PM timer; #40 on the TSC)
> (first written 2026-09-23 for the 1.57.6 TSC-calibration repair)
>
> Code: `tsc_calibrate` and its tiers in [`kernel/core/main.cyr`](../../kernel/core/main.cyr) (just after the
> boot body's `sti`) and its one retry (just before `sched_active = 1`) · the PM-timer decode in
> [`kernel/core/acpi.cyr`](../../kernel/core/acpi.cyr) `acpi_find_fadt` / `acpi_fadt_clear` / `acpi_pm_early_probe` ·
> `lapic_calibrate_pm` / `lapic_calibrate` / `lapic_reload_100hz` / `lapic_reload_src` in [`kernel/arch/x86_64/apic.cyr`](../../kernel/arch/x86_64/apic.cyr) · the tick in
> [`kernel/arch/x86_64/pic.cyr`](../../kernel/arch/x86_64/pic.cyr) · the declarations in
> [`kernel/arch/x86_64/boot_data.cyr`](../../kernel/arch/x86_64/boot_data.cyr) · the `#40` / `#95` arms in
> [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr).
> Ring-3 contract: the `#40` and `#95` rows of [`../development/agnos-userland-abi.md`](../development/agnos-userland-abi.md).
> Gate: [`scripts/smoke/tsc-smoke.sh`](../../scripts/smoke/tsc-smoke.sh) (sweep row — one invocation boots the matrix
> q35 -smp 1, q35 -smp 4, pc -smp 1 and scores T1-T10 on each; `TSC_QUOTA=<pct>` is the manual CPU-quota
> reproduction, whose boot B must also keep the LAPIC reload within 1% of A's and pass the halted tick-rate checks). Origin: daimon's 2026-09-23 filing, "a refused TSC calibration leaves
> `uptime_us`#95 at -1 for the whole boot".
>
> Numbers below were measured on this repo's QEMU host at 1.57.6; re-measure, do not copy forward.

## Three clocks, three owners

| Clock | Written by | Valid from | Ring-3 face | Stops when |
|---|---|---|---|---|
| `timer_ticks` (100 Hz) | the timer ISR, **BSP only** (`pcpu_cpu() == 0`) | the boot body's `sti` | `uptime_ms`#40 = ticks × 10 **only while the TSC is uncalibrated** (since 1.57.7 it is `uptime_ms_base` + TSC ms, see Invariant 4) | the BSP runs `IF=0` (since S3b only the pre-scheduler boot selftests); loses only ticks a hypervisor coalesces while throttling a busy vCPU (the reload itself is PM-measured since 1.57.7) |
| `tsc_per_us` / `tsc_base` | `tsc_calibrate` (twice at most, both before `sched_active = 1`) | the calibration | `uptime_us`#95 = (rdtsc − base) / rate, or −1 | never, once calibrated — rdtsc needs no interrupts |
| `klog_tsc_per_us` / `klog_tsc_boot` | `lapic_calibrate_pm` against the ACPI PM timer before `apic_init` (the polled PIT window on a PM-less box), ~4,400 statements before `sti` | near the top of the boot body | none (log timestamps only) | never (Invariant 4) |
| `sched_clock_us()` (1.57.7) | derived: `(rdtsc − tsc_base) / tsc_per_us` when the TSC is calibrated, else `timer_ticks × 10000` (**tick mode**) | `sched_active = 1` (both inputs are final by then) | none — every kernel wait deadline is on it (`wq_arm`, `sleep_ms`#41; since 1.57.7 S6 also every TCP/ICMP deadline: the retransmit stamps `cb+112` (`retx_us`), FIN_WAIT_2, #47's ceiling, #48's D6 clock, #55/#100's bound — `tcp_retx_due` REBASES a stamp that lies in the future, because `tsc_calibrate` re-points `tsc_base` and the clock can step backward once) | TSC mode: never. Tick mode: with the BSP's ticks — it **stalls while the BSP runs a long IF=0 syscall**, and it has one-tick granularity, so `wq_deadline_after_us` pads a tick-mode deadline by one tick (+10 ms) to keep "sleeps at least `us`". Deadlines expire in `wq_tick` on **every** CPU, at the first tick at or after them. See `blocking-waits.md`. |

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
or the tick seen to jump by 2) and run only when `lapic_reload_measured` says the tick rate was measured —
and only `lapic_reload_src == 1` (the PM timer, Invariant 4) proves that rate is a true 100 Hz.
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

## Invariant 3 — a foreground `run` returns to its kernel caller with the caller's IF (1.57.7 S3b)

After `sched_active = 1` a `run` (kmain's `sh_cmd_run`, the emergency shell, kybernet's `/bin/agnsh`, the
post-scheduler selftest hooks) is a **scheduled child kmain blocks for** (`kernel_run_child`; see
[`foreground-exec.md`](foreground-exec.md)), and `kernel_run_child` returns with the caller's own IF. Before it, the
out-of-band path (`kernel_exec_boot` → `exec_and_wait`) still returns through the child's exit syscall with IF
masked, and `kernel_exec_boot` restores the caller's IF after the reap. So no `run` hands its caller IF=0 any more:
- **`TSC_SELFTEST`'s `/bin/tscp` probe** (pre-scheduler, the only post-`sti` run before `sched_active = 1`): its
  trailing `asm { sti; }` (added 1.57.6, when its boot ended at `run: exit 1` in a `hlt` with IF=0) is now
  belt-and-braces.
- **`MODESET_TOOL_SELFTEST`'s `/bin/modeset` runs** (post-scheduler): the trailing `sti` they needed since 1.57.6 is
  DELETED.
- The emergency-shell caveat (the shell reaching `arch_wait()` IF=0 after a `run` or after a non-zero agnsh exit) is
  resolved the same way.
History: through 1.57.6 every foreground program ran IF=0 and its exit syscall longjmp'd back to the caller with
interrupts off, so a following `arch_wait()` (`hlt`) with IF=0 halted forever (`smp_wait_ticks` documents the same
hang for a trailing `cli`).

## Invariant 4 — the tick and the log timebase are measured against the PM timer, known before `apic_init`

Through 1.57.6 `lapic_calibrate` counted PIT channel-0 wraps by **polling**, with interrupts off. A vCPU
descheduled for longer than one 10 ms period misses a wrap, so under a host quota the LAPIC reload (hence the
100 Hz tick, every `timer_ticks` deadline and `uptime_ms`#40) and `klog_tsc_per_us` both came out high by the
same factor: tsc-smoke measured `klog: TIMEBASE DISAGREES -- early=8769 late=3193` at 25% and `early=7186` at 50%.

Since 1.57.7 (S1b):

- **The early probe.** `acpi_pm_early_probe` (acpi.cyr) decodes the FADT immediately before `apic_init`, from
  gnoboot's **boot_info RSDP only**: the legacy scan's first read is page 0 (the EBDA pointer), which firmware
  NULL-pointer detection can leave not-present under the firmware CR3 still live there, and a boot-context #PF
  halts the box. No boot_info RSDP → port 0 → the PIT method, exactly as before. CMOS checkpoint **0x83** (slot
  0x50) attributes a hang inside it. `acpi_va` takes its identity branch (the firmware CR3 is not 0x1000).
- **The double decode is pure.** The FADT is decoded twice (early, then `acpi_init`), and power.cyr reads the
  fields at shutdown, so `acpi_fadt_clear` zeroes all 18 outputs at the top of `acpi_find_fadt` and in
  `acpi_init`'s reset list — no stale field survives any path, including `acpi_init`'s no-RSDP return
  (tsc-smoke `acpi-fadt:` 3 arms). main.cyr prints `lapic: WARNING …` if the late decode's port differs.
- **`lapic_reload_src`**: 1 = `lapic_calibrate_pm` (median of 5 bracketed ~10 ms PM windows, 3 agreeing within
  0.5% for the reload AND the TSC rate) — a true 100 Hz; 2 = the polled PIT window (a PM-less box, a port that
  does not count, or a refused PM tier); 0 = the 10000000 literal. `lapic_reload_measured` keeps its 0/1 meaning.
  The boot log's `lapic:` line names the source; a refusal prints what it measured.
- **Both or neither.** `klog_tsc_per_us` is written by the PM tier only on success, so a log timebase never pairs
  with a reload from a different reference. When both it and `tsc_per_us` are PM-derived the klog cross-check
  band is **1%** (`… within 1%`); otherwise the 1.56.58 ±12% band stands.
- **`uptime_ms`#40 on the TSC** (operator OQ-2): `tsc_calibrate` publishes `uptime_ms_base = timer_ticks × 10`,
  then `tsc_base`, then the rate; #40 returns `uptime_ms_base + (rdtsc − tsc_base) / (tsc_per_us × 1000)` once
  calibrated — continuous with the tick clock, and it advances under IF=0 and under throttling.
- **Measured** (tsc-smoke, KVM): `LAPIC: reload=` 9999819..9999961 on the matrix (the PIT value was 10000536), the
  halted-window median tick period 9999-10000 us, #40 advanced 200 ms across a 200 ms IF=0 busy window, and
  the lowest AP took 100 ticks over 999 ms of PM time (-smp 4). Quota A/B numbers: see the 1.57.7 CHANGELOG.

**Residual.** Ticks a hypervisor coalesces while it throttles a *busy* vCPU are still lost, and the tick stops
while the BSP runs IF=0 — so tick-denominated deadlines stretch there (TSC-keyed ones do not; #40 no longer
does). On a PM-less box the PIT path stays polled and the live-tick tier trusts it; `tsc_calibrate` then prints
`tsc:   the live-tick tier trusted a PIT-measured reload -- a host CPU quota can bias it`.
⚠ Iron-only risk: the early ACPI reads under AMI firmware page tables — no QEMU gate can show a fault there.
