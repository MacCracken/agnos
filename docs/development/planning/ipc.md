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
> ✅ **THE DECISION IS MADE — 2026-08-03: `naadi`.** See **§9**, which is the operative section of this
> file. §§1–7 are the record of how it was reached and remain accurate as history; §7's checklist is
> answered item-by-item in §9. Do not re-run the design phase.

**Last refresh** 2026-08-03.

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
- **Budget**: the desktop is 5 of 16 slots today; +mishran = 8. **Eight free.** Tight but deliberate.
  (⚠ corrected 2026-08-03 — this file previously said "nine".)

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
- The kernel gains exactly the three things the design argues ring 3 cannot do for itself: reach the
  page at an **offset** (today `shm_write`/`shm_read` copy only at slot base), an **indivisible word
  update**, and a **park/wake**. ⚠ The design's phrasing — *"a ring is literally inexpressible today"* —
  was **measured by its own correctness judge as an overstatement** and must not be repeated in this
  file's voice; it is the design's claim, not a finding.
- It rides the **shipped op-record idiom** of `gpu_shader_op #92` / `gpu_modeset_op #93`: one syscall
  number, an array of 64-byte records, opcode in the payload, validate-all-then-execute-all.
- **Its best structural argument**: a channel's full state — cursors, occupancy, both peers' pids — is
  readable with one read by a debugger, a monitor, or chakshu. *AF_UNIX has never been able to answer
  "how many bytes are queued on that socket and who is behind it" from outside the two endpoints.*
- ⛔ **Its actual central weakness — and this file omitted it until 2026-08-03, which let the score
  leader read clean on the lens where it was weakest.** Because the cursors live in the shared region,
  **any process that can reach a channel can write another channel's cursors.** The design's own
  `failureModes` states the consequence in capitals: on the display channel that means **reading every
  keystroke the compositor delivers to the focused window, and injecting keystrokes into it** — with
  **"NO MITIGATION IN v1."** This, not slot waste, is why the fork-in-the-road went the other way (§9).
- **Its other named weakness**: SHM_MAX is 16 and `shm_create` calls `pmm_alloc_2mb()` **unconditionally
  regardless of requested size**, so a 64-byte control channel costs a 2 MB page and 1/16 of the table.
  Measured today: the desktop uses 2 of 16 slots at **13.8% byte utilisation**. *Slot pressure is not
  the bottleneck; waste is.* Its proposed fix is a separate 32-entry small-slot table of `kmalloc(4096)`
  = 128 KB of heap for every channel on the box.

---

## 6. The judge panel — scores and fatal flaws

Four lenses, twelve verdicts. Score is 1–10. ⚠ The gloss *"7 means would ship with fixes"* is
**reconstructed, not recovered** — no surviving artifact states the scale, so treat the numbers as
ordinal within this table only.

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
- **C, correctness (6):** the rollout encodes `id = (epoch << 8) | (slot + 1)`. ⛔ **This file inverted
  the judge's polarity until 2026-08-03 and the inversion mattered.** The flaw is not that the first 16
  creates break — it is that they are **byte-identical to today's**, so the change **tests green on
  every boot smoke** and fails only on a long-running desktop. *"This project's signature bug shipped as
  the plan"* is about a **silent** failure, not a loud one.
- **C, generality (6):** the "no fd, no VFS tag" refusal is sold with only its benefits enumerated.
- **C, increment (7):** the migration **inverts its own risk ranking**.
- **C, sovereignty (8):** *"no false premise survived verification"* — the only lens on any design to
  say so.

---

## 7. The checklist the decision had to clear — ✅ ANSWERED IN §9

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

## 9. ⭐ THE DECISION — `naadi` (नाडी, *conduit / channel / vessel*)

**Decided 2026-08-03.** One syscall **`#96 nd_op`**, VFS tag **`VFS_NAADI = 11`**, kernel band `nd_*`.

