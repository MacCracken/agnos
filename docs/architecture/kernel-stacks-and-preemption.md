# Kernel stacks, the switch tail and preemption — invariants

> **Last Updated**: 2026-09-24 (1.57.6 — Path 2 step S3, bites S3.1–S3.3: per-process kernel stacks, the
> deferred `on_cpu` release, preempt-disabling spinlocks, region-7 guard pages. The voluntary switch, the
> BLOCKED state and the blocking waits land in S3.4+ and extend this document.)
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
- It is called on **every** path that makes a process current before ring 3 can run: `do_context_switch`,
  `sys_sched_yield`'s tail, `exec_and_wait`, execwait#37's resume step (h), and `kernel_resume` (which parks
  the pair on kmain's slot so a dead child's slot is never left installed).
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
  it reuses the cpu index `syscall_handler` already reads for `ksyscall_a4` (a first version read the LAPIC id
  again and cost +20% on getpid at `-smp 4` under KVM, where every LAPIC read is a VM exit).
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
process's own frame, not from the per-CPU `pcpu_kernel_rsp_save` cell the next syscall on that CPU overwrites.
So a syscall switched out mid-flight, or resumed on another CPU, SYSRETs on its own state. `sc_frame_get(pid,
off)` reads a slot. RSP at `call syscall_handler` is `ktop-72 ≡ 8 (mod 16)`, the parity the old three pushes gave.

Stub register contract (1.57.6, S3.3; `syscall: stub 280 bytes of 2048` with `syscall: ibrs=0`): in — rax
num, rdi/rsi/rdx a1–a3, r10 a4, rcx user RIP, r11 user RFLAGS, rsp user RSP; scratch — r8 (the capped cpu),
r9 (a4), r10 (CR3 scratch); out — rax result, rcx/r11 the SYSRET pair, rbx/rbp/r12–r15/rsp from the frame,
rdx/rsi/rdi/r8–r10 whatever the handler left (as before). The stub is **built once** at boot and never
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
  slot, re-validate its (CS,SS) pair, set SPEC_CTRL for the target CPL (`sched_spec_ctrl_for` — the #44 yield
  tail uses the same helper since the S3-fix pass; it used to clear IBRS unconditionally, wrong for a CPL0
  target), and `sched_frame_iretq(fp, cell)`:
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

- Every plain spinlock (`heap vfs mmap proctab fs console nvme ahci vblk msc pmm input tlb_shoot`) calls
  `preempt_disable()` first and its unlock `preempt_enable()` last; a try-lock (`net_rx`, `hid_poll`)
  disables only when it wins. The call adds no local, so the hand-asm `[rbp-N]` slots do not move
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
says 0x1000 and live == `sched_home_cr3`, which is gnoboot's CR3 in a `BOOTCR3_KEEP_GNOBOOT_CR3` build) and it
is not the child of an in-flight execwait#37 (the INTERIM clause — its parent's continuation lives in this
CPU's per-CPU exec cells; S3b-F2 removes it). A **dead** current process is always switchable: `exit`#0 and
`fault_kill_current` end in an IF=1 `sti; hlt` tail at CPL0 whose reaper may already have detached the slot's
CR3 — refusing there would deadlock the reaper's fence.

## Invariant 6 — the out-of-band entries

`exec_and_wait` (every caller: kybernet's agnsh, the NET dig, the recovery `run`, bote, execwait#37) is
**entered IF=0** and the kmain callers get their own IF back after the reap (`kbd_irq_save`/`restore`); the
recovery shell used to return from `run` IF=0 and halt forever at its next `arch_wait`. `exec_and_wait` and
`kernel_resume` latch `sched:` asserts (klug + COM1) if entered with `preempt_count != 0` (or, for
`exec_and_wait`, IF=1). `elf_load_from_file` holds `preempt_count` for the whole load (its per-CPU header
buffer and env cells are live across it); kybernet additionally brackets its env set + load.
`power_stop_final` starts with `arch_cli` (kmain reaches it IF=1 now).

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

## Rules for code that runs on these stacks

- Never hold a spinlock across a preempt point (Invariant 4 makes a held lock non-preemptible).
- Never reuse `pcpu_cpu()`, a `pcpu_*` pointer or per-CPU scratch across a preempt point; re-read after it.
- Never open a preempt window while running on a borrowed CR3 (Invariant 5 refuses the switch; the wait
  would then just spin).
- A new path that makes a process current before ring 3 must call `kstack_install`; a new path that leaves a
  process's stack must publish `on_cpu = -1` only after it is off that stack and CR3.
