# 2026-09-02 — ring-3 telemetry gaps a system monitor needs

**Status:** ✅ **RESOLVED — all 9 sections closed at 1.56.59.** Six shipped code; three closed by
reasoning (§7 was repo policy; §8's cached/buffers and swap are correct as they are). Two §8 sub-items
are deliberately NOT built with the cost stated — per-process start time needs a new syscall number
now that `proclist`'s record is full, and interface enumeration would freeze an ifindex ABI while
there is exactly one interface. Both are yours to call.

✅ **§1 packet counters + §2 network byte counters** — `net_config`#61 gains fields **8-11**
(tx_packets / rx_packets / tx_bytes / rx_bytes). ⭐ **Counted at `nic_send`/`nic_poll`
(`core/r8169.cyr`), NOT at the virtio ring indices you offered** — those exist only on the QEMU path,
so a counter built on them would read 0 on iron where r8169 runs. That seam is the one place both
drivers meet, so the numbers mean the same thing on both substrates. Loopback is excluded by
construction. ⭐ **Extended #61 rather than minting a number, and that means you can read them TODAY**:
`sys_net_config(field)` already passes an arbitrary field id, so there is no cyrius peer to wait for.

✅ **§3 disk I/O counters** — in **`sysinfo`#35's tail at `+104 + tag*16`** (sectors read / written,
min length 200), keyed by `blk_enum`#75's tag list as you asked — and by the RAW tag, slot 0 wasted, so
you use the same value #75 gave you with no `-1`. ⛔ First minted as `blkstats`#105 and **withdrawn**:
a closed 5-value tag enum over flat arrays is a fixed-size tail block, not a syscall. The number would
have been permanent surface for every consumer, gate and peer. ⚠ **SECTORS, not bytes, deliberately**: this
layer moves exactly one sector per call, and a byte figure needs the per-device LBA size — which can
be 4096, a live latent path here. Multiply by `blk_info`#79's reported size. Cyrius peer filed at
`cyrius/docs/development/issues/2026-09-02-agnos-syscall-105-blkstats-wrapper.md`; until it lands,
issue 105 raw.

✅ **§4 per-process CPU time — the one you said changes what a monitor can be.** Live in
`proclist`#99's `+56` **low u32**, in 100 Hz ticks (one tick = 10 ms, the unit `uptime_ms`#40 already
uses). Charged in the timer ISR to `proc_current_get()` on **every CPU** — outside the BSP-only gate,
because each CPU runs a different process. Zeroed at slot ALLOC, not at reap, so a monitor sampling
between exit and reap never sees a live process with 0 ticks. Saturates rather than wraps.

✅ **§6 mount enumeration** — `mountlist`#104, shipped and boot-proven. ⭐ You said "do not prioritise
this"; crab filed the same ask the same day with a case you did not have — **aliasing** — and it
changed the verdict. Details in the archived crab record.

✅ **§0a** stale `statfs` comment deleted. ✅ **the console `kprintln`** — both `proclist` and `ptrscan`
one-shots now go to the klug ring, not the console, so `shu -p` is clean.

⚠ **§7 load average** is settled repo policy, not a pending question: `agnos-userland-abi.md:239` rules
load-avg out of the kernel by name. Your userland-tally plan is the intended path.

✅ **§5 per-process RSS — LANDED.** `proclist`#99's `+56` **high u32**, in 4 KiB pages.

⭐ **It is COMPUTED, not accounted — which is what you predicted**: *"the kernel must already know each
address space's extent to tear it down, so this may be recording a number it computes."* It walks the
process's page directory and counts PDEs that are **present AND user**, 512 pages (2 MB) each.

⛔ **The incremental version was built first and cannot work** — recorded so nobody re-attempts it. The
ELF loaders map every segment into the new `cr3` **before** `proc_set_cr3` binds it to a slot
(`elf.cyr` — the mapping loop is ~250 lines above the bind), so no slot owns that cr3 at charge time
and every charge is dropped.

