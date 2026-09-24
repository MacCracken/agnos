# 2026-09-23 — a refused TSC calibration leaves `uptime_us`#95 at -1 for the whole boot: no retry, no fallback

**Status:** ✅ **RESOLVED 1.57.6 (2026-09-24)** — `tsc_calibrate` measures against the **ACPI PM timer** (median of 5 bracketed windows, 3 must agree within 0.5%), falls back to a hardened live-tick tier, retries **once** immediately before `sched_active = 1`, prints the refused `lo..hi` range and the corrected message, and documents −1 from `#95` as **PERMANENT for the boot**. Gate: `scripts/smoke/tsc-smoke.sh` (sweep row, `TSC_SELFTEST=1`; 16/0) and its manual `TSC_QUOTA=25`/`50` mode (QEMU's own `cpu.max` as the positive control; 28/0), which reproduces the refusal on the 1.57.5 kernel. Built, gated, NOT burned. See § Resolution.
**Filed by:** daimon (the AGNOS agent orchestrator). Every deadline in daimon reads the clock, and
cyrius's `clock_now_ms` on agnos is `uptime_us`#95.
**Checked against:** agnos **1.57.5**: `tsc_calibrate` in `kernel/core/main.cyr` (`:4687`–`:4733`) and
the `#95` arm in `kernel/core/syscall.cyr` (`:10153`), read in the working tree.
**Consumer impact:** when the calibration is refused, a program timing itself with `#95` sees time
stand still, and every wait for a deadline waits forever. daimon's guest test hung in its first
10 ms wait. daimon 2.4.1 falls back to `uptime_ms`#40.

> `tsc_calibrate` runs once, at boot. It counts TSC cycles across 5 timer ticks (50 ms) and refuses
> a result below 100 or above 10000 cycles per µs (`:4699`–`:4700`). Nothing tries again. From then
> on the `#95` arm answers -1 (`if (tsc_per_us == 0) { return 0 - 1; }`) for the rest of the boot.
> The refusal is printed as `"tsc: calibration REFUSED -- uptime_us will report 0"`, but the arm
> returns -1, not 0.

---

## Measured (daimon's guest test, agnos 1.57.5 under QEMU TCG, released binaries)

| QEMU's CPU | the boot log | the guest test |
|---|---|---|
| unrestricted | `tsc: 3192 cycles per microsecond (measured over 50 ms of live ticks)` | passes (77 s) |
| held to 50% of a CPU (`systemd-run --scope -p CPUQuota=50%`) | calibrated; in a second boot `tsc: 8319 cycles per microsecond` | passes (164 s, 136 s) |
| held to 25% of a CPU | `tsc: calibration REFUSED -- uptime_us will report 0` | hung: no output for 12 minutes after its first agent started, with QEMU's vCPU thread using all of its 25% |

The refused value is not printed, so I cannot say which bound it crossed. The 50% row shows the other
side: a calibration inside the bounds can still be far off. 8319 against the true 3192 means `#95`
ran at about 38% of real time for that whole boot, and every deadline built on it stretched 2.6×. A CPU quota delivers a
guest's timer ticks unevenly, and so can any busy host or shared CI runner that runs agnos
virtualized.

## The ask

1. **Do not give up for the whole boot, and do not trust one window.** Try the calibration again,
   over a longer window, or take the median of several windows: one 50 ms window both refused
   (25%) and accepted a value 2.6× too large (50%).
2. **When there is no calibration, keep `#95` a clock.** For example, derive it from `timer_ticks`
   (10 000 µs a tick), or document -1 as permanent so that consumers know to fall back to `#40`.
3. **Print the refused measurement**, and correct the message: the arm returns -1, not 0.

## What daimon does meanwhile

daimon 2.4.1 reads its clock through `daimon_now_ms`. That uses `#95` while it answers, and
`uptime_ms`#40 (the 100 Hz tick) once it answers -1. daimon runs in the background, so `#40`
advances for it. (`#40` stands still only for a foreground `run` program, which is why cyrius moved
its clock to `#95`.) The same fallback is filed with cyrius for `clock_now_ms` itself.

---

## Resolution (1.57.6, 2026-09-24)

**What shipped** (`kernel/core/main.cyr` `tsc_calibrate` and its tiers, `kernel/core/acpi.cyr` FADT
decode, `kernel/arch/x86_64/apic.cyr` `lapic_reload_measured`, the `#95` arm; normative text in ABI row 95
and [`docs/architecture/kernel-clocks.md`](../../../architecture/kernel-clocks.md)):

- **Ask 1 — do not give up, do not trust one window.** The reference is now the ACPI PM timer: port from
  the FADT (`PM_TMR_BLK`@76 when `PM_TMR_LEN`@91 == 4, `X_PM_TMR_BLK`@208 when it is system-I/O, both only
  on a non-hardware-reduced FADT), bracketed `rdtsc`/`inl`/`rdtsc` samples (the tightest of 4), the median
  of 5 windows, of which 3 must agree within 0.5%. With no PM timer the live-tick tier runs, now with a
  lost-tick/burst test and gated on a measured LAPIC reload. One retry runs immediately before
  `sched_active = 1`. A box with no PM timer under sustained throttling can still refuse twice and then
  keep −1 — that is the reading 1.57.6 takes of this ask (S1's report asked the operator to confirm it).
- **Ask 2 — keep `#95` a clock, or document −1 as permanent.** Documented: after the pre-userland retry,
  −1 is permanent for the boot (ABI row 95; kernel-clocks.md Invariant 2), so a latched fallback to `#40`
  and a per-call one are equally correct. `#95` is not derived from `timer_ticks`.
- **Ask 3 — print the refused measurement and fix the message.** A refusal prints
  `tsc: <tier> REFUSED -- K of N windows usable; measured LO..HI cycles/us` and
  `tsc: calibration REFUSED -- uptime_us#95 returns -1 for the rest of this boot`.

**Measured** (q35, QEMU TCG held by `CPUQuota`; `cpu.max` read inside QEMU's own scope): the PM tier reads
**3193 cycles/µs at 25% and at 50%**, where the tick reference refuses at 25% (measured 12275..19163) and
reads 7898..11267 at 50%. The unmodified 1.57.5 kernel under the same smoke reproduces this filing
(`calibration REFUSED -- uptime_us will report 0`, `run: exit 0`). Plain KVM 3193 (baseline 3192–3193);
`-machine pc` (rev-1 FADT) decodes port `b008` and reads 3193; `-smp 4` 16/0.

**What the change broke — checked before archiving:** nothing observed. The PM tier reads within 1 cycle/µs
of the tick tier on this host; `check.sh`, `ktest` (107/3, the three environmental), `agnsh-smoke` and the
full sweep are unchanged. Two PRE-EXISTING defects surfaced and were fixed in the same step: `tsc-smoke` was
RED on 1.57.5 (5 passed, 2 failed — its extraction read the klog timestamp), and the `TSC_SELFTEST` boot hung
after `run /bin/tscp` (the probe returns to kmain with IF=0 and the next `arch_wait` halted forever).

**Not fixed here (roadmap step S1b):** `lapic_calibrate` still counts PIT wraps by polling, so under the
same throttle the LAPIC 100 Hz reload and the klog timebase are inflated
(`klog: TIMEBASE DISAGREES -- early=8769 late=3193` at 25%) and `uptime_ms`#40 runs slow for that boot.
**Unproven on iron:** the PM tier on the AMD FCH (expected `acpi: pm timer port 808, 32-bit`).
**Consumers:** cyrius `lib/chrono.cyr` (already filed there) and `lib/bench.cyr:197` (in the 2026-09-24
agnos peer filing) do not check −1; daimon can re-run its `CPUQuota` guest test against 1.57.6 and keep its
`#40` fallback for older kernels.
