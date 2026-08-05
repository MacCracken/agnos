# `#97 chan_op` — the local-IPC channel band: designed, decided, numbered, and now MINTED (bites 0-4a)

**Status:** 🟠 **IN PROGRESS — bites 0-3 done, 4a landed, 4 blocked on cyrius.** Filed 2026-08-05.
⭐ **`#97` is MINTED**: agnos 1.56.40 ships the dispatch arm, a boot-reserved 2 MB region and `CH_CAPS`.
🔴 **Blocked**: the cyrius peer has no `SYS_CHAN_OP = 97`, so the ABI gate correctly reds `check.sh`
(`kernel 97 · abi-doc 97 · cyrius 96`) and the ring-3 half of the region kill-criterion cannot be
written. Filed against cyrius and marked ACTIONABLE there —
[`2026-08-05-agnos-syscall-peer-...`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-08-05-agnos-syscall-peer-two-new-numbers-and-a-circular-authority.md) §2.
⚠ Bite 4a proves the region reachable under the **kernel** CR3 only; §9.9 names the **spawned-client**
CR3, and that half is what the cyrius constant unblocks.
**Number:** **`#97`** — ⭐ **settled 2026-08-05.** `#96` stays with `fork`
([`2026-08-05-syscall-96-fork.md`](2026-08-05-syscall-96-fork.md)). Next free is **`#98`**.
**Cross-repo:** agnos (kernel) **+ cyrius** (`lib/syscalls_x86_64_agnos.cyr`) **+ setu 0.8.0** **+ aethersafha**.
**Severity:** High — it is the desktop arc's remaining architectural item, and the transport it replaces
is already ruled a wrong premise, so the current path is deprecated with nothing shipped behind it.
**Affects:** agnos 1.56.40 (in progress).

## Summary

The sovereign display protocol runs its control channel over **TCP on loopback:7700**. That was reuse,
not design — setu 0.1.0 was AF_UNIX, agnos has no AF_UNIX, agnos did have a TCP stack. The operator
ruled on 2026-08-03 that this is the **wrong primitive** for local display IPC: nothing to route,
nothing to checksum, no window to negotiate, no RTO, and no business owning a port.

The replacement is a kernel-owned channel band on **one** syscall, where authority is re-derived per
operation so an **inherited handle is inert by construction**, a child is **placed** holding a
connected end rather than dialling, and **the batch IS the poll**.

⭐ **The design is DONE and must not be re-derived.** Four surveys, three fully-worked candidate
designs, twelve judge verdicts, and the landed synthesis all live in
[`../planning/ipc.md`](../planning/ipc.md) — §9 is the design, §9.6 the twelve-bite migration, §9.9 the
kill criteria, §10 the TCP removal inventory. This ticket exists to track *building* it, not to
reopen it.

## Naming — settled, and it is a rule

⛔ **It gets no codename.** The design carried a Sanskrit working name (`anu`) and ipc.md §9.7 spent one
of its six operator decisions choosing it. Operator, 2026-08-05: *"it doesn't need a special name, it's
in the kernel — unless we're splitting it out to its own repo."*

Band **`chan_*`**, VFS tag **`VFS_CHAN = 11`** (verified free — `vfs.cyr` tops out at `VFS_SOCK = 10`),
ops **`CH_*`**. That is the convention `pipe_*` / `shm_*` / `sock_*` / `net_*` already use. A name is a
*distribution* fact — it exists so a thing can be found across a repo boundary, and a band that never
leaves one kernel has no boundary to cross. Memory: [[feedback_naming_lanes]].

## Sequencing

⭐ **Unblocked.** ipc.md §9.7 item 3 made bites 4–9 wait on K1 (the `-smp 4` PT_LOAD fault); **K1 is
done** — agnos 1.56.35, `EFER.NXE` never enabled on the APs, `smp.cyr:514`.

**Progress — all in agnos 1.56.40:**

| bite | what | state |
|---|---|---|
| **0** | Delete the bare `arch_wait()` in `epoll_wait` — `hlt` with no `sti` inside an IF=0 handler | ✅ **DONE.** It hung the box on an unexpired timerfd. Regression lock + negative control |
| **1** | shm **owner + epoch**, released at both death sites; `shm_free #74` gated on owner | ✅ **DONE.** `#72`/`#73` warn-counted, never refused. ⚠ Measured INERT in the desktop workload — the selftest is its coverage |
| **2** | `proc_epoch[16]`, written and **never read** | ✅ **DONE**, bumped in `proc_alloc_slot` |
| **3** | Host semantic proof over `socketpair(SOCK_SEQPACKET)` | ✅ **DONE.** 18 assertions in `check.sh`; negative control over `SOCK_STREAM` fails exactly the 6 framing ones |
| **4a** | `#97` + the 2 MB region + `CH_CAPS` | ✅ **LANDED.** ⚠ Region proven under the **kernel** CR3 only |
| **4b** | the ring-3 half of the region kill criterion, then mint/close/send/recv | 🔴 **BLOCKED on cyrius `SYS_CHAN_OP = 97`** |

## Kill criterion worth repeating here

⭐ If bite 5's selftest shows a record delivered to or accepted from an **inherited (non-endowed)** fd
in a spawned child, **inert-by-construction is false and the whole authority model dies with it** —
along with the kavach sandbox story. Test that before any userland exists, not after.

## ⛔ It REPLACES TCP. It is not a second transport.

No fallback, no compile-time option, no runtime switch, no rollback to loopback:7700. Revertibility
comes from **bite order** — bites 0–5 land no consumer — not from keeping the rejected path alive. An
earlier synthesis kept TCP through three bites and was rejected on 2026-08-03: that came from a
*"the desktop must run at the end of every bite"* rubric, which scores preserving the old path highest
and is the wrong rubric for a design whose purpose is to delete that path.

## Pointers

- Design, migration, honest costs, kill criteria → [`../planning/ipc.md`](../planning/ipc.md) §9–§10
- Desktop arc ladder and substrate matrix → aethersafha [`planning/desktop.md`](https://github.com/MacCracken/aethersafha/blob/main/docs/development/planning/desktop.md)
- ⚠ Before treating the ABI table as complete → [`2026-08-05-abi-doc-covers-two-thirds-of-the-syscalls.md`](2026-08-05-abi-doc-covers-two-thirds-of-the-syscalls.md)