⭐ **The measured topology, since it is the part that took the work.** A probe build dumped the walk
for every live slot:
```
pid=6 cr3=ffd7000 pml4e=ffd6027 pdpte=ffd5027 pd=ffd5000 present=129 user=3
pid=5 cr3=ffda000 pml4e=ffd9027 pdpte=ffd8027 pd=ffd8000 present=130 user=4
pid<=4 cr3=1000 (the BOOT address space)                  present=512 user=0
```
`PML4[0] → PDPT[0] → PD` is exactly right. `present` is ~129 because `proc_create_address_space` fills
PD[0..7] kernel-identity and PD[8..63] identity-**supervisor** (flag `0x83`, no US bit). **Only the
loader's `0x87`/`0x85` mappings carry US** — so the US test is the whole discriminator, and a walk
without it reports ~258 MB of kernel window as every process's RSS. The gate asserts a ceiling that
catches exactly that, mutation-proven.

⚠ An earlier note in this file said §5 "was attempted and did not land, the walk finds zero present
PDEs". **That was a stale-build measurement, not a real result** — the walk was correct the whole time.
Corrected rather than deleted, because a wrong measurement recorded as fact is what this tracker keeps
finding.

✅ **§8 — CLOSED, all five sub-items, three of them by NOT building anything.**

* **Per-core CPU utilisation — SHIPPED**, appended to **`sysinfo`#35 at +40** (min length 104):
  `+40 + cpu*16 + 0` = user ticks, `+8` = kernel ticks, 4 CPUs. ⛔ First built as a new syscall
  `cpustat`#106 and moved — #35 already takes a length and the ABI rule is "append at the tail", so
  the number was needless and would have cost a third cyrius release. `sys_sysinfo(buf, len)` already
  exists, so **you read this with no toolchain change at all**. A caller passing len=40 is
  byte-identical to before. Split by the **privilege of the interrupted context** in the timer ISR — Linux's
  `%us`/`%sy`, computed the same way, exact rather than sampled. You said this "follows naturally
  from §4"; it did.
  ⛔ **But there is no `idle` field, and that is the answer, not a shortfall.** agnos has no single
  idle loop to instrument: `arch_wait()` (a bare `hlt`) is called from ~a dozen polling waits — DHCP
  retry, `sleep_ms`#41, `kbd_read_blocking`, the NIC drain — so a CPU **halted inside a blocking
  syscall is indistinguishable at the tick boundary** from one doing real kernel work. Both are ring 0.
  ⇒ **Field 1 is "system + halted", not "busy-system".** Compute `user / (user + kernel)`; do not
  render field 1 as CPU consumed. We declined to guess idle from the saved RIP or to flag one
  `arch_wait` site and not the other eleven — that is a plausible-looking wrong number, and this cut
  already declined one of those for RSS.
* **cached / buffers — CLOSED, no work.** You read the ABI's omission as deliberate. It is; it stays.
* **swap — CLOSED, no work.** No swap subsystem exists and none is planned. Correct for the design.
* **Per-process start time — NOT BUILT, and here is the cost so you can decide if it is worth it.**
  `proclist`#99's 64-byte record is now **full**: `+56` carries cpu ticks (low u32) and rss pages
  (high u32) as of this cut. A start time needs a WIDER record, which per this doc's own rule means a
  **new syscall number**, not a widening — so it is a real ABI decision rather than a field. Not taken
  on our own initiative for an item you filed as informational. **Say the word and it gets a number.**
* **Network interface enumeration — NOT BUILT, deliberately.** Your own note says there is exactly one
  implicit interface. An enumeration that always returns 1 is ceremony, and it would freeze an ifindex
  ABI before a second interface exists to shape it. Worth doing the day a second NIC does.

