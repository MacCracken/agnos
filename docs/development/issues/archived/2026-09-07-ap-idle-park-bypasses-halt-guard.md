# 2026-09-07 — the AP idle park bypasses the halt guard, and one thing you can now NOT build — RESOLVED

**Status:** RESOLVED in agnos **1.57.1**. All three items closed. No new syscall, no new ABI field,
no cyrius change.

| # | Ask | Outcome |
|---|-----|---------|
| 1 | AP idle park bypasses `cpu_in_halt` | **FIXED** — `while (1 == 1) { arch_wait(); }`, plus **two more halt sites** the sweep found, plus a **mutation-proven** multi-core gate. |
| 2 | ⛔ do NOT build an idle / halted-tick counter | **HONOURED — nothing built.** The asymmetry stays as-is precisely so your derivation keeps working. |
| 3 | ABI doc says `sysinfo_n` is pending | **FIXED** — §4.4 now says the wrapper shipped in 6.5.45 and tells consumers not to hand-roll the raw call. |

**1 — and your sweep suggestion found two more.** `grep -n 'hlt' kernel/` turned up five candidates
beyond the idle park. Three now route through `arch_wait()`:
- `arch/x86_64/smp.cyr` — **the AP idle park** (your report);
- `arch/x86_64/smp.cyr` `smp_wait_ticks()` — a genuine timed block, the same class as `sleep_ms`#41;
- `core/main.cyr` — the fork-selftest's wait-for-child loop.
In each, the `sti` is hoisted out of the loop so the documented enter-and-exit-with-IF=1 contract is
preserved (a trailing `cli` was tried once historically and hung every smoke at its first `arch_wait`).

⛔ **TWO SITES DELIBERATELY LEFT AS BARE `hlt`, AND ONE OF THEM MUST NEVER BE "FIXED":**
- `smp.cyr`'s **out-of-range APIC-id park** (`my_id >= 4`). `pcpu_cpu()` **clamps any id >= 4 to 0**,
  so a core parking there through `arch_wait()` would set and clear `cpu_in_halt[0]` — *the BSP's
  slot* — and suppress tick charging on the boot processor for as long as it lived. That turns a
  harmless park into a silent machine-wide accounting fault. It is also unnecessary: that core has no
  per-CPU slot, is never scheduled, and parks before `sti`, so its IF=0 `hlt` never wakes by design.
- The two **dying-process tails** in `core/syscall.cyr`. Terminal paths for an already-state-0 slot
  that the next tick switches away from: at most one tick, charged to something about to be reaped.
Both now carry ⛔ comments in place so the next sweep does not "complete" them.

**⚠ ONE CORRECTION TO THE FILING, because it changes where the gap actually was.** You wrote that
this was *"invisible in both our harnesses — chakshu's QEMU boot is single-vCPU and so, I believe, is
`telemetry-test.py`"*. **`telemetry-test.py` has passed `-smp 4` all along.** The harness was never
single-core; it was blind because **no assertion looked at the other cores**. That is a better problem
to have — it needed an arm, not a harness rewrite.

⇒ New **`tlm.cyr` §4d**: sum ticks across every slot that is NOT the caller, across a 300 ms block, and
require the delta under 15. On an idle box a correct kernel charges neighbours nothing; with the park
unguarded three cores accrue ~30 ticks each (~90). **Mutation-proven, not assumed** — reverting the
one-line fix and rebuilding reddens it: baseline **95**, mutant **69**, restored **95**.

**2 — we built nothing, and the reasoning is now recorded in the tree** so a later cut does not
"helpfully" add the field you asked us not to add. Your derivation
(`Σ per-process deltas / pooled band delta`) depends on the two counters staying halt-asymmetric in
opposite directions; that asymmetry is deliberate and stays.

**3 — the doc was worse than stale.** It told consumers a length-taking overload was still pending
upstream. `sys_sysinfo_n(out, len)` and the named band accessors have shipped since **6.5.45**, and
`lib/sys.cyr` is byte-identical 6.5.45 → 6.6.1. §4.4 now says so and warns against hand-rolling the
raw call. `blk_info`#79's `capacity_lbas` remains active-only and documented as a known gap — noted,
not changed; say the word if you need it per-tag.


**Filed by:** chakshu (the AGNOS system monitor), during v0.10.1.
**Checked against:** agnos **1.57.0**, `HEAD` `4914e5b`.

> **The halt exclusion works, and it unblocked the column it was built for.** chakshu v0.9.9 built a
> CPU% column, measured itself at 100% while asleep, and backed it out. You shipped `cpu_in_halt` in
> 1.56.60; chakshu v0.10.0 ships the column and its own row now reads 0%. Thank you — the fix was
> exactly right, including dropping the tick rather than re-charging it.
>
> Two follow-ups. The first is a one-line bug. The second is us telling you **not** to build
> something, because it turns out you already gave us what it would have provided.

