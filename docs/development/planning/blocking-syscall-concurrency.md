# Blocking syscalls vs. multi-proc concurrency

**Status:** Path 1 (userland cooperative yield) SHIPPED — **the mechanism stands.** What is
retracted (2026-08-03) is its **mishran duplex-AUDIO demonstration**: the only duplex proof
was the `MISHRAN_DUPLEX_SELFTEST` false green (see Path 1 below), so that demo needs
re-proving over `anu`.

> ⚠ **Scope of that retraction.** It voids **one demonstration**, not **two-proc concurrency
> on agnos** — which is independently established and is NOT in question: the 1.53.8
> `console_lock` fix, and two setu clients that connected and presented concurrently with the
> compositor under the un-rigged `scripts/harness/aethersafha-clients-test.py` (that harness
> byte-scans the kernel and hard-exits if it carries any selftest hook). Do not read anything
> here as "two procs can't run concurrently on agnos." They can.

Path 2 (per-proc syscall kstacks + real in-kernel blocking) IN FLIGHT since 1.57.6 — the operator chose it
2026-09-23 (decision D20); bites S3.1–S3.3 SHIPPED in 1.57.6, the rest is the 1.57.x ladder in § Path 2 plan
below. Opened 2026-07-10 out of the mishran two-proc audio bring-up.

> ⭐ **1.57.6 — PATH 2 IS IN FLIGHT (operator decision D20, 2026-09-23), AND THE INVARIANT BELOW IS HISTORY
> FROM S3.3 ON.** Bites S3.1–S3.3 landed: every process runs its syscalls on its OWN region-7 kernel stack
> (the per-CPU syscall stacks are gone), the SYSRET state lives in that process's frame, a switch releases
> `on_cpu` only after the CPU has left the old stack and CR3, spinlocks and ISR bodies are non-preemptible,
> and region 7 has guard pages — see [`../../architecture/kernel-stacks-and-preemption.md`](../../architecture/kernel-stacks-and-preemption.md).
> The waits themselves still hold their CPU (`preempt_disable` windows) until the voluntary switch + BLOCKED
> state land (S3.4+); this document is rewritten when they do.

## Path 2 plan (1.57.x) — the design record

Operator decision D20 (2026-09-23) chose Path 2 over restartable waits: **a syscall runs on its own
process's kernel stack, can block in place (a real BLOCKED state + wakeups) and be preempted at designated
points; no restart machinery.** The binding plan is the lead's integration of three designs and their
adversarial critiques (stacks, blocking, foreground), 2026-09-23/24. This section is its durable summary
and is what the roadmap cites. Design record only (per-bite code sketches, byte-level stub layouts, mutation
lists — not normative, not maintained): `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.6/design/`
(`path2-integration.json` and the `design-path2-*` / `crit-path2-*` pairs).

### Contracts every step builds on

- **C1 stack map** (region 7, always addressed through the direct map): `[0xE00000,0xF00000)` 16 × 64 KB
  per-process kernel stacks (slot = pid; SYSCALL entry AND CPL3→CPL0 interrupts) · `[0xF00000,0xF40000)` 4
  kthread stacks · `[0xF40000,0xF80000)` IST1 `#DF` · `[0xF80000,0xFC0000)` FREE, reserved for an NMI/#MC
  IST · `[0xFC0000,0x1000000)` AP boot/TSS stacks. The lowest 4 KB of every 64 KB slot is a not-present
  guard page. kmain stays on the BSP boot stack in region 1; AP idles stay on their AP boot stacks.
- **C2 syscall frame** at the stack top: user RSP/RBP/RIP/RFLAGS, rbx, r12–r15 (`SCF_*` 8..72); the exit
  pops SYSRET state from it, so a syscall may resume on any CPU.
- **C3 exactly two switch paths, one save format:** (T) timer → `do_context_switch` → `sched_leave_old`;
  (V) `sched_switch_vol` → `int 0xE0` → `resched_handler` → `do_context_switch` → `sched_leave_old`.
  `exec_and_wait`/`enter_ring3` and `kernel_resume` are the only out-of-band entries and become boot-only
  in S3b.
- **C4 (INV-11):** `on_cpu(old) = −1` is written only by `sched_frame_iretq`, after RSP has left old's
  stack and the new CR3 + kernel stack are installed.
- **C5 states:** 0 dead · 1 ready · 2 running · 3 claiming · 4 DYING (S7) · 5 STOPPED (S7) · 6 BLOCKED.
  `sched_next` picks only 1; `proc_alloc_slot` reuses only state 0 with `on_cpu == −1`.