⚠ **WHAT THIS SHIPPED WORK BROKE, checked before archiving per the folder rule.**
1. **Nothing is pending.** `syscall-abi-check.sh` reads `kernel 106 · abi-doc 106 · cyrius 106` — all
   agree, `check.sh` 32/32. §8 needed no new number once it was appended to `sysinfo`#35, so there is
   **no third cyrius ask** outstanding for this filing.
2. ⚠ Two asks were spent getting here that should have been one: `#104` (cyrius 6.5.43) and `#105`
   (6.5.44) were filed separately although both came from THIS filing, whose full surface was known at
   triage. That is recorded in the CHANGELOG as a process lesson, not glossed. `check.sh` is otherwise 32/32, `test.sh` 4/4, and every boot smoke is unchanged.

⚠ **ONE ASSERTION IN THE GATE IS DELIBERATELY NARROW, and it is the one that matters.** §8 asserts that
**USER ticks specifically** moved, not that user+kernel grew. A total-only assertion passes on a kernel
whose RPL mask is wrong — everything charged to kernel, totals still plausible. Mutation-proven:
inverting the ring test yields exit 73 with that diagnosis.

**All of the above is boot-proven, not compiled**: `scripts/harness/telemetry-test.py` +
`tests/telemetry/tlm.cyr`, exit 95. ⛔ The oracle is **"the counter MOVED"**, not "the counter is
readable" — a declared-but-never-incremented variable reads 0, which looks like a valid answer, so
every assertion samples, generates real load, and requires an increase. Mutation-proven on two axes.

---

**Filed by:** chakshu (the AGNOS system monitor), during the v0.9.8 cut that put a real
process table on AGNOS for the first time.

**Checked against:** agnos worktree **1.56.58** — `VERSION` reads 1.56.58, but `HEAD`
is `3e4faa0` whose `VERSION` is **1.56.57**, and the worktree is dirty (76 files, **9 of
them under `kernel/`**). Line numbers below are from the **worktree**, not from `3e4faa0`;
re-derive them by symbol name if they do not land. (Do not cite the newest git tag —
tags lag the VERSION file badly here.)

**Authorities read:** `kernel/core/syscall.cyr` (`fn ksyscall` @ :8300) **and**
`kernel/arch/x86_64/syscall_hw.cyr` (`fn syscall_handler` @ :114 — `#44` and `#96`
dispatch here and never reach `ksyscall`, so a negative derived from `syscall.cyr` alone
is unsound; both were checked). Plus `docs/development/agnos-userland-abi.md`.
`sh scripts/check/syscall-abi-check.sh` → `kernel 104 · abi-doc 104 · cyrius 104`, so
there is **no kernel-vs-cyrius drift** in the number set on this checkout.

> **Nothing here blocks chakshu.** `#99 proclist` landed the thing that did, and the
> monitor ships. Everything below is a column that currently renders `n/a`, ordered by
> value ÷ effort. Please treat this as a menu, not a bug report.

---

## 0. First: what is NOT a gap, and a correction we owe you

`#99 proclist` (agnos 1.56.47) is **the fix**, and it worked first try. chakshu's AGNOS
process table now lists pid / state / ppid / name for every live process, verified on a
real kernel under QEMU.

We owe you a correction. chakshu's roadmap recorded the empty process table as "blocked
upstream, no chakshu-side workaround" for **five releases after you shipped the syscall** —
the cyrius wrapper has been there since 6.5.35. Nobody on our side re-read the syscall
table. That was our failure, not yours.

**Also not gaps** — we assumed volume capacity was missing, which is what prompted this
audit. It is not:

| Need | Provided by |
|---|---|
| Filesystem capacity (total/free/avail) | `statfs` **#103** — and on **all three** backends |
| Block-device enumeration + geometry | `blk_enum` **#75**, `blk_info` **#79** |
| Total / free physical RAM | `sysinfo` **#35** (+8, +16) |
| CPU core count | `sysinfo` **#35** (+32) |
| Uptime | `uptime_ms` **#40**, `uptime_us` **#95** |

### 0a. One stale comment worth deleting

