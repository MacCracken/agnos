# 2026-09-23 — a refused TSC calibration leaves `uptime_us`#95 at -1 for the whole boot: no retry, no fallback

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