- **C6 preempt points (R1–R6):** arm → re-check → sleep|cancel with IF=0; preempt_count 0; ISRs only
  wake; never carry a per-CPU cell across a wait; the live CR3 equals the slot CR3; the `#3`/`#37`/`#43`
  loaders contain no wait.
- **C7 locks:** every plain spinlock disables preemption; `sched_lock` is the innermost leaf. Order: fs <
  vfs < proctab < console < {nvme,ahci,vblk,msc} < heap < pmm; `flock_lock` a leaf under fs; input and
  S4's tcp/tx/lo locks below `sched_lock`.
- **C9 API** (the only names later steps may use): `wq_can_block`, `wq_arm(key, deadline_us)`,
  `wq_cancel`, `wq_sleep`, `wq_wake(key)`, `wq_interrupt[_locked]`, `wq_tick`, `wq_signal_pending`,
  `wq_signal_point`, `sched_clock_us`, `wq_deadline_after_us`, `sched_yield_kernel`,
  `sched_switch_vol(intent)`, `sched_exit_tail`, `kstack_install`, `sc_frame_get`. Wait keys `WK_*`
  (SLEEP/FLOCK/CHILD/KBD/KBD_OWNER/SND/TCP/ICMP/TEST), reasons `WR_*` (NONE/EVENT/TIMEOUT/SIGNAL).

### The ladder

| Step | Bites | What lands | Status |
|---|---|---|---|
| S3 | S3.1 | switch tail + scheduler safety: deferred `on_cpu` release, READY-only tripwire, `sched_next` fallback, revive guard | ✅ **1.57.6** |
| | S3.2 | preempt-disabling spinlocks, non-preemptible ISR bodies | ✅ **1.57.6** |
| | S3.3 | per-process kernel stacks (stub bite B, 280 B), guard pages, foreground hygiene, `KSTACK_SELFTEST` + `kstack-smoke` | ✅ **1.57.6** |
| S3c | S3.4 | voluntary switch (`int 0xE0`), BLOCKED state, the wq primitive, `#44`/`#14`/`#96` off the per-CPU captures, stub bite C (174 B), `sched_exit_tail` | 1.57.x |
| | S3.5 | `sleep_ms`#41 blocks only its caller; `waitpid`#4 `WAIT_BLOCK` (`arg1 = 0x100\|pid`, `0x1FF` = any; no new number); child-exit wakes; `flock`#59 blocks (−2 = table full; NB keeps −1; a blocking conversion drops the old lock) | 1.57.x |
| S3d | S3.6 | keep-current (a lone runner keeps its CPU: ~50% → ~100%), its own gate | 1.57.x |
| | S3.7 | keyboard read (one blocking reader per line; the NB reader −2 while it is owned) and sound waits `#66`/`#68` | 1.57.x |
| | S3.8 | wake latency: idle step + reschedule kick IPI (vector `0xE1`) | 1.57.x |
| | S3.9 | docs (this file rewritten as SHIPPED; `blocking-waits.md`), sweep rows, bench | 1.57.x |
| S3b | F1–F5 | `execwait`#37 becomes "load an ordinary scheduled IF=1 child, block until it exits"; kybernet's `/bin/agnsh`, NET dig and the recovery `run` become `kernel_run_child` (BSP-pinned); `exec_and_wait` refused post-scheduler; no IF=0 ring 3 after `sched_active = 1`. F2 is a legal stopping point | 1.57.x |
| S6 | — | `sock_connect`#47 / `sock_send`#48 / `icmp_echo`#55/#100 block only their caller, woken by the RX demux (after S4 + S5) | 1.57.x |
| S7/S8 | — | kill/stop/continue build on `sched_switch_vol`, the wq hooks and `sched_exit_tail`; limits on the tick path | 1.57.x |

Every bite is boot-verified at `-smp 1` AND `-smp 4` before the next starts (agnsh-smoke at both, the stub
size oracle, the aarch64 name lists, LOAD end ≤ `0x370000`), with the accelerator pinned (KVM when
`/dev/kvm` is writable, else `tcg,thread=multi`) — a GREEN mutant under single-threaded TCG proves nothing.

### Risks the plan names (the iron-only ones are why 1.57.6 says "NOT burned")