> The three §5 designs were re-synthesized against a phase that first adjudicated **64 allegations**
> against the live kernel. The re-synthesized candidates scored **naadi 28** (sov 8 / corr 7 / incr 7 /
> gen 6) · **dvara 27** (8/7/6/6) · **sanketa 26** (8/6/6/6). naadi is the winner's **object model with
> its scope corrected** — all three of its own fatal flaws were resolved, not accepted.

### 9.1 The answer, in one sentence

**An agnos socket is a RELATIONSHIP THE KERNEL REMEMBERS, and a process's authority is exactly the set
of relationships it holds.** It is not a thing you find, open, or dial. Everything else follows —
including why it is not called a socket.

### 9.2 The fork in the road (§7 item 1) — the queue lives in the KERNEL

sanketa put the queue in the shared region with userland cursors and lost on its own evidence: any
process that can reach a channel can **forge occupancy, rewind a peer's consumption, and inject** — on
the display channel, keystroke capture and injection, *"NO MITIGATION IN v1."*

**naadi's cursors live in kernel arrays.** Ring 3 cannot address a cursor, so the entire class is gone.
One **2 MB region reserved at boot**, carved into 32 × 4096 B pages, reachable from every syscall CR3
through the kernel mirror. Pre-reserved rather than 32 `kmalloc`s for three reasons — creation cannot
OOM; it sidesteps the 4096-byte slab ceiling; and **decisively, because channel pages are never
`kmalloc`'d or `kfree`'d, a destructive op inside a validate-then-execute batch cannot produce a
kernel-heap use-after-free.** That is the exact bug sanketa's correctness judge found (`SHO_FREE` then
`SHO_PWRITE` in one batch, writing 8 attacker-chosen bytes to kernel VA `0x100`).

Cursors are **monotonic 64-bit counters that never wrap** — the shape agnos's `pipe` already gets right
(`vfs.cyr:830`, `:848`), so equality means genuinely drained.

### 9.3 The authority inversion (§7 item 2)

A VFS fd, tag 11, spending exactly the **three** payload words the 32-byte slot allows:
`[0] endpoint · [1] channel epoch at claim · [2] cached mode`. **Every operation re-derives authority:**

```
ktag(base) == VFS_NAADI
nd_end_open[e] == 1
nd_ch_epoch[e >> 1] == payload[1]                       — fd-vs-channel staleness
nd_end_owner[e]     == proc_current_get()
nd_end_oepoch[e]    == proc_epoch_get(proc_current_get())  — pid-vs-PROCESS staleness
```

⭐ **The consequence is the whole design.** agnos has **no CLOEXEC** and an unconditional whole-table
fd copy at spawn — so instead of fighting that default, naadi **inverts** it: an inherited copy is
**inert**, every op on it returns −1. A child's channel set is exactly *what was explicitly endowed*.
**A sandbox is DESCRIBED (a list of endowments), not CARVED (a list of denials).** kavach's agnos
backend needs no close-loop and no `landlock_abstract_unix` analogue, because there is no ambient reach
to revoke.

`nd_end_open` is kept separate from `nd_end_owner` because **pid 0 is a real process** (`hda.cyr:258`).
**Peer-gone is derived, never stored**: `peer_alive = nd_end_open[e ^ 1]` — a stored flag can go stale.

### 9.4 The wakeup — **the batch IS the poll**

No blocking in v1, and the reason is the **stack, not a policy**: each CPU has one shared SYSCALL kernel
stack, so N blocked waiters need N disjoint kernel stacks. Both escape hatches are refused — the
`preempt_disable; sti; hlt` spin is the poison that made TCP toxic, and a kernel-side tail-call into
`#44`'s abandon-frame path is illegal because `nd_*` arms run inside `ksyscall` with stale captures.

⭐ **One `nd_op` call carries an `ND_RECV` per held channel and returns the COUNT that produced data.**
A six-client compositor polls six channels in **one syscall** and gets its data in the same call — no
registration, no watch table, no re-arming, no ceiling of 8. `WOULD_BLOCK`/`PEER_GONE` are **per-record
results**, never batch errors, so a poll batch never aborts on "nothing here". Two syscalls per idle
rotation; one in the common case.

