# 2026-09-03 — two follow-ons from the telemetry filing, both found by consuming it — RESOLVED

**Status:** RESOLVED in agnos **1.56.60** (the cut that was open when this was filed — no version
bump was taken for it). All three asks fixed, plus the gate finding. **No new syscall, no new ABI
field, and no cyrius change** — the ABI gate still reads `kernel 105 · abi-doc 105 · cyrius 105`.

| # | Ask | Outcome |
|---|-----|---------|
| 1 | per-process ticks include halted time | **FIXED** — shape #1 (halt exclusion). Answer to *"tell us if it's not worth it"*: it was cheap. |
| 2 | block band misses `*_sectors_on` / ext2 | **FIXED** — counted at every bypassing path. `disk:` is renderable. |
| 2a | `blk_info`#79 ignores per-tag `lba_bytes` | **FIXED** — one line, `blk_lba_bytes_for(h)`. |
| — | block gate is a static test | **FIXED** — plus a second oracle you did not ask for (below). |

**1 — halt exclusion.** `arch_wait()` is the single `hlt` every blocking wait in the kernel funnels
through (`sleep_ms`#41's loop, `kbd_read_blocking`, the idle loop, the dozen net polls), so the flag
went there rather than at ~a dozen call sites — a per-site list is a list that rots. Per-CPU
`cpu_in_halt[4]`; the timer ISR skips the charge. `proclist`#99 `+56` low u32 now means CPU time.
Halted time is charged to **nobody**. ⚠ We did NOT add the second counter you offered as shape #2:
it would have needed a new ABI field for a quantity a consumer only wanted in order to subtract it.
⛔ **One trap worth your knowing, because it bit us mid-implementation**: clearing the flag only in
`arch_wait` after the `hlt` **wedges the counter for the whole boot**. The same ISR calls
`do_context_switch`, so a tick that wakes a halt can switch away and the post-`hlt` clear never runs;
every later tick on that core is then suppressed. The ISR now *consumes* the flag (read-then-clear),
making the suppression one-shot.

**2 — the block band.** Counting is placed **per-branch** at each path that genuinely bypasses
`blk_read_on`/`blk_write_on` (`blk_read_sectors_on`, `blk_write_sectors_on`'s NVMe arm, and both
`*_sectors_direct` NVMe arms). Not at the top of those functions: their non-NVMe fallbacks loop
through `blk_*_on`, which already counts, so a blanket count would have doubled every non-NVMe
transfer. Your diagnosis was exactly right, including the 4096-block/8-sector fast-path detail.

**Your gate note was right and cost us the most to act on.** `tlm.cyr` §3 now uses the two-sample
moved oracle — but *"it moved"* alone still passed with the fix removed, because `open()` also does
single-sector metadata reads (`ext2_blk_read` → `blk_read_on`) that were counted all along. The
oracle needs a **magnitude**: 12 passes over the ~22 KB exerciser, asserting ≥256 sectors. New §4b
also blocks in `sleep_ms` and asserts the tick counter does **not** move — §4's busy-loop oracle
could never have seen your defect, since a wall-clock counter passes it identically.

⚠ **What we found while verifying, which you should know about because it affects how much any of
our green gates are worth:** `telemetry-test.py` resolved both the exerciser and `build/agnos` as
prebuilt paths and rebuilt neither. Eight consecutive runs — including mutants that deliberately
re-introduced your two defects — reported PASS against stale artifacts. Both are now guarded; the
other 26 harnesses with the same shape are filed at
`issues/2026-09-03-harness-exercisers-never-rebuilt.md`.

⚠ **Not fixed, and now documented rather than silently wrong:** `blk_info`#79's `capacity_lbas` is
still reported only for the ACTIVE backend and reads 0 for any other registered handle. That is a
gap, not a claim of zero capacity — ABI row 79 says so now. Tell us if you need it.

⚠ **§4c (the wedge arm) is NOT mutation-proven** and is labelled as such in the test: it needs a
context switch out of a halt, which this single-process harness does not reliably produce.

**Your three "not asks" are recorded as-is** — the `net_config` seam confirmation, the statfs timing
(591 µs ext2 / 151 ms FAT under `fs_spin_lock`, do not put it in a render loop), and the
self-declared `f_blocks * f_bsize` per volume. Thank you for measuring rather than guessing.

---

**Filed by:** chakshu (the AGNOS system monitor), during v0.9.9 — the cut that consumed
the telemetry you shipped in 1.56.59.

**Checked against:** agnos worktree **1.56.60**, `HEAD` `df787cd`.

> **First: thank you, and the big one works.** `proclist`#99's RSS half is live and
> chakshu now renders a real MEM% column on AGNOS — the first per-process memory figure
> the platform has ever had. `mountlist`#104, the `sysinfo`#35 CPU band, the `net_config`
> fields and the `kprintln`→klug move all landed exactly as described.
>
> Two things did not survive contact with a consumer. Both are narrow.

---

## 1. Per-process ticks include HALTED time, so they are not CPU utilisation

**Status: chakshu built this column, measured it, and backed it out.** Recorded here so
the work is not repeated.

`+56`'s low u32 is exactly as specified — cumulative, monotonic, zeroed at slot alloc.
The problem is what a tick means. The charge at `kernel/arch/x86_64/pic.cyr:65-68`:

```
var tk_p = proc_current_get();
if (tk_p >= 0) {
    if (tk_p < 16) { store64(&proc_ticks + tk_p * 8, load64(&proc_ticks + tk_p * 8) + 1); }
}
```

credits whoever is current **with no halt exclusion**. And `sleep_ms`#41 halts with
`sched_active = 0` and the caller still current — its own comment says so:

> *"sched_active=0 so the timer ISR still ticks+EOIs but do_context_switch early-returns"*

So a process blocked in a syscall keeps accruing ticks at wall-clock rate.

**Measured, on a live kernel under QEMU.** chakshu slept 100 ms for its own sampling
window and rendered:

```
   PID USER      S  CPU%  MEM% CMD
     3 root      R   100     1 [shu]      <-- 100%, while asleep
     2 root      R     0     1 [agnsh]
     1 root      R     0     0 [n/a]
     0 root      R     0     0 [n/a]
```

The quantity is *"share of wall-clock ticks while this slot was current, including
halted"*, which equals CPU utilisation only for a process that never blocks. chakshu's
column head is shared with the Linux build, where it means `utime+stime`, so rendering
this under it would make one name mean two things.

⭐ **This is the per-process analogue of the missing per-core `idle` field** — and you
declined to guess at that one for exactly this reason, which is why this is filed rather
than worked around. The same argument applies one level down.

**Not asking for a specific fix**, since the halt sites are the same ~dozen `arch_wait()`
callers that made `idle` undecidable per-core. Two shapes that would each unblock it:

- don't charge the tick when the interrupted context is a known blocking wait; or
- a second per-process counter (halted ticks) so a consumer can subtract — the record is
  full, but this could ride the `sysinfo`#35 tail the way the per-core band did.

⚠ If neither is cheap, **say so and we will stop asking** — MEM% alone made this cut
worthwhile, and `n/a` is a perfectly good answer for a column with no honest number
behind it.

---

## 2. The `sysinfo` block band misses the mainline I/O path

**Status: chakshu is NOT rendering a disk rate, and will keep `disk: n/a`, because the
counters do not move during real I/O.**

`blk_reads_by_tag` has exactly one increment site — `kernel/core/block.cyr:226`, inside
`blk_read_on`. `blk_writes_by_tag` likewise at `:273` inside `blk_write_on`. Every
multi-sector path bypasses both:

- `blk_read_sectors_on` (`block.cyr:313`) dispatches straight to the backend on **all
  five tags**
- `blk_write_sectors_on` (`block.cyr:358`) does so on NVMe
- `ext2_read_block` / `ext2_write_block` (`ext2.cyr:669` / `:689`) — the universal FS
  block primitives — call exactly those

chakshu's own harness builds a 4096-byte-block ext2 root on NVMe, so
`sectors_per_block = 8`, `8 × 512 = 4096` takes nvme's single-command fast path, and
**both counters stay frozen at their boot-probe value for the life of the boot.** A
monitor rendering from this band shows `0 B/s` through a heavy copy — a confident wrong
number, which is worse for us than `n/a`.

⚠ **Why your gate passed:** `tests/telemetry/tlm.cyr:158-165` asserts the block band
statically — *"some tag > 0"* — rather than with the two-sample **"the counter MOVED"**
oracle you used for the CPU and net bands, and which your own filing calls the right
oracle. The boot probe alone satisfies a static test. Applying the moved-oracle here
would have caught this before it shipped.

### 2a. `blk_info`#79 reports the wrong `lba_bytes` for any non-active tag

Separate, smaller, and it would corrupt the byte conversion the ABI doc prescribes.
`kernel/core/syscall.cyr:8276` stores the module-global `blk_lba_bytes` — the **active**
backend's — rather than `blk_lba_bytes_for(h)`. The 1.56.52 per-tag fix reached
`blk_read_sys`, `blk_write_sys` and `blk_enum_sys` (`:8135`) but not this one.

Both `agnos-userland-abi.md` §4.4 and cyrius `sys.cyr:373` tell a consumer to multiply
sectors by `blk_info`'s reported size. Following that on a secondary device — active NVMe
at 4096, registered virtio at 512 — is an **8× byte-rate error**. And 512 is not a safe
default: `blk_lba_bytes_ok` (`block.cyr:94-97`) admits 4096, and only virtio hardcodes 512.

---

## Also worth knowing, not asks

- **`net_config` fields 8-11 work under QEMU**, contrary to the concern in the original
  filing — `nic_send`/`nic_poll` are the driver *dispatcher*, not the r8169 driver, and
  the increments sit in both arms. Verified by a probe: one ICMP echo moved tx by exactly
  1 packet / 74 bytes. **The counting seam you chose was the right call and my suggested
  virtio ring indices would have been wrong.**
- **A per-volume capacity panel is feasible but cannot run per-frame.** Measured with
  `uptime_us`: `statfs` on ext2 = **591 µs**, on FAT = **151 ms** (a full free-cluster
  walk, ~1020 sector reads) — and the `#103` arm holds `fs_spin_lock` throughout. At 1 Hz
  that stalls every other process's file I/O ~15% of the time. Not a bug; recorded so the
  next consumer does not put it in a render loop. chakshu will use a slow separate cadence
  if it builds the panel.
- **`f_blocks * f_bsize` is self-declared per volume**: on the standard image FAT claims
  510 MiB and ext2 480 MiB on a 512 MB disk, so summing volumes reports ~2× the machine's
  storage. A consumer must not total them.

---

## Summary

| # | Finding | Consumer impact | Ask |
|---|---|---|---|
| 1 | Per-process ticks include halted time | CPU% column not renderable | halt exclusion, or a second counter — **or tell us it's not worth it** |
| 2 | Block band misses `*_sectors_on` / ext2 | `disk:` stays `n/a` | count at the multi-sector path too |
| 2a | `blk_info`#79 ignores per-tag `lba_bytes` | 8× byte-rate error | use `blk_lba_bytes_for(h)` |
| — | block gate is a static test | let §2 ship | reuse the "counter MOVED" oracle |

§2 is the one that costs you least and unblocks a whole panel.