- The torn (CS,SS) frame class on the CPL0 resume paths (`sched_leave_old` → `sched_frame_iretq`, the
  `#44` tail; S3b adds agnsh's first ring-3 entry through the scheduler tail) — QEMU cannot show it.
- `SPEC_CTRL` in the switch tail is inert on both test substrates (`ibrs=0`); the 4 KB guard pages under
  real paging/TLB behaviour; the hand-built SYSCALL stub (one wrong byte bricks userland).
- Behaviour: a kmain or kthread holding any spinlock is no longer preemptible; keep-current changes a lone
  runner's share; a READY process on a busy CPU waits for its next tick (the kick targets halted CPUs only).
- NMI is not configured (pre-existing); `[0xF80000,0xFC0000)` is its natural IST home.
- `BOOTCR3_KEEP_GNOBOOT_CR3` builds get no guard pages and keep the `.bss` kthread pool; no smoke covers them.
- `flock` has no FIFO fairness; until S7 a two-lock cycle parks both processes BLOCKED (the rest of the
  machine keeps running).

## The invariant (why this is hard) — HISTORY: true through 1.57.5

Every proc on a CPU enters syscall handlers on ONE **shared per-CPU** syscall kernel
stack (`pcpu_syscall_kstack_top` = `0xF10000 + cpu*0x10000`, `syscall_hw.cyr`), NOT a
per-proc stack. Only the *interrupt* entry stack went per-proc at 1.46.1
(`proc_rsp0[pid]` / TSS.RSP0). This is the **serial-kstack invariant**: if the timer
preempted a proc mid-syscall (CPL0) and switched away, the next proc's `SYSCALL` stub
would reset RSP to that same shared top and clobber the suspended handler frame — the
first proc would resume on a corrupted stack and fault.

This is why:
- `preempt_disable()` guards every sti-window blocking wait (`do_context_switch`
  no-ops while `preempt_count > 0`, `sched.cyr`).
- `sys_sched_yield` #44 is an **abandon-frame** yield (it rewrites the caller's slot
  as if the syscall had SYSRET'd, `rax=0`), NOT a suspend-frame yield — it cannot
  resume a value-returning blocking loop mid-loop. The "1.44.14 in-handler yield" was
  rejected for exactly this reason.
- `execwait` #37 needs a SECOND disjoint kstack (`pcpu_syscall_kstack_top2`) for the
  one case (agnsh → child) where two syscall frames must be live at once.

**Consequence:** any blocking, preempt-held syscall starves every other proc on the
CPU for its whole duration. Confirmed preempt-held blockers: `sleep_ms` #41,
`snd_write` #66 (blocking mode), `snd_drain` #68, `sock_connect` #47, `sock_send` #48,
`icmp_echo` #55, `kbd_read_blocking`.

## Path 1 — userland cooperative yield (SHIPPED)

Keep the kernel as-is; make **producers** non-blocking + cooperatively yield — the
already-proven 1.53.9 setu-present pattern. No kernel-logic change. Landed in vani +
mishran for the two-proc audio path:
- `vani` `audio_write_nb` (`snd_write` NONBLOCK #66) + `audio_avail` (`snd_avail` #69).
- `mishran` `msh_router_pump` emits a block only when the DAC ring has room (else
  returns without mixing), and the transport backoffs `sched_yield` instead of
  `sleep_ms`.
- ⛔ **The duplex proof that used to be cited here is GONE and was never valid.**
  `MISHRAN_DUPLEX_SELFTEST` (`main.cyr`) + `scripts/smoke/mishran-duplex-audio-smoke.sh`
  claimed two concurrent ring-3 procs streaming client → **TCP loopback** → mixer → vani
  → HDA at RMS 2116 / PEAK 4448, and called the deadlock broken. That number was a
  **FALSE GREEN**: the hook assigned `net_ip = 0x7F000001` in the kernel, which is the only
  reason **that smoke's** loopback connect ever completed. Hook, define and script were
  removed 2026-08-03 and must not be re-added. The **cooperative-yield mechanism above
  still stands** — what is void is the RMS/PEAK measurement and the "deadlock broken"
  claim resting on it. Re-prove over `anu` when it lands.
- ⚠ **Say which of the two you mean.** Voiding that measurement is **not** a claim that no
  setu client ever connected on agnos — one did, un-rigged, on 1.56.34+ (post-`net_src_for`)
  under `scripts/harness/aethersafha-clients-test.py`. TCP-on-loopback is retired as the
  local display/IPC transport because it is the **wrong primitive**, not because it never
  ran. See `docs/development/planning/ipc.md` §9 (anu design) / §10 (removal inventory).

Four things were required together, worth recording:
1. Cooperative yield (above).
2. **Server-first ordering** — the server binds *before* the client connects, so a
   blocking `sock_connect` #47 completes in-kernel against a bound listener (a
   client-spawns-then-connects ordering deadlocks: the connect starves the unbound
   server). Mirrors aethersafha→puka.
3. **Post-`sched_active` launch** — two procs can only run once the scheduler is live;
   a pre-scheduler boot-hook (`sched_active=0`) makes `sched_yield` a no-op and has no
   timer preemption, so a spawned secondary never runs. kmain idles (`while(1)
   arch_wait()`) and the live scheduler drives both procs.
4. ~~**Sub-window TCP chunks**~~ — ⛔ **RETIRED WRONG PREMISE, do not follow.** This item
   was never a requirement of the concurrency mechanism; it was an accommodation to a
   transport that should not have been carrying local IPC. Local control messages move over
   **`anu`** and bulk payload over the `sys_shm_*` band — see
   `docs/development/planning/ipc.md` §9 (anu design) / §10 (removal inventory), and the
   TCP-wire section below for the constraint it was working around. Items 1-3 stand.

## The TCP-wire constraint (`sock_send` #48)

> ⛔ **This section describes a constraint on the NETWORK stack, not a local-IPC design.**
> Everything below about chunking payloads under the loopback window was written while
> TCP-on-loopback was mistakenly treated as a local transport. It is **not** the local
> IPC or display transport — `anu` is (`docs/development/planning/ipc.md` §9-§10). Do
> not use this section as a recipe for getting a local two-proc path working.

`sock_send` #48 blocks preempt-held waiting for ACKs (`tcp_send`, ~8 s ceiling). On the
agnos loopback the recv ring is ~2 KB; a payload larger than that fills the peer's recv
buffer, and `sock_send` then blocks waiting for the peer to drain — which it can't,
because the sender holds preemption. The mishran audio proof works around this by
chunking PCM **below the window** (256 frames = 1024 B/write) + `sched_yield`-pacing, so
each `sock_send` fits and completes in-kernel. ⛔ That workaround is **retired along with
the transport** — the "chunk it under the window" recipe is exactly the accommodation
that should have falsified the premise instead of propping it up. The desktop does NOT
"keep tiny control messages on TCP": local control messages move over `anu`, and bulk
pixels move over the `sys_shm_*` band. Retracted 2026-08-03.

Two clean fixes (either unblocks large-payload two-proc streaming without the chunking
workaround):
- **Shared-memory PCM transport for mishran** (`sys_shm_*`, like setu's framebuffer) —
  move PCM over shm; control msgs go over **`anu`**, not TCP (⛔ this bullet originally
  read "keep control msgs on TCP" — corrected 2026-08-03). Userland (mishran) change.
- **Non-blocking `sock_send`** — return partial + would-block (0) when the recv buffer
  is full, so the caller yields (as `sock_recv` #49 already does). Kernel change.

The `msh_client_write` API should also internally chunk large writes ≤ window + yield on
agnos, so real clients (jalwa) get correct pacing for free.

## Path 2 — the original sketch (2026-07-10; superseded by § Path 2 plan above)

Give each proc its OWN syscall entry stack (the `proc_rsp0` pool already gives every pid
a region-7 stack; repoint `pcpu_syscall_kstack_top` per-proc on context switch, exactly
as `execwait` #37 repoints it for its one nested case). Then mid-syscall preemption is
inherently safe: a preempted-in proc's syscall grows down its OWN stack, never clobbering
a suspended handler frame. This dissolves the serial-kstack "shared-RSP0 wall"
(deferred at `syscall.cyr:985`) and lets the blocking waits drop `preempt_disable`
outright — the genuinely-general fix for blocking-syscall + concurrency.

**Cost:** LARGE, incremental, iron-gated. It touches the most delicate subsystem the
whole two-proc bring-up (1.53.8) rests on — the SYSCALL entry stub + the serial-kstack
invariant. Scratch-holding syscalls (`spawn_path` #43, `execwait`, ext2 lookups) would
still need `preempt_disable` for the per-CPU FS/ELF scratch, so the change is "per-proc
kstacks + drop preempt_disable only on scratch-free waits", not a blanket removal.

Do NOT hand-edit `do_context_switch` / `proc_get_user_cr3` inline — their save/restore
zone is cc5-regalloc-sensitive (`sched.cyr:341`). Revisit when a native workload needs
truly-blocking syscalls to coexist with concurrency that cooperative yield can't express.
