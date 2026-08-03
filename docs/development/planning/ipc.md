---
name: AGNOS Local IPC — what an agnos socket is
description: The single source of truth for the local-IPC / agnos-socket question — the design session's surveys, its three candidate designs, the judge panel's verdicts, and the decision that is still outstanding.
type: planning
---

# What an agnos socket is

> **This is THE local-IPC document.** It is to the socket what
> [`gpu.md`](gpu.md) is to the GPU: one file, exhaustive, no sibling arc docs.
> Opened 2026-08-02.
>
> ⛔ **THE DECISION HAS NOT BEEN MADE.** Three designs are fully worked and twelve judge verdicts are
> in. What is missing is one synthesis, and §7 says exactly what it needs to resolve. Do not implement
> from this file yet; do not re-run the design phase either — it is done and it is below.

**Last refresh** 2026-08-02.

---

## 1. The question

The operator's framing, verbatim in substance:

> *What IS an agnos socket? How can we improve upon the Unix socket while not bringing over the
> baggage, and planning for an innovative future on a sovereign OS?*

Three parts. A design that answers only the first two has not answered it.

**Why it is live now.** The sovereign display protocol runs its control channel over **TCP on
loopback:7700**. That was reuse, not design — setu 0.1.0 was AF_UNIX, agnos has no AF_UNIX, agnos did
have a TCP stack. What rode along: `net_ip` source-address semantics and 4-tuple matching · a **DHCP
dependency for a local display protocol** · a `net_ip == 0` case unfixable from ring 3 because
`net_is_loopback` excludes 0 · `sock_connect #47` blocking with preempt disabled · and a ~2 KB loopback
window the pixel path already had to escape via `sys_shm`.

**The pixels left TCP a month ago. Only the small control channel still drags the network stack behind
it.** And the same shape appeared twice independently: mishran, the audio mixer, converged on *tiny
control channel over TCP (port 7701) + bulk in shm* without being told to.