⛔ **`sched_yield #44` is a silent successful no-op under any of four guards**, two enterable without the
caller knowing — and a foreground `run` is IF=0 and gets the no-op, degrading to a 10 ms busy poll. The
honest claim is *"one cheap syscall per poll"*, never *"then a real yield."*

⛔ **The 30-second stall is a cyrius STDLIB defect, not a kernel one** (`sock_recv #49` already answers
immediately three ways). This design must **not** be justified on that number.

### 9.5 Where it beats AF_UNIX — and what each win costs

| AF_UNIX debt | naadi | cost |
|---|---|---|
| The namespace **outlives the process** — unlink-before-bind races a live instance | **No namespace.** Minted as a pair or placed at birth. agnos already reproduced the abstract-namespace authority bug *without* AF_UNIX: `tcp_listen` gates only on duplicate-bind, so whoever binds 7700 first owns the display protocol **and every keystroke on it** | A process nobody spawned cannot find a service in v1 |
| `SOCK_STREAM` has **no message boundaries**; SEQPACKET existed for decades and practice ignored it | Framing is a **property of the channel**, fixed at mint, reported by `ND_STAT` — not a flag anyone can forget. Centralises a discipline this ecosystem rebuilt **four times** | Two contracts in one object; guess wrong and framing is silently wrong |
| **`SCM_RIGHTS` is a bolted-on ancillary-data parser** — a recurring CVE surface | Nothing passes *inside* a message. **`ND_GRANT(h, shm_id, mode)`** binds an shm slot to a channel. Closes a hole open **today**: any of 16 procs can read, write or **free** any other's pixel or PCM buffer | Bulk consumers learn a `{region, offset, length}` idiom |
| **`SO_PEERCRED` is a query you can forget**, and its pid is racy | Peer identity is a kernel fact re-derived **every operation**, carrying a **generation**. Two of its three fields don't exist here (`getuid` is literally `return 0`) | `proc_epoch[16]` is genuinely new state on the process-creation path |
| **CLOEXEC is opt-in and forgettable** | Inverted — see §9.3 | Endowment is an explicit act; the hook sits on every process's birth path |
| **Peer death is an errno on your next write** | A queryable, non-destructive liveness bit that **works for a non-child** — which agnos cannot do today at all | Learned up to one 10 ms rotation late |
| **Readiness is a separate mechanism from receive** | The batch is the poll (§9.4) | 64 B copy-in per channel per rotation |
| **Local and remote are different APIs** — the cardinal sin per AF_UNIX's own designers | Every record carries a `node` word (MUST be 0); `ND_DIAL` reserved, caps bit clear. Uses the shipped `MDO_OP_SUPPORTED` negotiation that grew `#93` across a whole arc under one number with no ABI break | ⚠ **Honest**: naadi is *not* location-transparent and the kernel will never dial. The name promises an **identity model** that spans local and relayed channels, not one syscall |

**Refused outright**, each with a why-it's-safe-here: the whole `AF_*`/`SOCK_*` matrix · `sockaddr_un`
and its 108-byte truncation · `bind`/`listen`/`connect`/`accept` · the Linux abstract `@`-namespace ·
`SCM_RIGHTS`/`cmsg`/`MSG_CTRUNC` · `SIGPIPE` · the entire `SO_*` namespace · buffer autotuning ·
`shutdown`/half-close · `MSG_PEEK`/`DONTWAIT`/`OOB`/`WAITALL` · the `{pid,uid,gid}` triple · a second
handle namespace · **and design-A's seven syscall numbers** — the kernel deliberately realigned onto op
arrays at 1.56.4, and seven numbers would contradict a decision made two arcs ago.

### 9.6 The migration — twelve bites, no flag day

⛔ **naadi REPLACES TCP. It is not a second transport.** TCP on loopback is the rejected primitive —
it is not kept as a fallback, a compile-time option, a runtime switch, or a rollback path. Any plan
that preserves it has not done the job.