`kernel/core/syscall.cyr:9345-9347` still says FAT/exFAT statfs is "filed as a follow-on
rather than half-built" — but the arms at **:9366** (`be103 == FS_FAT`) and **:9371**
(`be103 == FS_EXFAT`) implement exactly that, and the ABI doc is correct. The comment is
what nearly made us file a phantom gap. Cheap to delete.

---

## 1. Expose packet counters  ·  *smallest ask*

**Both network paths already count packets. Neither is reachable from ring 3.**

- **virtio-net** (what `agnos_qemu.py` runs): monotonic ring indices
  `vnet_tx_idx` (`kernel/core/virtio_net.cyr:93`, incremented :430) and
  `vnet_rx_used_last` (:87, incremented :453). Nothing reads them.
- **r8169** (real iron): `r8169_dump_stats()` (`kernel/core/r8169.cyr:1054`) DMAs the
  RTL8168 hardware tally block; only two boot self-tests read it.

*(An earlier draft of this issue claimed packet counts were r8169-only and therefore
absent under QEMU. That was wrong — the virtio indices exist too, which makes this ask
testable in CI.)*

One getter shaped like `net_config` #61 — `net_stats(field) -> u64` — would give a monitor
a packets/sec line. Byte counters (§2) are what users actually expect, but these are
already in hand.

## 2. Per-interface rx/tx **byte** counters  ·  *the network rate line*

**Genuinely absent at every layer**, verified against a control grep (54 hits for a term
that does exist, 0 for every byte-counter spelling).

chakshu's Linux path double-samples `/proc/net/dev` and differences the byte columns. With
no counter there is nothing to difference, so `net:` reads `n/a`.

Two cumulative u64s incremented in the send/receive paths, read through the §1 getter,
would be enough — a monitor does the differencing and rate maths itself. **Monotonic and
never reset** is the only hard requirement.

## 3. Per-device disk I/O counters  ·  *the disk rate line*

**Genuinely absent, and absent internally too** — so this is *implement counters*, not the
cheaper *expose existing counters*. `kernel/core/block.cyr` declares four module vars
(`blk_active`, `blk_capacity`, `blk_lba_bytes`, `blk_registered`) plus `blk_lba_by_tag[6]`
— zero statistics. The one accumulator in the whole block path is `nvme_io_submit_count`
(`kernel/core/nvme.cyr:736`): NVMe-only, counts submissions not bytes, no read/write split,
and reset by `bench.cyr` around measurement windows.

Cumulative sectors-or-bytes read and written, ideally keyed by `blk_enum` #75's existing
tag list so it composes with what is already there.

## 4. Per-process CPU time  ·  *highest value for a monitor*

**Genuinely absent, and structurally so.** `kernel/core/proc.cyr:27`
`struct Process { pid; state; rsp; rip; …r8–r15; rflags; cr3; exit_code; }` — 22 fields ×
8 B, matching the 176-byte stride at `:29`. It is all register state; there is nowhere to
put a tick count and no parallel array holds one.

`#99 proclist` already reserves `+56` for this and documents that the record size will not
change when it lands. A tick counter incremented in the context-switch path, surfaced at
`+56`, turns CPU% from `n/a` into a real column — the thing people open a monitor to see.

## 5. Per-process RSS / mapped size  ·  *the memory column*

**Genuinely absent** — no `proc_rss` / `rss_pages` / `proc_pages` equivalent. System-wide
memory works via `sysinfo`, so only the per-row breakdown is missing. The kernel must
already know each address space's extent to tear it down, so this may be recording a
number it computes rather than new accounting.

## 6. Mount-table enumeration  ·  *expose existing state, low priority*

No syscall — but **the kernel holds the table**: `vfs_mnt_count` (`kernel/core/vfs.cyr:373`),
`vfs_mnt_prefix[64]` (:376), `vfs_mnt_prefix_len[8]` (:375). Those symbols appear in no
file but `vfs.cyr`; `syscall.cyr` never reads them. So this is a getter, not a subsystem.

