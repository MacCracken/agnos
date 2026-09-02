# 2026-09-02 — ring-3 telemetry gaps a system monitor needs

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