**It is also the PTY question.** Decompose a PTY and it is (i) a bidirectional local channel, (ii) a
way to hand one end to a child at spawn, (iii) a line discipline. Only (iii) is terminal-specific. So
`/bin/puka` is downstream of this file, not parallel to it — see
[aethersafha `desktop.md` §5 D2](https://github.com/MacCracken/aethersafha/blob/main/docs/development/planning/desktop.md).

---

## 2. Provenance — where this came from, and how it was nearly lost

A 20-agent design workflow named **`agnos-socket-design`** ran on **2026-08-02** and completed its
Survey, Design and Judge phases. Its final **Decide** agent died with the account, so the workflow
returned `{decision: null, designCount: 3, judgeCount: 12}` and the substance appeared to be gone.

It was not. Every agent's return value survived in the run journal, and was recovered on 2026-08-02:

| Artifact | Count | Size |
|---|---|---|
| Surveys (agnos IPC surface · setu's measured needs · non-setu consumers · prior art) | 4 | ~168 KB |
| Full candidate designs | 3 | ~167 KB |
| Judge verdicts (4 lenses × 3 designs, each with `falsePremises` + `fatalFlaw`) | 12 | ~131 KB |

Extracted JSON:
`~/.claude/projects/-home-macro-Repos-agnosticos/7505acab-1cf0-4dc6-a785-d258fc02ed89/socket-design-extracted/`
Source journal: the same session's `subagents/workflows/wf_33810d40-2b7/journal.jsonl`.

⚠ A second workflow (`agnos-socket-decide`) was launched on 2026-08-02 to run the missing phase and
**failed in full** — all 8 agents errored on a weekly account limit before returning anything. The
decision is therefore still outstanding, and nothing in §7 has been superseded.

⭐ **The lesson worth keeping:** a workflow's return value is not its output. Phase results live in
`journal.jsonl` and survive the run that produced them.

---

## 3. The constraints any answer must survive

Measured, from the surveys. A design that violates one of these is not a candidate.

### Kernel mechanics
- **No blocking in the kernel.** Syscalls run **IF=0** and run to completion on a **shared per-CPU
  kernel stack** (the serial-kstack invariant). There is **no blocked process state**: `sched_next`
  selects only `state == 1`, and `do_context_switch` **unconditionally** resets any non-dead
  descheduled proc back to ready — a line whose own comment cites an iron attempt as the reason it is
  unconditional.
- The two shipped answers to "must wait" are **(a)** return WOULD_BLOCK and let ring 3 poll
  (`waitpid #4`, `sock_recv #49`, `sock_accept #57`, `flock #59`) or **(b)** `preempt_disable(); sti;
  hlt`-spin (`sleep_ms #41`, `sock_connect #47`, `sock_send #48`, `snd_write #66`).
  ⛔ **(b) is exactly what made TCP toxic for a display protocol** — it starves the peer it is waiting
  on. All three designs independently refused (b). A design whose wait answer is (b) recreates the
  failure it exists to fix.
- **Table sizes are the house style**: 16 procs · 32 fds/proc · 16 shm slots **at 2 MB granularity
  each** · 8 TCP conn slots (a loopback connection costs **two**) · 8 epoll watches · 4 snd slots. Any
  new table is the same shape and the same order of magnitude.
- **`kmalloc` tops out at 4096 B** (slab classes 32…4096; `slab_class_for` returns −1 above it), so
  4096 is the natural single-allocation unit for a ring.
- **User pointers must lie in `[0x200000, 0x40000000)`**, wrap-checked. No SMAP-free path.

### Identity
- **No uid/gid anywhere** — `getuid #15` returns a constant 0. No design may lean on credential
  triples, mode bits, or ownership-by-user. (This is a freedom, not only a lack: there is no 40-year
  ABI to stay compatible with.)
- **pids are recycled slot indices with no generation counter**, so a pid is not a durable identity.
  Stamped identity needs an epoch, or must reference the object rather than the pid.

### Doctrine
- The agnos roadmap **bans POSIX `socket()` emulation and foreign-ABI absorption**, and states the bans
  do not expire.
- AGNOS's published **CVE-2026-31431 immunity argument is anchored on the ABSENT socket/splice
  surface**. Any new local-IPC surface must stay small enough that the claim survives it.
- **The kernel grows per native workload, never to match Linux** — every new syscall needs a real,
  named, *today* consumer.

### Workload, measured
- **No production setu message exceeds 64 bytes**; the protocol ceiling is 80 (`SETU_MAX_ARGS = 8`).
  mishran's control frames are 48 B. **A record channel, not a stream.**
- Steady-state control traffic is **0 B/s (crab) to ~3 KB/s (doom at 35 Hz)**, plus 40 B per key.
  ⭐ **This channel is essentially idle. Do not design for throughput — design for latency and for a
  cheap "nothing pending" answer.**
- **Pixels and PCM are already off the wire and must stay there.** Only the control channel is in
  scope.
- **No back-pressure is wanted.** Presents are idempotent overwrites; input is droppable *except* that
  a lost key-RELEASE sticks a key. Bounded-queue-with-drop or newest-wins is correct.

---

## 4. ⛔ Corrected fact — fd inheritance to a `spawn_path #43` child EXISTS

This correction was made independently by three investigators and **verified directly** against the
kernel on 2026-08-02. It matters because "hand a child a pre-connected channel" is load-bearing in all
three designs, and because the opposite is currently asserted in the desktop arc doc.

- `proc_create_user` calls **`vfs_fd_inherit(idx, proc_current_get())` unconditionally**
  (`kernel/core/proc.cyr:394`). Its own comment names it *"The single inheritance point for every user
  proc (elf_load / elf_load_from_file / spawn)."*
- `vfs_fd_inherit` kmallocs a fresh 1024-byte table and **byte-copies the creator's 32 entries**
  (`kernel/core/vfs.cyr:167-175`).
- **`elf_load_from_file` — the `#43` path — routes through `proc_create_user`** (`kernel/core/elf.cyr:460`).

So a channel end minted by the compositor **before** `sys_spawn_path("/bin/crab", …)` is **already in
the child's table at the same index**.

⛔ **What is actually missing is not transfer — it is placement and announcement.** The child does not
know *which* index it holds. `exec_redirect #62` is the narrower *placement* mechanism, and it is
genuinely one-shot and `execwait #37`-only. Announcement can ride the env blob `spawn_path #43`
already accepts and validates (flat `KEY=VALUE`, ≤1024 B, 1..16 entries, staged onto the child's SysV
init stack) — which is precisely Wayland's `WAYLAND_SOCKET` trick, and the cheapest high-value steal
available.

---

## 5. The three candidate designs

All three refuse a byte stream, refuse to carry bulk, and refuse blocking-mode (b). They differ on
**where the queue lives** and **what confers authority**.

### A — `dvara` (द्वार, *door/gate*), the local **record socket**

*A socket you would recognise on sight, with every AF_UNIX wart corrected in the primitive rather than
bolted on as an option.* Kernel band `dv_*`, syscalls **#96–#102**, VFS tag `VFS_DVARA = 11`.

- **Object**: 16-slot endpoint table shared between PORTs (bound, listening) and CHANNEL ENDs. A
  connection costs **two** slots, one per end, each independently owned and reclaimed.
- **Ring**: one 4096-byte kmalloc per channel end = **32 records × 128 B** (8-byte length + 120-byte
  payload). Head/tail live in kernel arrays, **not** in the fd payload — which is named as pipe's
  existing bug, since `vfs_fd_inherit`'s byte copy duplicates a tail stored there and yields broadcast
  rather than stream semantics.
- **Name**: a **bounded kernel name table** — 16 × 32 B, up to 31 opaque bytes. No inode, no mode bits,
  no umask, no unlink-before-bind, no stale socket file, no abstract-namespace hack.
  ⭐ **Its luckiest fact**: every setu entry point *already* carries a vestigial `path` argument that is
  documented as advisory and ignored, and every consumer already passes the same string. dvara makes
  that argument real **with zero signature change at every call site**.
- **Authority**: the fd is **not** the capability — `{slot, epoch, owner_pid}` is re-checked on every
  operation, copying the discipline `snd_*` already ships. An inherited fd copy in a spawned child is
  **inert by construction** — CLOEXEC's job, done without CLOEXEC (which agnos does not have).
- **Peer identity** is a return value of `accept`/`connect`, not a `getsockopt` you can forget. **Peer
  death is a state on the object**, not an errno you discover on the next write.
- **Budget**: the desktop is 5 of 16 slots today; +mishran = 8. Nine free. Tight but deliberate.

**Its case against AF_UNIX**: `SOCK_STREAM` has no message boundaries, so every protocol on it
reinvents length-prefixing — **and in this ecosystem it has been rebuilt four times** (setu, mishran,
majra, bote, each with its own framing). AF_UNIX *has* the right type, `SOCK_SEQPACKET`, and 40 years
of practice ignored it because `SOCK_STREAM` was the default. dvara makes the good type the only type.
*"A default that four independent consumers work around is not a default, it is a tax."*

### B — `dvara` as a **capability endpoint** (*"the door you were given"*)

*An agnos socket is not dialed — it is GIVEN.* Syscalls **#96–#101**. **No name, no bind, no listen,
no connect, no accept.**

- Ends are acquired exactly three ways: **mint a pair**, **inherit one at birth** through the fd-table
  copy agnos already does, or **receive one inside a message** on an end you already hold. There is no
  fourth way, so **a stranger has nothing to dial** — the who-can-talk-to-whom graph is exactly the
  transitive closure of who handed what to whom, rooted at PID 1.
- The kernel stamps **granter-chosen `{epoch, badge}` provenance** into every delivered record, so the
  receiver never has to ask who the sender is *and cannot forget to*.
- **Ring**: 4096 B per end = 16 records × 256 B (8 B kernel header + 248 B payload) — 3× setu's ceiling
  and deliberately too small for bulk.
- Steals, named: **seL4** badged endpoints · **Binder** (the *driver* stamps provenance) · **zircon**
  channels (atomic datagrams, handle MOVE, PEER_CLOSED as an object property) · **Mach** ports (rights
  as payload) · **Wayland's `WAYLAND_SOCKET`** (an already-connected channel inherited at spawn and
  announced by env var — *the cheapest high-value steal, needing zero new transfer mechanism*).
  Deliberately **not** taken: X11 MIT-SHM's global integer shmid (*that is the status quo and it IS the
  failure mode*) · page remapping · seL4 synchronous rendezvous (*a compositor cannot block on a
  client*) · priority inheritance (*the scheduler is flat round-robin; there is nothing to inherit*).
