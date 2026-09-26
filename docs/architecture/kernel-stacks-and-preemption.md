# Kernel stacks, the switch tail and preemption — invariants

> **Last Updated**: 2026-09-25 (1.57.7 — Path 2 step S3d, bites S3.6–S3.9: the 0xE1 reschedule kick (EOI-only — a
> wake, not a switch path), the vector table below, keep-current, the idle step and the park; the KEEP-build idle-stack
> bound. 1.57.7 — Path 2 step S3c, bites S3.4–S3.5: the voluntary switch (`int 0xE0`,
> Invariant 7), the 174-byte stub (bite C), `clac` at every interrupt/exception stub, per-process a4, fork from the
> frame with IF forced. The BLOCKED state and the wait/wake primitive are [`blocking-waits.md`](blocking-waits.md).
> 1.57.6 — Path 2 step S3, bites S3.1–S3.3: per-process kernel stacks, the deferred `on_cpu` release,
> preempt-disabling spinlocks, region-7 guard pages.)
>
> Code: the switch tail (`sched_leave_old`, `sched_frame_iretq`), `do_context_switch`'s return contract,
> tripwire and pre-lock guard (`sched_cpl0_switch_ok`, `sched_live_cr3_ok`), `sched_next`'s fallback and the
> KSTACK hooks in [`kernel/core/sched.cyr`](../../kernel/core/sched.cyr) · the SYSCALL stub, the `SCF_*` frame,
> `kstack_install` and the once-built stub in [`kernel/arch/x86_64/syscall_hw.cyr`](../../kernel/arch/x86_64/syscall_hw.cyr)
> · `timer_handler` in [`kernel/arch/x86_64/pic.cyr`](../../kernel/arch/x86_64/pic.cyr) · the lock functions in
> [`kernel/arch/x86_64/smp.cyr`](../../kernel/arch/x86_64/smp.cyr) (+ `pmm.cyr`, `keyboard.cyr`, `apic.cyr`, `usb/hid.cyr`)
> · `kstack_guard_init` in [`kernel/core/vmm.cyr`](../../kernel/core/vmm.cyr) · `proc_alloc_slot`'s reuse guard,
> the kthread pool and `kstack_paint` in [`kernel/core/proc.cyr`](../../kernel/core/proc.cyr) · `exec_and_wait` in
> [`kernel/arch/x86_64/ring3.cyr`](../../kernel/arch/x86_64/ring3.cyr) · `kernel_resume` and execwait#37 in
> [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr) · the region-7 map in
> [`kernel/arch/x86_64/gdt.cyr`](../../kernel/arch/x86_64/gdt.cyr).
> Gate: [`scripts/smoke/kstack-smoke.sh`](../../scripts/smoke/kstack-smoke.sh) (`KSTACK_SELFTEST`, `-smp 1` and
> `-smp 4`), plus `exec-smoke`'s `exec: rsp0 restored`, plus the latched-line deny (`SMOKE_INVARIANT_DENY`,
> `scripts/smoke/lib/qemu-dwell.sh`) in every production-path smoke and the run37 / agnsh-bg / multijob harnesses.
> Measurement: `KSTACK_HW=1` (`docs/development/build.md`). Design record: the Path 2 plan (operator decision D20,
> 2026-09-23); the planning note is [`../development/planning/blocking-syscall-concurrency.md`](../development/planning/blocking-syscall-concurrency.md).

## Invariant 1 — a process's kernel stack is its own, for syscalls AND interrupts

Every process slot `pid` owns one 64 KB kernel stack in region 7: phys `0xE00000 + pid * 0x10000`, top
`proc_rsp0[pid] = DIRECTMAP_BASE + 0xE00000 + (pid + 1) * 0x10000`, always addressed through the **direct
map** (the identity VA of region 7 is inside the user-segment range and a large image overrides it).

- `kstack_install(pid)` makes it THE kernel stack of the calling CPU: `TSS.RSP0` (CPL3→CPL0 interrupts) and
  `pcpu_syscall_kstack_top[cpu]` (SYSCALL entry — the stub can index it with `r8*8`; the TSS stride is not a SIB
  scale). One stack serves both because a process is either in ring 3 (an interrupt frame starts at the top)
  or in a syscall (the frame starts at the top and any interrupt nests below it), never both.
- It is called on **every** path that makes a process current before ring 3 can run: `do_context_switch` (both
  switch paths, Invariant 7 — the retired `sys_sched_yield` had its own copy until 1.57.7), the boot-only
  `exec_and_wait`, and `kernel_resume` (which parks the pair on kmain's slot so a dead child's slot is never left
  installed). (execwait#37's resume step (h) is gone with S3b: a #37 caller wakes through the switch tail, which
  installs its stack — [`foreground-exec.md`](foreground-exec.md).)