**Revertibility comes from bite ORDER, not from a parallel dead path**: bites 0–5 land no consumer at
all, so everything up to the cutover reverts by simply not landing the next bite. The cutover (6–7) is
a real cutover and is meant to be.

⛔ **Recorded so it is not re-derived: the first synthesis of this plan kept TCP alive through three
bites** — a runtime env-var switch, a dual-transport compositor, and a "flip the default, TCP stays
compiled in" step. That was an artifact of a *"the desktop must run at the end of every bite"* rubric,
which scores preserving the old path highest. **The rubric was wrong for a design whose entire purpose
is to delete that path.** Rejected 2026-08-03.

| # | Repo | What | Desktop runs? |
|---|---|---|---|
| **0** | agnos | ⛔ **Delete the bare `arch_wait()` at `syscall.cyr:6695`** — a `hlt` with **no `sti`** inside an IF=0 handler. **An `epoll_wait` on an unexpired timerfd hangs the box today.** design-A claimed no consumer could reach it; that was false | ✅ removes a way to freeze the machine |
| **1** | agnos | shm **owner + epoch**, released at **both** death sites; gate `shm_free #74` on owner (unauthenticated today). ⛔ **`shm_write`/`shm_read` get a WARN COUNTER ONLY** | ✅ nothing is refused |
| **2** | agnos | `proc_epoch[16]`, written and **never read** | ✅ |
| **3** | new `naadi` lib | The **Linux semantic proof** over `socketpair(SOCK_SEQPACKET)`. Zero kernel lines, zero QEMU | ✅ agnos untouched |
| **4** | agnos | The band + `#96`, **kernel selftest only, no consumer** | ✅ nothing calls it |
| **5** | agnos | ⚠ **Highest-risk bite** — endow **with placement** inside `proc_create_user`. Must abort if the child's table is the global one, because `vfs_fd_inherit` **returns success on kmalloc failure** | ✅ no-op path proven across a full boot first |
| **6** | setu 0.8.0 | ⭐ **naadi REPLACES the agnos control transport.** The agnos arm of `src/client.cyr` speaks naadi; the TCP arm is **deleted**, not gated. (Linux keeps its own transport because Linux is a different target — that is not a fallback.) | ✅ — nothing on agnos has spawned a client yet at this bite |
| **7** | aethersafha | The compositor mints, labels and endows a channel per client and spawns them placed. `setu_srv_listen` and the accept block are **removed**, not bypassed | ✅ on naadi |
| **8** | agnos | Retire the loopback carve-outs the display protocol forced into the network stack — the `net_ip == 0` case, and the 7700/7701 well-known ports | ✅ nothing dials them |
| **9** | puka + agnoshi | ⭐ **The PTY** — a live agnsh prompt in a composited window. The gate no candidate could pass | ✅ |
| **10** | agnos | `pipe_write`'s ~3-line producer refusal — it silently overwrites unread bytes today | ✅ |
| **11** | agnoshi + agnos | Concurrent pipelines. Named as a follow-on **because [[feedback_genuine_blocker_taxonomy]] forbids scoping it out** | ✅ |

⭐ The draft had scoped agnsh pipelines out permanently. That is precisely the cop-out the blocker
taxonomy forbids — the prerequisites already landed at 1.47.x, so it is **work we own**, sequenced.

### 9.7 What only the operator can decide