- **Its sharpest point**: agnos has already reproduced AF_UNIX's authority bug on its own —
  `tcp_listen`'s only gate is a duplicate-bind refusal with **no owner and no privilege check**, so any
  of the 16 processes that binds 7700 before the compositor **owns the display protocol and receives
  every client's keystrokes**.

### C — `sanketa` (संकेत, *an agreed signal at an appointed place*)

*There is no agnos socket. There is an shm slot and a convention.* **One** new syscall, `shm_op` **#96**.

- agnos's distinctive starting condition is a kernel-owned, id-addressed, **every-CR3-reachable**
  memory object that is *already* the desktop's real transport. Two subsystems independently converged
  on "tiny control channel over TCP + bulk in an shm slot". **sanketa's claim is that the convergence
  points at the wrong half: the shm slot is not the workaround, TCP is. Put the queue in the slot too.**
- A channel is a slot whose first 128 bytes are a header and whose remainder is **two SPSC byte rings
  with 64-bit monotonic cursors**; records are length-prefixed and published by advancing a cursor, so
  one send is one recv by construction. The kernel learns nothing about connections, peers, listen or
  accept.
- The kernel gains exactly the three things ring 3 **provably cannot do for itself**: reach the page at
  an **offset** (today `shm_write`/`shm_read` copy only at slot base — *which is why a ring is
  literally inexpressible*), an **indivisible word update**, and a **park/wake**.
