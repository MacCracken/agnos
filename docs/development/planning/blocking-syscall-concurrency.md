# Blocking syscalls vs. multi-proc concurrency

**Status:** Path 1 (userland cooperative yield) SHIPPED + QEMU-validated. Path 2
(per-proc syscall kstacks) TRACKED, deferred. Opened 2026-07-10 out of the mishran
two-proc audio bring-up.

## The invariant (why this is hard)

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
- `MISHRAN_DUPLEX_SELFTEST` (`main.cyr`, **post-`sched_active`**) + `scripts/
  mishran-duplex-audio-smoke.sh`: two concurrent ring-3 procs, client → loopback →
  mixer → vani → HDA, **RMS 2116 / PEAK 4448** (non-silent). Deadlock broken.

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
4. **Sub-window TCP chunks** — see below.

## The TCP-wire constraint (`sock_send` #48)

`sock_send` #48 blocks preempt-held waiting for ACKs (`tcp_send`, ~8 s ceiling). On the
agnos loopback the recv ring is ~2 KB; a payload larger than that fills the peer's recv
buffer, and `sock_send` then blocks waiting for the peer to drain — which it can't,
because the sender holds preemption. The mishran audio proof works around this by
chunking PCM **below the window** (256 frames = 1024 B/write) + `sched_yield`-pacing, so
each `sock_send` fits and completes in-kernel. This is the same constraint the desktop
sidesteps by moving large data (the framebuffer) over **shared memory** and keeping only
tiny control messages on TCP.

Two clean fixes (either unblocks large-payload two-proc streaming without the chunking
workaround):
- **Shared-memory PCM transport for mishran** (`sys_shm_*`, like setu's framebuffer) —
  keep control msgs on TCP, move PCM over shm. Userland (mishran) change; no kernel risk.
- **Non-blocking `sock_send`** — return partial + would-block (0) when the recv buffer
  is full, so the caller yields (as `sock_recv` #49 already does). Kernel change.

The `msh_client_write` API should also internally chunk large writes ≤ window + yield on
agnos, so real clients (jalwa) get correct pacing for free.

## Path 2 — per-proc syscall kstacks (DEFERRED, the real general fix)

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