⚠ **Do not prioritise this.** `mount` #11 and `umount` #24 are both `return 0;` no-ops, so
the table is fixed at boot by `vfs_mount_init()` (`vfs.cyr:396`) to at most `/`,
`/mnt/fat`, `/mnt/exfat`. A monitor can statfs those three and skip the `-1`s — complete
and correct today. **The gap becomes real only when `mount` #11 stops being a no-op.**

## 7. Load average  ·  *probably ours, not yours*

`sysinfo` #35 writes five u64s and has no `loads[]`, so our header reads `load: n/a`.

**This likely needs nothing from you.** A monitor can tally `proclist`'s `+8` state field
in userland for an instantaneous runnable count. Not a 1/5/15-minute average, but honest
and free. `proc_count_by_state()` (`kernel/core/proc.cyr:498`) also already exists,
currently called only by boot self-tests. **We will try the userland route first.**

## 8. Also absent — lower value, listed for completeness

- **Per-core CPU utilisation** — no idle/busy accounting at any granularity (0 hits for
  `idle_ticks`/`busy_time`/`cpu_busy`/`percpu_ticks`). Follows naturally from §4.
- **cached / buffers** — and the ABI declines these explicitly rather than having
  overlooked them, which we read as a deliberate choice.
- **swap** — no swap subsystem exists at all. Correct for the design; noted only so the
  absence is not mistaken for an oversight.
- **Per-process start time** — no creation path records a timestamp
  (`proc_create_full` / `proc_create_user`, `kernel/core/proc.cyr:506`).
- **Network interface enumeration** — no ifindex, name, MAC or link-state surface; #61
  takes a field selector only. There is exactly one implicit interface.

## 9. Explicitly NOT requested

**Per-process uid.** `getuid` #15 is the literal `return 0` (`syscall.cyr:8657`) and no
per-task uid exists anywhere in the kernel (0 hits for every spelling, against a control
of 26 for `exit_code`). AGNOS is single-user — that is a coherent design choice, not a
gap. chakshu renders `root`, which is **true**, rather than `n/a`. **Please do not add a
uid on our account**; it would imply a multi-user model that does not exist.

---

## One small annoyance, cheap to fix

`kernel/core/syscall.cyr:10213` `kprintln("proclist: first call from ring 3", 32)` writes
to the console on first call. The diagnostic intent is sound — the comment explains it
separates "nobody called proclist" from "proclist found nothing", which are bugs in
different repos — but it lands **inside the monitor's output**:

```
cpu:  n/a   disk: n/a   net: n/a
[   37.727698] proclist: first call from ring 3     <-- here
   PID USER      S  CPU%  MEM% CMD
     1 root      R   n/a   n/a []
```

`shu -p` is chakshu's pipe-safe mode (our design-spec calls it "sacred for pipes"), so
this corrupts any consumer parsing that stream, and it would scribble over a TUI frame.
`ptrscan` #98 does the same at `:10123`.

Suggestion: keep the one-shot, but behind the existing debug-verbosity gate, or emit to
the kernel log ring rather than the console.

---

## Summary

| # | Capability | Verdict | Ask |
|---|---|---|---|
| 1 | Packet counters (virtio **and** r8169) | counted, not exposed | one getter |
| 2 | Network byte counters | absent | 2 counters + getter |
| 3 | Disk I/O counters | absent internally too | implement + expose |
| 4 | Per-process CPU time | absent (no struct room) | tick → `proclist` `+56` |
| 5 | Per-process RSS | absent | record a known number → `+56` |
| 6 | Mount enumeration | held in `vfs.cyr`, not exposed | getter — **low priority** |
| 7 | Load average | absent | *chakshu to try userland first* |
| 8 | per-core CPU / cached / swap / start time / iface enum | absent | informational |
| — | `proclist` console `kprintln` | present | gate it |

If only one gets done, **§4** is the one that changes what a system monitor can be on
AGNOS.