- It rides the **shipped op-record idiom** of `gpu_shader_op #92` / `gpu_modeset_op #93`: one syscall
  number, an array of 64-byte records, opcode in the payload, validate-all-then-execute-all.
- **Its best structural argument**: a channel's full state — cursors, occupancy, both peers' pids — is
  readable with one read by a debugger, a monitor, or chakshu. *AF_UNIX has never been able to answer
  "how many bytes are queued on that socket and who is behind it" from outside the two endpoints.*
- **Its own named weakness**: SHM_MAX is 16 and `shm_create` calls `pmm_alloc_2mb()` **unconditionally
  regardless of requested size**, so a 64-byte control channel costs a 2 MB page and 1/16 of the table.
  Measured today: the desktop uses 2 of 16 slots at **13.8% byte utilisation**. *Slot pressure is not
  the bottleneck; waste is.* Its proposed fix is a separate 32-entry small-slot table of `kmalloc(4096)`
  = 128 KB of heap for every channel on the box.

---

## 6. The judge panel — scores and fatal flaws

Four lenses, twelve verdicts. Score is 1–10; 7 means *would ship with fixes*.

| Design | sovereignty | correctness | generality | increment | **total** |
|---|---|---|---|---|---|
| **C — sanketa** | 8 | 6 | 6 | **7** | **27** |
| **A — dvara record socket** | 8 | **7** | 5 | 5 | **25** |
| **B — dvara capability** | **9** | 4 | 3 | 5 | **21** |

**No design cleared 7 on generality.** The recurring charges, in the judges' own terms:

- **A, correctness (7):** *"`dv_release_pid` is wired to ONE exit path when agnos has two"* — the
  sibling `flock_release_pid` / `snd_release_pid` / `gpu_release_pid` each appear at **both**.