- `syscall_kstack_reserve` seeds the tops with **0 — fail-STOP, not fail-loud**: a SYSCALL that arrives before
  any install on its CPU faults on its first push instead of silently sharing another process's stack. The #PF
  cannot be pushed on that RSP either, so it escalates to #DF on IST1. Until the S3-fix pass that was a
  **silent wedge** under QEMU (mutation M-B2: no serial line; the vector-8 stub reached only CMOS `0x54` and the
  FB bar); the #DF stub now prints one lock-free COM1 line first — `PANIC: Double Fault (#DF, IST1) rip=… rsp=…
  cr2=…` (`exc_df_report`, `idt.cyr`) — which also covers a stack that runs into its guard page.
- A zero top covers only the FIRST entry on a CPU. The likely regression — a new switch path that forgets
  `kstack_install` — leaves the top naming the PREVIOUS process's stack, which is valid memory. So every ring-3
  syscall first runs `kstack_check_entry` (`sched.cyr`): this CPU's top must equal `proc_rsp0_top(current)`,
  else one latched klug + COM1 line, `syscall: kernel stack is not the caller's (a switch path missed
  kstack_install)`, which the production-path smokes deny. Diagnostic only; cost two loads and a compare —
  it reuses the cpu index `syscall_handler` already reads (a first version read the LAPIC id
  again and cost +20% on getpid at `-smp 4` under KVM, where every LAPIC read is a VM exit). Since 1.57.7 it
  RETURNS the pid it loads, and `syscall_handler` stores the 4th syscall argument with it:
  `ksyscall_a4_store(pid, a4)` — **a4 is per-PROCESS** (`proc_sc_a4[16]`, proc.cyr), because a syscall can now
  block and resume on another CPU after other processes' syscalls ran on both (it was a per-CPU cell,
  `pcpu_ksyscall_a4`, and execwait#37 saved/restored it around its child).
- Until 1.57.6 syscalls ran on a PER-CPU stack every process on that CPU shared (plus a second one execwait#37
  swapped in so its child could not smash the parent's suspended frame — "hazard H2"). Both are gone; a #37
  child's syscalls grow down the child's own stack by construction.

### The syscall frame

Live only while the process is inside a SYSCALL from ring 3; the stub builds it at the top of the stack:

| Slot | Contents | `SCF_*` |
|---|---|---|
| `ktop-8` | user RSP | `SCF_URSP` = 8 |
| `ktop-16` | user RBP | `SCF_RBP` = 16 |
| `ktop-24` | user RIP (rcx) | `SCF_RIP` = 24 |
| `ktop-32` | user RFLAGS (r11) | `SCF_RFL` = 32 |
| `ktop-40..-72` | rbx, r12, r13, r14, r15 | `SCF_RBX`..`SCF_R15` |

The exit **pops** r15..r12, rbx, r11, rcx, rbp and then `mov rsp, [rsp]` — the user RSP comes from the
process's own frame, not from a per-CPU cell the next syscall on that CPU overwrites (the per-CPU
`pcpu_kernel_rsp_save` is gone entirely since 1.57.7's stub bite C).
So a syscall switched out mid-flight, or resumed on another CPU, SYSRETs on its own state. `sc_frame_get(pid,
off)` reads a slot. RSP at `call syscall_handler` is `ktop-72 ≡ 8 (mod 16)`, the parity the old three pushes gave.

Stub register contract (1.57.7, stub bite C; **`syscall: stub 174 bytes of 2048`** with `syscall: ibrs=0` —
280 − 63 (the per-CPU capture block) − 5 − 6 − 32): in — rax num, rdi/rsi/rdx a1–a3, r10 a4, rcx user RIP, r11
user RFLAGS, rsp user RSP; scratch — r8 (the capped cpu), r9 (a4), r10 (kernel CR3, then **the user RSP**: `mov
r10, rsp` before the stack switch, `push r10` → `[ktop-8]` after it); `user_rsp` for `syscall_handler` is read
back off the stack (`mov rdi, [rsp+0x40]` = `[ktop-8]` after the 9 pushes); out — rax result, rcx/r11 the SYSRET
pair, rbx/rbp/r12–r15/rsp from the frame, rdx/rsi/rdi/r8–r10 whatever the handler left. Between the stack switch
and SYSRET the stub touches **no per-CPU cell** except the two it must (the kernel-stack top and the KPTI CR3 pair);
it reads the LAPIC twice per syscall (entry, exit) — the third read (the "off-100 consumer") is gone. The 1.44.16
capture of rcx/r11/rbx/rbp/r12–r15 into the per-CPU `pcpu_sc_entry_regs` (read by the abandon-frame #44 and by
`fork`) is deleted: the voluntary switch saves the whole frame, and **`sys_fork` reads the caller's own frame**
(`sc_frame_get(parent, SCF_*)`) and **forces IF in the child's RFLAGS** (`| 0x200` — a forked child is always an
ordinary IF=1 scheduled process, even under an IF=0 foreground parent; fork-smoke's foreground arm, mutation M-C12). The stub is **built once** at boot and never
rewritten (`syscall_init` is MSR-only after its first call, which builds it — `syscall_stub_built`) —
rewriting it while other CPUs execute it would be cross-modifying code. `exec_and_wait` calls that same
once-guarded `syscall_init`, NOT `syscall_msr_init`: a boot selftest (DOOM_SELFTEST) execs ring 3 before
`main.cyr`'s own `syscall_init`, and with the MSR-only call its first SYSCALL vectored into an empty entry
buffer (measured: doom-smoke RED, fixed in S3.3). The size oracle is keyed on
`ibrs_supported`; the IBRS blocks add bytes on a host whose CPUID leaf-7 EDX[26] is set.

## Invariant 2 — `on_cpu(old) = -1` is published only after the CPU has left old (INV-11)

`on_cpu[pid]` is the scheduler's fence: `sched_next` picks only `on_cpu == -1`, the reap fence
(`proc_reap_off_cpu_fence`) spins until it, and `proc_alloc_slot` reuses a dead slot only at `-1`.

- `do_context_switch` no longer stores `-1` under `sched_lock`. It returns **`old + 1`** on a real switch (0 =
  no switch, frame untouched), and the caller MUST finish through `sched_leave_old(isr_rsp, old)`: copy the
  160-byte frame (which now holds NEW's context but sits on OLD's stack) into this CPU's `pcpu_yield_frame`
  slot, re-validate its (CS,SS) pair, set SPEC_CTRL for the target CPL (`sched_spec_ctrl_for`), and
  `sched_frame_iretq(fp, cell)`:
  `mov rsp, fp` (off old's stack) → `mov qword [cell], -1` (the release) → 15 pops → `iretq`.
- By then `cr3_load(new)` and `kstack_install(new)` have run. So **`on_cpu == -1` ⇔ no CPU is on this
  process's kernel stack and none has its CR3 loaded.** x86-TSO orders every earlier store (the saved slot,
  the FXSAVE area, `on_cpu(new)`, the CR3) and every earlier load from old's stack before the release.
- The old early publish let another CPU pick `old` and resume it onto the very frame this CPU was still
  popping — latent while syscalls shared per-CPU stacks, routine once each process has its own.
- The only writers of `-1`: `proc_on_cpu_init` (boot), `proc_alloc_slot`'s recycle store (on a slot that is
  already `-1`), the reap fence's self-owned path (a `kernel_resume` exit — the CPU that ran the child is the
  one reaping it), and `sched_frame_iretq`. INV-6 is unchanged: `on_cpu(new) = cpu` is the last under-lock
  mutation of a switch.
- **INV-RUN**: the process current on a CPU is state 2 with `on_cpu` == that CPU. kmain gets it at the
  bootstrap (`on_cpu_set(0, 0)`); an out-of-band `exec_and_wait` child gets it at entry (FG-1: state 2 +
  `on_cpu` = this CPU — it used to run at state 3 or 1 with `on_cpu == -1`, kept safe only by its pin).
- A dead `old` still hands the CPU to `cr3_load(0x1000)` before the tail (spawn-and-fd-lifetime.md,
  Invariant 4) — belt-and-braces now that the fence stays shut until the tail.
- **Gated directly** (S3-fix): kstack-smoke's `-smp 4` fence phase holds the CPU leaving a LIVE, READY probe in
  its switch tail (on the probe's stack, `on_cpu` still its own) while the other CPUs tick. They must find it
  READY-but-fenced and skip it (`contested`, counted in `sched_next`), never switch it in (`overlap`, counted in
  `kst_note_switch_in`, said at once on COM1), and the holder's canary must survive. Putting the release back
  under the lock (M-A1) goes RED there with no tail delay and no retirement; the storm (retire + reuse) remains
  the M-A3 discriminator. Both phases need held >= 4 or they say `VOID`, never OK.

## Invariant 3 — only a READY process is ever switched to

- `sched_next` picks state 1 only; when nothing is READY it returns **this CPU's idle** (which is then
  `old`, so no switch), never kmain. The old BSP `return 0` restored kmain's STALE slot whenever kmain was
  parked out-of-band in `exec_and_wait` and the idle was current with nothing ready — a time-travel onto
  kmain's live stack the moment a process can leave a CPU without being READY.
- `do_context_switch`'s **tripwire** refuses any pick whose state is not 1 and latches
  `sched: refused non-ready pick` (klug + COM1, after the unlock).
- The revive guard makes only states 1–3 READY again; 4 (DYING) / 5 (STOPPED) / 6 (BLOCKED) left their CPU on
  purpose.
- `proc_alloc_slot` reuses a dead slot only when `on_cpu == -1` (strict — no self-owned exemption).

## Invariant 4 — a held spinlock and an ISR body are non-preemptible

- Every plain spinlock (`heap vfs mmap proctab fs console nvme ahci vblk msc pmm input tlb_shoot`, and since 1.57.7
  S4 the IRQ-saved net chain `tcp_tab net_tx lo_q udp` — net-concurrency.md) calls
  `preempt_disable()` first and its unlock `preempt_enable()` last; a try-lock (`net_rx`, `hid_poll`, `lo_drain`)
  disables only when it wins. 1.57.7 S6 adds `icmp_lock` (IRQ-saved sibling leaf, plain-spinlock shape) and the
  `net_tick_lock` TRY lock (net_tick's body, one CPU at a time). The call adds no local, so the hand-asm `[rbp-N]` slots do not move
  (objdump-checked). kmain and the kthreads run IF=1 beside runnable ring-3 processes: a tick that switched
  kmain out holding `console_lock` handed the CPU to a process whose `write(1)` then spun at IF=0 forever.
- EXCLUDED: `spin_lock`/`smp_lock` (only `ap_entry`, across the `cpu_count` 1→2 flip, where
  `preempt_cpu_slot`'s fast path would unbalance the BSP's count) and `sched_lock` (the innermost LEAF,
  IF=0 only; nothing is acquired or printed under it).
- `timer_handler`, `nic_rx_handler` and `xhci_rx_handler` raise the count for their bodies; the timer drops it
  immediately before `do_context_switch`, so the switch sees the interrupted context's count. Nothing reached
  from an ISR body can switch the ISR frame away before its EOI.
- `apic_send_ipi_one` is IRQ-saved around the two ICR writes and the delivery wait.
- `preempt_disable` does its increment with IF masked (`kbd_irq_save`/`kbd_irq_restore`, which give the
  caller its own IF back). It is the one call made at count 0, while the caller is still preemptible, and it
  is a read-modify-write of the slot for THIS CPU's id: a tick between picking the slot and the store could
  migrate the caller mid-RMW, so the +1 would land on the old CPU (non-preemptible from then on) while the
  caller held its lock at count 0 on the new one. Latent in 1.57.6 (kmain is BSP-pinned; the THREAD_SELFTEST
  kthreads take no lock), closed before S3.4 makes IF=1 CPL0 contexts routine. `preempt_enable` runs at
  count >= 1, where no switch can happen before its store, and needs no mask.
- Cost: `preempt_cpu_slot` reads the LAPIC id per lock and per unlock once `cpu_count >= 2`.

## Invariant 5 — a CPL0 frame is switched out only on its own CR3

The switch restores the SLOT's CR3, not the live one. `sched_cpl0_switch_ok` (pre-lock, every tick) lets a
CPL3 frame always switch; a CPL0 frame only if `sched_live_cr3_ok(cur)` (live CR3 == the slot's, or the slot
says 0x1000 and live == `sched_home_cr3`, which is gnoboot's CR3 in a `BOOTCR3_KEEP_GNOBOOT_CR3` build). (The
INTERIM "child of an in-flight execwait#37" clause is gone since S3b-F2: a #37 child is an ordinary scheduled
process — [`foreground-exec.md`](foreground-exec.md).) A **dead** current process is always switchable: `exit`#0 and
`fault_kill_current` end in `sched_exit_tail` (1.57.7: a BLOCK-shaped voluntary switch, with an IF=1 `sti; hlt`
fallback) at CPL0, and the reaper may already have detached the slot's CR3 — refusing there would deadlock the
reaper's fence.

## Invariant 6 — the out-of-band entries

⭐ **1.57.7 (S3b-F4): BOOT-ONLY.** After `sched_active = 1` every kernel launch is a scheduled child kmain blocks for
(`kernel_run_child`) and #37 is a blocking wait, so `exec_and_wait` refuses after the scheduler starts (a latched,
denied line) and the `kernel_resume` gates are wrapped in `sched_active == 0` — see
[`foreground-exec.md`](foreground-exec.md). Before the scheduler, `exec_and_wait` (the `sh_exec("run …")` selftest
hooks through `kernel_exec_boot`, bote, a KTEST-build kybernet) is
**entered IF=0** and the kmain callers get their own IF back after the reap (`kbd_irq_save`/`restore`); the
recovery shell used to return from `run` IF=0 and halt forever at its next `arch_wait`. `exec_and_wait` and
`kernel_resume` latch `sched:` asserts (klug + COM1) if entered with `preempt_count != 0` (or, for
`exec_and_wait`, IF=1). `elf_load_from_file` holds `preempt_count` for the whole load (its per-CPU header
buffer and env cells are live across it); kybernet additionally brackets its env set + load.
`power_stop_final` starts with `arch_cli` (kmain reaches it IF=1 now).

## Invariant 7 — exactly two switch paths, one save format (1.57.7)

- **(T) timer**: `timer_isr` → `timer_handler` → `do_context_switch` → EOI → `sched_leave_old`.
- **(V) voluntary**: `sched_switch_vol(intent)` → `int 0xE0` → `resched_isr` → `resched_handler` →
  `do_context_switch` → `sched_leave_old`. `resched_isr` pushes the timer's exact 15-register frame (after a
  `clac`), so the leaver is saved exactly as a tick would save it and is resumed — later, on any CPU — by an iretq
  to the instruction after the `int`; it finds rax = 1 (the reversed-label slot map: `p+112` → rax), or 0 when
  `do_context_switch` declined. Everything the switch does (FXSAVE under the lock, CR3 + both KPTI cells,
  `kstack_install`, TS, SPEC_CTRL, the (CS,SS) guards, INV-11) is inherited by construction. The only other
  entries are the out-of-band `exec_and_wait` / `kernel_resume` (Invariant 6; pre-scheduler only since S3b-F4).
- **The intent cell** `pcpu_resched_intent[cpu]` is set by `sched_switch_vol` with IF=0 and cleared by
  `resched_handler` on the same CPU, so it is non-zero only inside a voluntary switch. A **hardware** 0xE0 (a
  misprogrammed MSI, a self-IPI — maskable, so it can only arrive with IF=1) finds it 0 and is EOI'd without a
  switch (kstack-smoke "spurious 0xE0", mutation M-C9). intent 1 = YIELD (the leaver is revived READY); **any
  intent ≥ 2 is BLOCK-shaped**: `sched_block_intent_satisfied` (under `sched_lock`, first thing after `old` is
  read) declines the switch when the wait's wake already landed (state 1 → back to 2) or nothing was published
  (2/3), and switches for 0/4/5/6.
- The gate is **DPL0, IST0, selector 0x08** (installed right after the timer gate, before `tss_ist_selftest`,
  which asserts the IST; `resched_gates_ok` prints `sched: resched gate 0xE0 OK` or the denied
  `sched: resched gate misconfigured (0xE0 must be DPL0 IST0)`). Ring 3 `int 0xE0` is a #GP → exit 141
  (kstack-smoke "resched gate DPL0", mutation M-C4).
- `sched_yield_kernel()` (the in-kernel yield behind `#44` and `#14`) reads the CPU index once and
  refuses before the scheduler, with preempt held and on a borrowed CR3 (the INTERIM #37-child refusal is gone
  since S3b-F2).