1. ⛔ **`#96` IS CONTESTED.** `roadmap.md:41` reserves it for **`fork`** (agora's blocker). fork is
   unslotted and gated behind `waitpid` wait-any, so naadi likely lands first — **but whoever lands
   takes it and the other takes #97. Neither should mint until you say.**
2. **The name.** `naadi` over `dvara` (used by two candidates for two *different* objects — a collision
   this file already flagged) and `sanketa` (both connote a rendezvous this design refuses).
3. **Sequencing against K1.** Bites 0, 1, 2, 10 are independent of the `-smp 4` fault and can land
   alongside it. **Bites 4–9 should follow K1** — bite 7's `-smp 4` half cannot be proven while `-smp 4`
   is broken.
4. **Whether the PTY rides this.** Recommended yes: it is the **only** named consumer with no setu
   lineage, so it is the only thing that can falsify "is this setu-shaped" (§7 item 3).
5. **How much kernel growth in one cut.** Recommendation: **cut `ND_ENUM` from v1** — it is the one op
   with no today-consumer, which fails the roadmap's own growth rule.
6. **When shm ENFORCE ships.** Warn-only in bite 1. The flip to refusal can land **once every client is
   placed on a naadi channel** (after bite 7), because only then does every shm toucher have a channel
   to hang a grant on. It is a separate, deliberate decision — not a bite's side effect.

### 9.8 Honest costs — knowingly accepted

- **2 MB of PMM reserved at boot** whether or not any channel exists (0.78% of the identity window).
- **Two contracts in one object** (RECORD all-or-nothing vs STREAM short-write).
- **The placement hook is on the boot path of every user process** — the highest-risk diff in the plan,
  and no sequencing makes that risk zero.
- **v1 serves ONE topology: server-spawns-client.** The desktop therefore *cannot* falsify the
  generality claim, because server-spawns-client is exactly what aethersafha does.
- **jalwa regresses under naadi alone** — it dials mishran, and nobody can endow it an audio channel to
  a mixer that did not spawn it.
- **The AI band is NOT served in v1** — bote and majra are bind+accept servers; they are `ND_HANDOFF`
  consumers. The architecture serves them; this cut does not.
- **The grant budget is counted, not solved** — grants ride the same 16-slot table where every slot
  costs an unconditional 2 MB.
- **A third WOULD_BLOCK convention.** agnos already carries two; naadi adds `-2`/`-3`. Less uniform, not
  more. A better project would unify all three.
- **A new spinlock in a kernel mid-SMP-bringup**, while the desktop's blocker *is* an `-smp 4` fault.
- ⛔ **NOTHING HERE HAS BEEN BUILT OR BOOTED.** Every claim is read-only static analysis at agnos
  1.56.35 / setu 0.7.3 / aethersafha 0.12.0.

### 9.9 Kill criteria

- ⭐ **THE PRIMARY ONE.** If bite 5's selftest shows a record delivered to or accepted from an
  **inherited (non-endowed)** fd in a spawned child, **inert-by-construction is false and the entire
  authority model dies with it** — along with the kavach story and the display/agent separation.
- If the 2 MB region is not reachable from a spawned client's CR3, the static-region choice dies. **Test
  this first in bite 4, before any userland.**
- If a client killed by any of the four fault vectors leaves its peer reading `peer_alive = 1`, PEER_GONE
  is silently false **on the death mode aethersafha actually suffers**.
- ⛔ If a green boot smoke passes while a long-running desktop later fails, **any lifetime claim here is
  untrustworthy** — `run` routes through `proc_reap`; production uses `spawn_path #43` and never reaps.
  **A test that only exercises `run` proves nothing about lifetime.**
- If the placement hook destabilises spawn in any measurable way, placement moves out of the birth path
  — and then a child cannot be born holding a channel, **which voids the PTY answer**.
- **setu 0.8.0 requires a `#96` kernel and says so** — a hard floor, exactly as 0.7.3 already declares
  `agnos >= 1.56.34`. If a client silently *appears* to work on a pre-`#96` kernel instead of refusing
  at startup, `ND_CAPS` is not doing its job.

## 10. ⛔ The revert inventory — what TCP-on-loopback put into this system

**This is not a migration forced by a broken transport. It is the removal of a wrong path**, chosen
because a TCP stack happened to exist, never discussed with the operator, and carried for a week.
⚠ Post-`net_src_for` the transport *did* carry a real client↔compositor connect + present, un-rigged
(QEMU `-smp 1`, 2026-08-02 — §10.1). **That is not a reprieve**: it is retired on the architecture,
not on the failure. A local display
protocol has nothing to route, nothing to checksum, no window to negotiate, no RTO to wait out, and no
business owning a port. Two processes on one box with a common ancestor need a channel handed to the
child at spawn.

### 10.0 ⭐ The shape of the mistake — a square peg, and a week of shaping the peg

**Every "fix" in this arc was making TCP fit a hole it does not fit.** Listed together they stop looking
like progress and start looking like what they were:

`net_src_for` (source selection, so a *local* channel could reach itself) · the no-connect-retry rule
(because dialling starves the peer) · sub-window TCP chunking · the bounded DHCP wait before a display
handshake · `SO_REUSEADDR` on the audio port (to survive a restart race) · the selftest assigning
`net_ip = 0x7F000001` (which made the only test passing *at the time* pass by accident) · and an advisory `path`
argument on every setu entry point that was carried, ignored, and passed identically by six consumers.

⛔ **The tell was there a month early and was read backwards.** Pixels left the wire for `sys_shm`, and
then PCM left the wire for `sys_shm` — **independently, in two subsystems, both citing the same ~2 KB
window.** The workload voted with its feet, twice, that the transport could not carry it. That was read
as *"keep the small control channel on TCP"* when it meant *"TCP is the wrong primitive."* The correct
reading was available before any of the shaping work was done.

⛔ **None of this was ever put to the operator.** TCP was chosen because a TCP stack existed, labelled a
stopgap, and then defended by a week of accommodations. **The accommodation count IS the falsification
signal** — when a primitive needs six carve-outs, a boot-path wait and a test that passes by accident,
the primitive is wrong, and no further accommodation is the fix.

### 10.1 The receipts — what a display protocol forced into the kernel

- ⛔ **`net.cyr:183-209` states it outright**, and the scope is **pre-`net_src_for` (agnos 1.56.34)**:
  every outbound segment claimed `net_ip` as its source, so a SYN to 127.0.0.1 was answered to
  `net_ip` and `tcp_find_conn` never matched. **Before that fix the display protocol did not work on
  an ordinary boot, and the only test that passed then did so by accident** —
  `AETHERSAFHA_SETU_SELFTEST` assigned `net_ip = 0x7F000001`, making src and dst agree.
  ⭐ **After the fix it DID connect, un-rigged.** On 2026-08-02, on 1.56.34+,
  `scripts/harness/aethersafha-clients-test.py` reached **"connected: 2, presented: 2"** — setu's
  slim `present_probe` (staged as `/bin/puka`) and the real dhancha `crab` both connected and
  presented. That harness byte-scans `build/agnos` and **hard-exits if the kernel carries any
  selftest hook** (*"a kernel carrying any such hook does not fail this test, it INVALIDATES it"*),
  and attaches a virtio NIC so DHCP yields a real `net_ip` — **it is the harness that caught the
  rigging.** ⚠ Scope it honestly: QEMU at `-smp 1`, never shown on iron, and `-smp 4` fault-kills.
  ⛔ That result is **not** why the transport is going away — see §10.0: it is the **wrong
  primitive**, not a broken one.
- **`net_src_for` (`net.cyr:203`) exists to fix that** — route-derived source selection, a real
  networking concept, added because a *local* channel needed it.
- **`net_ingress.cyr:121-126` waits on DHCP in the boot path** (`while (net_ip == 0 && …)`).
- **`sock_connect #47` holds preempt disabled for the whole attempt** — which is why a connect retry
  loop measured *strictly worse* (200 retries stretched a 30 s budget to 72 s, zero connections): the
  client starves the compositor it is dialling.
- **8 TCP conn slots system-wide, and a loopback connection costs TWO** — so listener + 3 clients
  exhausts the table the *network* is supposed to use.
- **`TCP_RX_RING = 2048`** — the ~2 KB window that forced pixels and PCM onto shm in the first place.
- **The `AETHERSAFHA_SETU_SELFTEST` / `MISHRAN_DUPLEX` scaffolding is now GONE** — three hooks, their
  build defines, six smokes and five harnesses were deleted 2026-08-03. ⚠ The "19 kernel/smoke sites"
  figure previously here is **stale**; what remains in-tree is **tombstone comments only**
  (`kernel/core/net.cyr`, `kernel/core/main.cyr`, `kernel/core/modeset_latch.cyr`,
  `scripts/build.sh`) plus the guard in `scripts/harness/aethersafha-clients-test.py` that hard-exits
  on a hooked kernel. **No live scaffolding is left.** A live count is not stable — re-derive with
  `command grep -rn AETHERSAFHA_SETU_SELFTEST` rather than citing a number.

### 10.2 Blast radius — measured 2026-08-03

Files matching the TCP transport surface (`7700` · `7701` · `sock_connect` · `sock_listen` ·
`sock_accept` · `SETU_TCP_PORT` · `MSH_TCP_PORT`):

| repo | files | repo | files |
|---|---|---|---|
| jalwa | 11 | mishran | 10 |
| aethersafha | 10 | setu | 8 |
| dhancha | 8 | crab | 7 |
| puka | 6 | cyrius-doom | 4 |
| cyrius-mine-cart | 2 | | |

**66 files, 9 repos.** ⚠ `cyrius-doom/vendor/setu.cyr` and `cyrius-mine-cart/vendor/setu.cyr` carry
**no `[deps.setu]` stanza** and will never update mechanically — they are hand-vendored copies and must
be named explicitly in the cut.

### 10.3 What comes out

| Layer | Remove |
|---|---|
| **setu** | `SETU_TCP_PORT = 7700` (`src/client.cyr:16`), `setu_connect`'s `tcp_socket`/`sock_connect` body (`:33-50`), `setu_listen`'s `sock_listen`/`sock_accept` body (`:65-83`), the no-retry comment at `:234` (the hazard it documents ceases to exist), and the advisory `path` argument that was never real |
| **aethersafha** | `setu_srv_listen` + the `setu_sfd` accept block (`src/main.cyr:247-300`), the `"/tmp/aethersafha-setu.sock"` advisory path (`:252`), and the `(TCP loopback:7700)` banner |
| **mishran** | `MSH_TCP_PORT = 7701` and the whole `src/transport.cyr` socket body — including `sock_reuse`/`SO_REUSEADDR`, which exists only to survive a restart race that a placed channel cannot have |
| **kernel** | the `AETHERSAFHA_SETU_SELFTEST` / `MISHRAN_DUPLEX` hooks and the `net_ip = 0x7F000001` assignment; the boot-path DHCP wait's display justification; the 7700/7701 well-known ports |
| **smokes** | every `aethersafha-*.sh` that stands up a listener — and note they each clobber `build/agnos` with a selftest kernel |

### 10.4 What stays, and why it is not a fallback

- **The TCP stack itself.** agnos is *A General **Networked** Operating System*; TCP is correct for the
  network. What is being removed is a **display protocol riding it**, not networking.
- **`net_src_for`.** Route-derived source selection is right regardless of who needed it first.
- **setu's Linux arm.** Linux is a different target with a different kernel, not a fallback path on
  agnos. ⛔ If it ever becomes reachable *on agnos*, that is the wrong path returning.

## 8. Pointers

- **The desktop arc** (open decisions D1/D2, the compositor ladder, the substrate matrix) → aethersafha
  [`planning/desktop.md`](https://github.com/MacCracken/aethersafha/blob/main/docs/development/planning/desktop.md)
- **Protocol design** → agnosticos [`planning/native-display-protocol.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/native-display-protocol.md)
- **The blocking-syscall / two-proc recipe** → [`planning/blocking-syscall-concurrency.md`](blocking-syscall-concurrency.md)
- **Session handoff** → agnosticos [`planning/desktop-arc-handoff.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/desktop-arc-handoff.md)
- **The cut this lands in** → `CHANGELOG.md` [1.56.35]