- **A, generality (5) and B, generality (3):** the primitive is **setu-shaped with a kernel number**.
  *"Its sole evidence that the primitive is not setu-shaped is mishran — and the very line it cites
  says mishran was MODELED ON setu."* An independent second consumer was not established.
- **B, correctness (4):** *"PEER_GONE peer-death detection and 'authority is exactly the grant graph'
  are both silently false."*
- **A and B, increment (5):** both migrations are **self-declared flag days**. B's *first* userland bite
  deletes the listener.
- **C, correctness (6):** the rollout encodes `id = (epoch << 8) | (slot + 1)`, which breaks the first
  16 creates — *"this project's signature bug shipped as the plan."*
- **C, generality (6):** the "no fd, no VFS tag" refusal is sold with only its benefits enumerated.
- **C, increment (7):** the migration **inverts its own risk ranking**.
- **C, sovereignty (8):** *"no false premise survived verification"* — the only lens on any design to
  say so.

---

## 7. ⛔ What is still outstanding — the decision

The design phase is **done**. One synthesis is missing, and it must resolve all of the following. Do
not restart the design phase to produce it.

1. **Where the queue lives** — a kernel object (A/B) or bytes in a shared region (C). This is the
   actual fork in the road; everything else follows from it.
2. **What confers authority** — a re-checked `{slot, epoch, owner}` tuple (A), a granter-minted badge
   (B), or possession of an id in a table with **no owner field at all** (C, the status quo, and the
   judges were right to flag it).
3. **Whether the primitive is genuinely general or is setu-shaped.** Three of four generality verdicts
   say it is not proven. **mishran is not an independent witness — it was modeled on setu.** A real
   third consumer must be named and checked, or the claim must be narrowed honestly.
4. **A migration with no flag day.** The desktop must run at the end of *every* bite. Two of three
   candidates failed this.
5. **The wakeup, phase 2.** All three ship non-blocking-only, correctly. A true blocked state needs a
   new proc state, a `sched_next` that skips it, a ready-edge that flips it back, **and** a relaxation
   of the unconditional reset in `do_context_switch`. That is a scheduler arc, and it should be named
   as one rather than smuggled into this cut.
6. **The third question, which no candidate answered well** — the innovative future. Concretely: the AI
   band (daimon · bote · hoosh · mela · t-ron), where an MCP transport *is* a local IPC channel and
   [`native-display-protocol.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/native-display-protocol.md)
   §2.1/§3.5 **requires the display endpoint be separate from the agent endpoint** ("AI-optional by
   construction"); kavach, where a sandboxed process's channel set *is* its authority; sigil/libro,
   where the question is whether a channel can be attestable or audited without paying per message;
   and the **N in AGNOS** — AF_UNIX's cardinal sin per its own designers is that local and remote are
   different APIs, so either an agnos channel is location-transparent or the name is not a promise.

### Only the operator can settle
- **The name.** All three candidates independently chose `dvara`/`sanketa` from the Sanskrit system-lib
  lane; two are the same word for different objects.
- **Scope against the open cut.** 1.56.35 is open and its ranked K1 is the `-smp 4` PT_LOAD PDE-absent
  fault, which is QEMU-reproducible and blocks the desktop today. This work is K7/K8 in that cut.
- **Whether the PTY rides this or waits.** §1 argues they are one primitive; that is a judgement, not a
  measurement.

---

## 8. Pointers

- **The desktop arc** (open decisions D1/D2, the compositor ladder, the substrate matrix) → aethersafha
  [`planning/desktop.md`](https://github.com/MacCracken/aethersafha/blob/main/docs/development/planning/desktop.md)
- **Protocol design** → agnosticos [`planning/native-display-protocol.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/native-display-protocol.md)
- **The blocking-syscall / two-proc recipe** → [`planning/blocking-syscall-concurrency.md`](blocking-syscall-concurrency.md)
- **Session handoff** → agnosticos [`planning/desktop-arc-handoff.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/desktop-arc-handoff.md)
- **The cut this lands in** → `CHANGELOG.md` [1.56.35]