- ⭐ **1.57.7 (S3d) — THE KICK IS A WAKE, NOT A SWITCH PATH.** The 0xE1 reschedule kick (`resched_kick_isr` →
  `resched_kick_handler`) only EOIs: it ends a remote `hlt`, and the kicked CPU's own code then switches through (V) —
  the idle step's `sched_yield_kernel`, the park's trailing yield. The idle step itself switches only through (V). So
  the count stays at two. ([`blocking-waits.md`](blocking-waits.md) has the halt protocol and the kick's targets.)
- Keep-current (S3.6): `sched_next` may now return `old` itself (a RUNNING current with only the idle READY) and
  `do_context_switch`'s `new == old` early-out keeps it; the tripwire (Invariant 3) is unchanged — it never sees `old`.

### The vectors (1.57.7)

| Vector | What | DPL | IST | Entry | Switches? |
|---|---|---|---|---|---|
| 32 | timer | 0 | 0 | `clac` | yes — path (T) |
| 0xE0 (224) | voluntary switch (`resched_isr`) | 0 | 0 (the leaver's own stack) | `clac` | yes — path (V), only with the intent cell set; a hardware 0xE0 is EOI-only |
| **0xE1 (225)** | **reschedule kick** (`resched_kick_isr`, 43 B fixed) | 0 | 0 | `clac` | **never — EOI only** |
| 0x50 / 0x51 | NIC / xHCI MSI-X | 0 | 0 | `clac` | no (they wake) |
| 0xF0 | TLB shootdown | 0 | 0 | `clac` | no |
| 7 (#NM), 0, 6, 8, 10–14, 19 | exception stubs | 0 | 8 (#DF) = IST1, else 0 | `clac` | no (a ring-3 fault ends in `sched_exit_tail` → (V)) |

`tss_ist_selftest` asserts IST 0 for 14, 32, 224 and **225**; `resched_gates_ok` prints `sched: resched gate 0xE0 OK`
and `sched: resched gate 0xE1 OK` (or the denied `… misconfigured (0xE{0,1} must be DPL0 IST0)`); the generic
"isr clac" byte check counts n = 16 gates since S3d and also asserts the kick stub's `iretq` at bytes 41–42.

## `clac` at every interrupt and exception stub (1.57.7)

Hardware does NOT clear RFLAGS.AC on interrupt or exception delivery. Ring 3 can set AC with `popf`, and inside
a syscall the entry stub has done `stac` (SFMASK clears AC only at SYSCALL entry) — so without a `clac` any ISR
or fault body could run with SMAP off. **Every interrupt and exception stub the kernel builds begins with
`0F 01 CA`**: the timer, `resched_isr` (0xE0), the NIC (0x50) and xHCI (0x51) MSI-X stubs, the TLB shootdown
(0xF0), `#NM` (7) and the nine `exc_handlers_init` stubs (0, 6, 8, 10, 11, 12, 13, 14, 19; the gate is installed on
the `clac`, the unchanged body follows at +3). The saved RFLAGS keeps the interrupted AC and `iretq` restores it.
The only exemption is `idt_init`'s bare-`iretq` default `isr_stub`, which touches nothing. **The generic byte check**
(kstack-smoke "isr clac"): every IDT vector whose handler is not `isr_stub` must start with `0F 01 CA` (n = 15 at
S3c, 16 since S3d's 0xE1 kick stub — a new stub without it goes RED), plus a sample of the live AC inside timer ISR
bodies that interrupted a stac window.

⛔ **An exception stub must not dereference user memory on a RING-3 fault.** The `#GP` stub's 1.46.x iretq-frame
diagnostics read through `[rsp+0x20]` — the faulting context's saved RSP. For a kernel-iretq #GP that is a kernel
frame; for a #GP taken IN RING 3 it is the user stack, and the read was a CPL0 access to a US=1 page with AC clear:
a SMAP #PF inside the #GP stub, which the #PF stub (seeing CPL0) turns into the canary halt. So **every ring-3 #GP**
(a privileged instruction, a DPL0 `int`, a bad segment load) wedged the box instead of reaching the ring3-kill —
pre-existing, found by kstack-smoke's DPL0 phase (1.57.7: QEMU `-d int` showed `#GP e=0x702 cpl=3`, then
`#PF e=0001 cpl=0 CR2 = user RSP + 0x20`). The six deref blocks are now skipped when the saved CS is ring 3
(`test byte [rsp+0x10], 3; jnz`), mutation M-GP.

## Region 7 and the guard pages

| Phys range | Use (1.57.6) |
|---|---|
| `0xE00000–0xF00000` | 16 × 64 KB per-process kernel stacks (slot = pid) |
| `0xF00000–0xF40000` | 4 × 64 KB kthread stacks (the BSP idle's included; were the per-CPU syscall stacks) |
| `0xF40000–0xF80000` | IST1 (#DF), one per CPU |
| `0xF80000–0xFC0000` | FREE (were the #37 second stacks) — reserved for a future NMI/#MC IST |
| `0xFC0000–0x1000000` | AP boot/TSS stacks (slot 0 unused) |

`kstack_guard_init` (after `pmm_bitmap_use_directmap`, before any per-process CR3 and before the APs wake)
replaces the direct map's 2 MB entry for region 7 in `dm_pd` — a single PD copied **by pointer** into every
per-process CR3 — with a 4 KB table whose 32 slot bottoms are **not present** (P|RW|NX elsewhere, same phys).
Each stack has 60 KB usable; an overflow is a CPL0 #PF → #DF on IST1 (and its `PANIC: Double Fault` COM1 line)
instead of a silent write into the slot below (another process's SYSRET frame). The depth actually used is
measured by a `KSTACK_HW=1` build (implied by `KSTACK_SELFTEST`): every slot is painted when it is handed out and
every reap / slot hand-out scans all painted slots, printing `kstack-hw: max=…` whenever the high-water mark
grows. AP idles are registered on their AP boot stacks and take no kthread slot; they are born CLAIMING (state 3,
`proc_create_kclaim`) and first published — running, pinned, owned — by `ap_entry` under `sched_lock`, because
their initial RSP is the stack `ap_entry` is running on. A `BOOTCR3_KEEP_GNOBOOT_CR3` build keeps the 4 KB `.bss` kthread pool and gets no guard pages (its kmain
context has no direct map); no smoke covers that build.

## Region 1 — the BSP's two fixed stacks (1.57.7)

| Phys = VA (identity, PD[1]) | Use |
|---|---|
| `[0x100000, LOAD end)` | the kernel image (LOAD end `0x361898` at 1.57.7's first cut) |
| `[LOAD end, 0x390000)` | image headroom — `scripts/check/image-layout-check.sh` (check.sh gate 34; `scripts/build.sh` after every x86_64 build, fatal for a flag build; CI after its plain build) fails any image past `0x390000` |
| `[0x390000, 0x3A0000)` | BSP boot stack, 64 KB, grows down from `0x3A0000` (`boot_shim.cyr`: the legacy `mov esp` / `mov rsp` and the ELF64 `mov rsp`; kmain = proc 0 runs and is switched out on it) |
| `[0x3A0000, 0x3B0000)` | UNUSED guard gap — nothing in the tree references it; keep it empty |
| `[0x3B0000, 0x3C0000)` | BSP TSS.RSP0 (`gdt.cyr` `tss_kernel_stack`; the fallback for an unassigned `proc_rsp0`) |

The boot stack was `[0x370000, 0x380000)` from 1.57.3 through 1.57.6; the IMG step moved it up 128 KB because the
1.57.7 plan's image estimates left 4 B of headroom and three flag builds the sweep boots were already past
`0x370000`. It cannot leave region 1 (live from the shim's first instruction, before the direct map exists — see
`boot_shim.cyr` step 12). Neither region-1 stack has a guard page (they are inside the 2 MB identity pages), and
the boot stack's peak depth is **not measured** by any build (`KSTACK_HW` paints only region 7). Measured from
outside at 1.57.7 (IMG-fix): the window is **painted** over QEMU's gdbstub while the VM is held at reset, booted,
then `pmemsave`d — the lowest qword that is no longer paint is a true high-water mark (a lowest-non-zero scan of
the zero-filled window is only a lower bound: at `-smp 4` the deepest qword written was a zero). To the agnsh
prompt: 2,088 B and 2,312 B (`-smp 1`, two boots), 2,328 B (`-smp 4`, KVM); 5,288 B through doom-smoke's
pre-scheduler IF=0 run. The image headroom, the guard gap and the RSP0 window stayed paint in every run.

**What keeps the window free is the firmware.** Nothing reserves `[0x390000, 0x3A0000)` before the shim's first
push: `pmm_init`'s 0–4 MB reservation is the kernel's own bookkeeping, made later; gnoboot pins only the kernel
image (ET_EXEC `AllocateAddress`), allocates the `/initramfs` and `/cmdline` blobs with `AllocateAnyPages`
(EfiLoaderData), and keeps `boot_info` and the memory-map buffer in its own image (EfiLoaderCode), wherever the
firmware loaded it. So kmain checks the map it was handed right after `pmm_probe_memmap`
(`mbi.cyr` `bootstack_window_check`): every descriptor meeting `[0x390000, 0x3C0000)` must be free once
ExitBootServices returns (type 3, 4 or 7), the descriptors must cover the span, and the map buffer must lie outside
it. It prints `boot: BSP stack span 0x390000-0x3C0000 is free RAM in the UEFI map OK`, or
`boot: BSP stack window not free RAM in the UEFI map - type 0x.. at 0x..` — a latched line in
`SMOKE_INVARIANT_DENY` (agnsh-smoke requires the OK line). It cannot move the stack (already in use); it makes the
one iron-only risk of this window observable in the burn's klug/fb transcript. Iron: built, gated, NOT burned.

## The lifecycle boundaries on these stacks (1.57.7, S7)

The lifecycle TICK death (`proc_tick_lifecycle`, [`process-lifecycle.md`](process-lifecycle.md)) runs in the timer
ISR on the dying process's own RSP0 stack, before `do_context_switch`, and only for a CPL3-interrupted frame (INV-L2:
no kernel frame of that process is live below it). The B1 park (a stop at syscall exit or inside a kernel wait) is a
voluntary `int 0xE0` from the syscall path — the process keeps its kernel frame (and the syscall's result) on its
own stack while STOPPED, and resumes on whichever CPU picks it after SIGCONT.

## Rules for code that runs on these stacks

- Never hold a spinlock across a preempt point (Invariant 4 makes a held lock non-preemptible). The one
  sanctioned exception is `wq_arm` under the condition's own lock (`flock_lock`), which the caller drops before
  `wq_sleep` (`blocking-waits.md`, R3).
- Never reuse `pcpu_cpu()`, a `pcpu_*` pointer or per-CPU scratch across a preempt point; re-read after it.
- Never open a preempt window while running on a borrowed CR3 (Invariant 5 refuses the switch; the wait
  would then just spin).
- A new path that makes a process current before ring 3 must call `kstack_install`; a new path that leaves a
  process's stack must publish `on_cpu = -1` only after it is off that stack and CR3.

### Function-local arrays (measured 1.57.7, cycc 6.6.6)

- A function-local `var x[N]` is **N bytes**, rounded up to 8-byte slots. A module-scope `var x[N]` is N u64.
- Slots are allocated in declaration order, and `&x` is the deepest byte, so `x[i]` runs toward `rbp`. An overrun
  therefore hits the local declared **immediately before** `x`, then the earlier locals, then the parameters' home
  slots, and only then the callee-saved save area.
- Whether that corrupts anything depends on whether the victim is **live in its slot**:
  - a local promoted to rbx/r12–r15 leaves a dead home slot;
  - an `asm {}` anywhere in the body turns regalloc off for the whole function
    (`../cyrius/src/frontend/parse_fn.cyr:5062-5096`);
  - a `&local` keeps that local in memory.

  So a "harmless" overrun becomes live after an unrelated edit. msc.cyr's seven `var cdb_buf[2]` (16 bytes
  written into one 8-byte slot, until 1.57.7) were harmless only because every victim was dead in its frame.
- `scripts/check/check-array-sizing.sh` (check.sh) gates the provable shapes: literal, alias, loop-bounded,
  callee-offset and callee-bounded. Size a buffer to the largest write any path can make, never to the bytes one
  caller uses. The precedent is msc.cyr's `var cdb_buf[16]`, because `msc_build_rw10_cdb` zero-fills 16 bytes for
  a 10-byte CDB. `scripts/smoke/msc-cdb-smoke.sh` is the runtime proof for those seven frames (a canary in the
  slot a too-small buffer overflows into).

## The idle's stack in `BOOTCR3_KEEP_GNOBOOT_CR3` builds (1.57.7, S3d §2.8)

Under `BOOTCR3_KEEP_GNOBOOT_CR3` the kthread pool is `.bss`, **4 KB per stack, no guard page**, and `KSTACK_HW` is
skipped — and since S3d the BSP idle does real work on that stack (the idle step's scan and its voluntary switch).
Static worst case, measured on the final S3d plain image from `objdump -d` with `CYRIUS_SYMS` (frame = return address
+ saved rbp + the prologue's `sub rsp` + the deepest transient push depth at a call; tool:
`logs/S3d/B6/stackdepth.py` in the 1.57.7 handoff):
- **(a)** `kernel_idle_loop` (64) → `sched_idle_step` (48) → `sched_yield_kernel` (80) → `sched_switch_vol` (32) →
  `int 0xE0` frame (40 hardware + 120 registers) → `call` (8) → `resched_handler` → `do_context_switch` → `sched_next`
  → … (608) = **≈ 1,000 B**.
- **(b)** the timer ISR landing in the idle's `sti;hlt`: `kernel_idle_loop` (64) → `sched_idle_step` (48) →
  `arch_sti_hlt` (16) → ISR frame (160) → `call` (8) → `timer_handler`'s deepest chain (1,312: `net_rx_drain_isr` →
  … → `net_handle_tcp` → `kmalloc` → `slab_grow` → `pmm_alloc` → …; the new `hid_poll` → `hid_kb_push` → `wq_wake`
  → `sched_kick_mask` → `sched_kick_for` → `apic_send_ipi_one` chain is 1,008, `wq_tick` → kick 512) = **≈ 1,610 B**.
Both are under 3,072 B, so the KEEP pool stays 4 KB per slot (no raise). Re-measure when a deeper call lands under
the timer ISR or the idle step.