---

## 1. The AP idle park is a raw `hlt` outside `arch_wait()` — one line

`arch_wait()` brackets its `hlt` correctly (`kernel/arch/x86_64/io.cyr:183-185`):

```
if (aw_c < 4) { store64(&cpu_in_halt + aw_c * 8, 1); }
        asm { hlt; }
if (aw_c < 4) { store64(&cpu_in_halt + aw_c * 8, 0); }
```

But an AP's idle loop does not go through it (`kernel/arch/x86_64/smp.cyr:466-467`):

```
asm { sti; }
while (1 == 1) { asm { hlt; } }
```

Its LAPIC timer is already armed (`apic_timer_init` at `:460`) and IF is set, so **every idle tick
on APs 1..3 is charged to whichever slot `proc_current_get()` names on that core** — that core's
idle kthread. The flag is never set, so `pic.cyr`'s guard cannot fire.

**Consequence for a monitor:** on a wholly idle 4-core box, a naive per-process render shows three
rows at ~33% each and an aggregate of ~75% busy. chakshu suppresses it (see §2), so this is not
currently breaking us — but it will break the next consumer that does the obvious thing, and it
makes any machine-wide utilisation figure wrong by `(ncpu-1)/ncpu` on an idle box.

**Invisible in both our harnesses** — chakshu's QEMU boot is single-vCPU and so, I believe, is
`telemetry-test.py`. That is why the 1.56.60 gate passed. A multi-core assertion would catch it.

Suggested shape, using the primitive that already exists:

```
while (1 == 1) { arch_wait(); }
```

⚠ Worth checking whether any other bare `hlt` sits outside `arch_wait()` — `grep -n 'hlt' kernel/`
against the two known-good sites is a cheap sweep, and this is the second time a halt site has
mattered.

---

## 2. ⛔ Please do NOT add an idle field or a halted-tick counter. We derive it.

This is the part worth your time, because it is a request to **not** do work.

The obvious fix for "there is no idle field" would be a per-core halted-tick counter, and after
1.56.60 it would have been easy — `cpu_in_halt` is right there. **It is not needed.** Your two
counters are halt-asymmetric in opposite directions, and the residue between them is exactly the
idle time:

| counter | halt |
|---|---|
| `sysinfo`#35 `+40` per-core band, pooled | **included** (charged unconditionally by privilege of the interrupted context) |
| `proclist`#99 `+56` low u32, summed | **excluded** (1.56.60's guard) |

so

```
busy% = Σ(per-process tick deltas) / (pooled band delta) * 100
```

is real CPU utilisation, and chakshu v0.10.1 renders it. The AGNOS `-p` line now reads
`cpu: 0%   disk: rd 0 B/s wr 0 B/s   net: rx 0 B/s tx 0 B/s` instead of three `n/a`s.

⭐ **The asymmetry you chose deliberately for one reason turned out to be worth twice what it cost.**
The band is not halt-excluded because that makes it a valid wall-clock denominator for the
per-process column. That same property makes it the denominator for a machine-wide busy% as well.
An idle field would be a third counter carrying information the first two already encode.

**The one thing that would break this derivation is §1**, because the numerator sums per-process
ticks and the AP idle park injects halt time into that sum. chakshu filters it by only summing
processes with a name (only the ELF loader names a slot, so kernel threads and idle parks drop out
in one test) — but that is a workaround for a bug, not a design, and it would stop working the day a
kernel thread does real work worth reporting.

---

## 3. Two documentation notes, no code

- **`agnos-userland-abi.md` is stale on `sysinfo` lengths.** It tells a consumer that a
  length-taking overload is pending upstream in cyrius. It is not: `sys_sysinfo_n(out, len)` plus the
  named band accessors (`sysinfo_cpu_user`, `sysinfo_blk_read`, …) have existed since cyrius
  **6.5.45**, and `lib/sys.cyr` is byte-identical from 6.5.45 through 6.6.0. As written the doc sends
  the next consumer to hand-roll a raw syscall it does not need — which is how offsets get computed
  by hand and bands get read off by one.
- **`blk_info`#79's `capacity_lbas` is still active-only** while `lba_bytes` is now correctly
  per-tag. You already document this as a known gap, so this is only a note that a consumer did hit
  it: chakshu reads `lba_bytes` from `blk_info` for the unit guard and deliberately does **not**
  touch `capacity_lbas`.

---

## Summary

| # | Item | Ask |
|---|---|---|
| 1 | AP idle park bypasses `cpu_in_halt` | one line: `while (1) { arch_wait(); }` — plus a multi-core assertion, since neither harness sees it |
| 2 | idle / halted-tick counter | ⛔ **do not build it** — the residue between your two existing counters already is it |
| 3 | ABI doc says `sysinfo_n` is pending | it shipped in cyrius 6.5.45; the doc misdirects the next consumer |

§1 is the only code change requested, and it is one line.
