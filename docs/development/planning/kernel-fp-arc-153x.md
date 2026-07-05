# Kernel FP/SIMD capability arc — f64 in ring-3 (slotted 1.53.x)

**Status (2026-07-05): ▶ OPEN — B1 SHIPPED as agnos 1.53.0.** Opened right after
the 1.52.x audio-output arc closed (iron-validated), per user direction ("open
1.53.0 and get the plan together and foundational work for .0"). No new hardware:
SSE2 is x86-64 baseline, so this rides the **archaemenid AMD Zen** target the
1.50–1.52 arcs already use.

### Bite → cut mapping (each bite = its own cut, strictly sequential)

| Bite | Cut | What | State |
|------|-----|------|-------|
| **B1** | **1.53.0** | Enable SSE per core (BSP + every AP); FP-free-kernel invariant; ring-0 f64 proof | **✅ DONE + QEMU 4/4 (2026-07-05)** |
| **B2** | **1.53.1** | Per-proc FXSAVE state array + per-CPU `fpu_owner` + **hand-built** default image | **✅ DONE + QEMU 2/2 (2026-07-05)** |
| **B3** | **1.53.2** | Lazy `#NM` handler + `CR0.TS`-on-both-switch-paths + `fpu_owner` + deschedule-FXSAVE + `#XM` handler | **✅ DONE + QEMU (2026-07-05) — iron-gated (SMP migration → B5 burn)** |
| **B4** | **1.53.3** | Ring-3 f64 first-touch FXRSTOR (single-owner, end to end) | **✅ DONE + QEMU (2026-07-05) — real cyrius f64 in ring 3, `run: exit 84`** |
| **B5** | 1.53.4 | Two-proc FP-preservation stress (timer / cooperative-yield / `-smp` migration) | Planned |
| **B6** | 1.53.5 | `naad` on agnos ring-3 (the green end-proof) + cyrius issue-doc confirm + iron burn | Planned — arc-closing |

**B1 adversarial re-verification (multi-agent, 2026-07-05): CONFIRMED ship-safe.**
Every opcode byte re-derived against `objdump` ground-truth (all decode as
commented in 64-bit mode); the 32-bit `eax` RMW zeroing `RAX[63:32]` is safe for
both CR0 and CR4 (every defined bit is in `[0:31]`, high halves reserved-MBZ);
`FNINIT` is correct hygiene (clean x87 baseline for the future FXSAVE image).
Actioned: (1) **low — `OSXMMEXCPT` set without a `#XM` handler** → kept (correct
routing; unreachable under the all-masked `0x1F80` MXCSR default), documented in
`fpu.cyr`, real handler deferred to **B3**; (2) **medium — FP-free audit
durability**: `grep -c xmm` misses `fxsave`/`fxrstor` (B2/B3 add them
legitimately), so the standing gate is hardened to `grep -Ec
'xmm|fxsave|fxrstor|emms|femms'` — 0 on the 1.53.0 production build; (3) low —
stale "AP path is ENTIRELY INERT" comments (`smp.cyr`/`sched.cyr`/`proc.cyr`)
predate live AP-wake; reconcile out of band. Per-bite grounded refinements are
inlined below as *[2026-07-05]* notes.

This arc gives the agnos kernel the FPU/SSE state-management infrastructure so
**ring-3 cyrius programs can use `f64` (and later int-SIMD / `f64v2`/`f64v4`)**.
`naad` (the f64 audio-synthesis lib) is the exposing case and the green end-proof.

---

## The gap — measured, not theorized (2026-07-04)

cyrius emits **hardware SSE for scalar `f64`**. A trivial `f64` mul/div/add built
with `cyrius build --agnos` disassembles to `addsd`/`divsd`/`mulsd` on
`xmm0`/`xmm1`. So *any* `f64` arithmetic in a cyrius program touches XMM.

The agnos kernel enables **no FP at all**:

- `boot_shim.cyr` sets `CR4 = PAE + (CPUID-gated) SMEP/SMAP` only; `CR0 = PG + PE`
  only. **No `CR4.OSFXSR` (bit 9, 0x200)**, no `CR4.OSXMMEXCPT` (bit 10, 0x400),
  no `fninit`, no `clts`, no `CR0.MP`/`EM` handling anywhere in `kernel/`.
- Consequence: the **first `movsd` in any ring-3 `f64` program raises `#UD`
  immediately** — SSE is never turned on.
- `do_context_switch` (`kernel/core/sched.cyr:298`) saves/restores **GP registers
  only** via `proc_save_context`/`proc_restore_context`. No XMM. So even with SSE
  enabled, two `f64` procs corrupt each other's floating state across a switch.
- The proc slot is **176 bytes** (22 fields × 8; `pid * 176` stride hardcoded at
  ~16 sites, `proc.cyr:29,59-60`) — a 512-byte `FXSAVE` area cannot go inline.

**naad exposes it concretely.** `naad` 2.1.0 (`--agnos`) *compiles clean* (0
errors; its Cyrius port already flows `f64` through the `f64_*` stdlib helpers,
which are declared `: i64` — `f64` bit-patterns transported as integers — so no
fn declares a scalar-`f64` return type). The `--agnos` binary contains **26,647
XMM-touching instructions** (2606 `mulsd`, 1166 `addsd`, 670 `divsd`, 118
`sqrtsd`, 721 `cvtsi2sd`…). Running it on agnos today = **`#UD` on the first SSE
op** (`movq %rax,%xmm0; roundsd`). This is a **runtime fault, not a compile
error**, and it is the exact wall `nidhi` (sample playback) and the
`rosnet`/`tyche`/`hisab` f64 on-device-ML future all inherit.

---

## Committed mechanism

Six decisions, grounded against the live 1.52.8 tree:

1. **Enable = EAGER at boot, per core.** A new `fpu_enable()` (Cyrius `asm {}`):
   clear `CR0.EM` (bit 2), set `CR0.MP` (bit 1), set `CR4.OSFXSR` (0x200) +
   `CR4.OSXMMEXCPT` (0x400), then `fninit`. Called **twice**: on the BSP in
   `core/main.cyr` right after `pt_init()` (CR3 0x1000 live, before any ring-3
   entry), and on **each AP** in `ap_entry()` (`smp.cyr:369`) beside the proven
   per-core `syscall_msr_init()` (`smp.cyr:407`) / `tss_init_cpu()`. CR0/CR4 are
   per-core, so the enable **must** run on BSP + every AP. **Do NOT touch either
   hand-assembled trampoline** (`boot_shim.cyr` raw-opcode CR4 block; the
   `smp.cyr` AP trampoline) — both set `CR4 = PAE-only` in literal opcode bytes
   on the boot-critical path; enabling one instruction later in high-level Cyrius
   is dramatically lower risk. (CR0 after reset is `0x60000010`, so `EM=0` already
   — clearing `EM` + setting `MP` is defensive hygiene, not strictly required to
   avoid `#UD`, but `OSFXSR` **is** required or SSE `#UD`s.)

2. **Save format = `FXSAVE`/`FXRSTOR` (512 bytes, legacy), NOT `XSAVE`.** FXSAVE
   covers x87 + SSE (XMM0–15 + MXCSR) — everything scalar `f64`, `f64v2`
   (128-bit XMM), and SSE2 int-SIMD need. `XSAVE`/`XSAVEOPT` (for `f64v4` 256-bit
   YMM / AVX) is deferred to a **future bite gated only on a consumer actually
   using `f64v4`** (see Open questions). 16-byte alignment required.

3. **Per-proc FP state = a SEPARATE module-global sibling array, never
   slot-inlined.** `var fpu_state[1026];` in `proc.cyr` (8208 bytes = 16 procs ×
   512-byte FXSAVE + 16-byte align slop). This is the *exact* blessed precedent of
   `proc_cs[16]`/`proc_ss[16]`/`proc_ppid[16]`/`proc_on_cpu[16]`/`proc_rsp0[16]`
   (`proc.cyr:64-137`) — parallel pid-indexed arrays created specifically to avoid
   the `pid * 176` stride at ~16 sites. FXSAVE needs 16-byte alignment; cyrius
   module-global `var X[N]` is N × u64 (8-aligned start, not guaranteed 16), so
   align at use: `fpu_area(pid) = ((&fpu_state + 15) & ~15) + pid * 512` (512 is a
   multiple of 16, so every slot stays aligned; the `[1026]` over-size absorbs the
   +15 slop). **No** struct extension (breaks ~16 stride sites + the 16-field
   derive-accessor cap), **no** heap pointer (adds alloc lifecycle + a null-deref
   failure mode on the switch hot path).

4. **Save/restore = LAZY (`CR0.TS` + `#NM` vector-7 handler), NOT eager FXSAVE in
   the switch.** `do_context_switch` gains exactly **one line**: set `CR0.TS` on
   every real switch, placed in the region the code documents as **outside the
   cc5-regalloc-sensitive raw save/restore zone** (beside the `tss_set_rsp0` /
   kpti-cr3 updates, ~`sched.cyr:319-360`). All heavy FP work lives in a **new
   vector-7 (`#NM`, device-not-available) ISR**: on first `f64` use after a
   switch, `#NM` fires; the handler clears `CR0.TS`, `FXSAVE`s the previous
   owner's area (if valid and ≠ current), `FXRSTOR`s current's area, records the
   new owner, and `iretq`s to **retry** the faulting instruction. Vector 7 is
   **deliberately reserved-not-installed today** (`idt.cyr:76,91` — the comment
   explicitly names "`#NM/7` from SSE use"); installing it is the intended path.
   Rationale: the raw zone is the documented source of the 1.46.1 iron timer-ISR
   `iretq` `#GP` and the v1.28.3 accessor-port boot break — touching it to add
   FXSAVE risks re-triggering that regalloc bug class (which manifests **iron-only**;
   QEMU never reproduced it). Lazy keeps the switch edit to a single `CR0.TS`
   write in the already-blessed region, moves all FP-register work into a fresh,
   independently-testable ISR, and is a perf win (FP-free thread switches never
   touch XMM).

5. **FP ownership = PER-CPU, not a single global.** `var fpu_owner[4];` default
   -1, indexed by CPU id like `pcpu_curproc[4]` / `proc_on_cpu`. Each core has its
   own live XMM; a single global `fpu_owner` corrupts XMM across cores once
   `smp_sched_aps=1` (the default, `smp.cyr:151`). This is a **must-fix baked into
   B3**, not optional hardening.

6. **Kernel-stays-FP-free = an AUDITED, greppable invariant.** Confirmed this
   session: `objdump -d build/agnos | grep -icE 'xmm|movsd|addsd|mulsd|divsd'`
   == **0**. Policy: no kernel-side `f64` in any steady-state path
   (timer/syscall/sched/driver). Enforced by a **standing `objdump==0` gate**
   (see Cross-cutting). Rationale: once `CR0.TS` is set on a switch, **any** kernel
   `f64` before the next `#NM` would itself `#NM` on the interrupt path.
   `fpu_owner[cpu] == -1` (kernel context) is the do-not-restore sentinel.

---

## Bites (each bootable, QEMU-gated, its own cut)

Strict correctness order: enable → storage → switch-preserve → ring-3 → stress →
naad. Every bite adds a `#ifdef FP_*_SELFTEST` block in `selftests.cyr` (gated by
an env var `build.sh` turns into a `#define`, per the HDA/TONEGEN precedent) +
a matching `scripts/fp-*-smoke.sh`, and registers the flag in `build.sh`'s
`*_SELFTEST` allow-list. The default/production build stays byte-identical.

### B1 — Enable SSE on BSP + every AP; audit kernel FP-free; ring-0 proof — ✅ SHIPPED 1.53.0 (2026-07-05)
*As shipped:* `fpu_enable()` in `kernel/arch/x86_64/fpu.cyr` (raw CR opcodes +
`fninit`, no xmm) on the BSP (`main.cyr` after `pt_init()`, `+ "SSE enabled"`) and
every AP (`smp.cyr` `ap_entry()`). Production `objdump -Ec 'xmm|fxsave|fxrstor'`
== 0. `FP_SELFTEST` build adds the raw `movsd` probe + a cyrius `f64` `3.0*2.0==6.0`
ring-0 proof; `scripts/fp-selftest-smoke.sh` greps `SSE enabled` + `fp: movsd OK`
+ `fp: ring0 OK` + boot-to-shell — **4/4 green**; registered in `sweep.sh` +
`build.sh`. Adversarially re-verified (see Status). *Original plan (B1a/B1b) below,
kept as the record:*
- **B1a (invariant + enable):** add `fpu_enable()` in a new
  `kernel/arch/x86_64/fpu.cyr`; call it on the BSP after `pt_init()` (with a
  `kprintln("SSE enabled")` + CMOS checkpoint) and in `ap_entry()` beside
  `syscall_msr_init()`. **Prove SSE is live with a raw `movsd` `asm` probe** (no
  stdlib `f64`), so this bite does **not** put any `f64` in the default binary.
  Gate: boot-to-shell stays green (`agnsh-smoke`) with `fpu_enable` always-on,
  **and** `objdump -d build/agnos | grep -c xmm` == 0 on the production build.
- **B1b (arithmetic proof):** a ring-0 `f64_mul(3.0, 2.0)` inside the
  `FP_SELFTEST`-only build (never the default), asserting `fp: ring0 OK` (no
  `#UD`). `scripts/fp-selftest-smoke.sh` (QEMU + KVM) greps `SSE enabled` +
  `fp: ring0 OK`.
- **Repo:** agnos kernel.

### B2 — Per-proc FP-state array + per-proc `fninit` init (pure additive state) — ✅ SHIPPED 1.53.1 (2026-07-05)
*As shipped:* `fpu_state[1026]` + `fpu_owner[4]` in `proc.cyr` + `fpu_area(pid)`
(16-align) + `fpu_area_reset`/`fpu_area_init` (hand-built fninit-equiv default:
`FCW=0x037F`, `MXCSR=0x1F80`, **no `fxsave`** → production stays FP-free);
`fpu_area_init()` at boot after `fpu_enable`, `proc_alloc_slot` resets recycled slots.
`FP_AREA_SELFTEST` + `fp-area-smoke.sh` → `fp: area OK`, 2/2 green. Also fixed a stale
`proc.cyr` IF=0-cooperative comment. *Original plan below:*
- Add `var fpu_state[1026];` + `var fpu_owner[4];` (default -1) to `proc.cyr`,
  documented like the `proc_cs`/`proc_ss` siblings. Add `fpu_area(pid)` with the
  16-byte align-up. **Zero + write an `fninit`-derived default FXSAVE image**
  into each proc's 512-byte slot at creation (in `proc_alloc_slot` beside the
  `proc_cs`/`proc_ss`/`proc_ppid` inits) so the first `FXRSTOR` never loads a
  garbage MXCSR (reserved-bit `#GP`). No switch-path change yet.
- **Gate:** `FP_AREA_SELFTEST` asserts `fpu_area(pid)` is 16-aligned for all 16
  pids **and** each slot's default MXCSR == `0x1F80`. `exec-smoke` + `agnsh-smoke`
  stay green (additive only).
- **[2026-07-05] decision (as shipped):** the grounded pass suggested capturing a
  real `FXSAVE` at boot (to guarantee FXRSTOR-legality); B2 instead **hand-builds**
  the default (zeroed + `FCW=0x037F` + `MXCSR=0x1F80`) via plain stores — this keeps
  the kernel FP-free through B2 (no `fxsave` until B3's `#NM` handler) and the image
  is FXRSTOR-legal (MXCSR valid under any MXCSR_MASK, reserved area zeroed). One
  `fpu_area_init()` seeds all 16 at boot; `proc_alloc_slot` resets a recycled slot so
  a new proc never inherits the previous occupant's saved XMM. **If B4's
  first-FXRSTOR test ever `#GP`s, B3 switches to a boot-captured image.**
- **Repo:** agnos kernel.

### B3 — Lazy `#NM` handler + `CR0.TS`-on-switch + per-CPU `fpu_owner` (the core)
- Add `nm_isr_build()` mirroring `timer_isr_build`'s **exact** push-GPRs →
  `mov rdi,rsp` → `call handler` → pop → `iretq` shape, plus a Cyrius
  `nm_handler(rsp)`: clear `CR0.TS`; `cpu = pcpu_cpu()`; if `fpu_owner[cpu]` is
  valid and ≠ current, `FXSAVE` its area; `FXRSTOR` current's area; set
  `fpu_owner[cpu] = current`. Wire `idt_set_gate(&idt + 7*16, &nm_isr, 0x08,
  0x8E)` in `main.cyr` beside the timer(32)/kbd(33)/nic(80) gates.
- **Set `CR0.TS` on BOTH switch paths** (adversarial-review fix — the cooperative
  path was missing): route `do_context_switch` **and** `sys_sched_yield`
  (`sched.cyr:495`) through a shared `fpu_mark_switch()` that sets `CR0.TS`, both
  in the outside-the-raw-zone region. Missing the yield path = silent XMM
  corruption on cooperative yields.
- **Resolve the SMP migration race** (adversarial-review fix, committed here not
  deferred): because `sched_next()` has zero CPU affinity and APs run real procs,
  a proc that owns FP on CPU0, migrates to CPU1, and touches `f64` would `FXRSTOR`
  a **stale** area (CPU0 never `FXSAVE`d its live regs). Fix: **eager
  `FXSAVE`-on-deschedule** for the owning core — when a proc is descheduled and
  `fpu_owner[cpu] == descheduling_pid`, `FXSAVE` it then and clear the owner.
  Only FP owners pay this; FP-free switches stay cheap.
- **Gate:** `FP_NM_SELFTEST` — force `CR0.TS`, run an XMM op, assert a one-shot
  `fp: #NM serviced` latch (the r8169 "RX MSI LIVE" flag-in-ISR/print-once
  technique) + the op completed, with **no infinite `#NM` loop / `#DF`**. Add a
  **nested-`#NM` stress** (high timer rate during FP churn — a timer landing
  *during* `#NM` service). **Highest-risk bite** (iretq-frame + regalloc + the
  iron-only regression class) — QEMU-green is necessary but the **iron burn is
  the real gate**.
- **[2026-07-05] refinement:** (a) add a **`#XM` (vector 19) handler** here too
  (CMOS-stamp + halt) — B1 enabled `OSXMMEXCPT` but left #XM on the default stub;
  (b) size `nm_isr`'s `.bss` buffer like `timer_isr[64]`/`nic_rx_isr[64]` (module
  `var X[64]` = 512 B); (c) the cooperative `CR0.TS` write goes in
  `sys_sched_yield`'s OUTSIDE-raw tail (~`sched.cyr:555-560`), NOT the SYSRET-parity
  raw store64 block; (d) the IDT is shared (APs `lidt` the same `&idt`), so the
  BSP-installed vector-7 gate is live on APs automatically.
- **Repo:** agnos kernel.

#### B3 — VERIFIED DESIGN (adversarial workflow, 2026-07-05) — the implementation blueprint

> **B3 SHIPPED (a+b) + QEMU-validated (2026-07-05, cut 1.53.2):** the full lazy-`#NM`
> per-proc FP context switch is wired LIVE. **B3a** (additive machinery) —
> `fpu_do_fxsave`/`fpu_do_fxrstor` (leaf `[rbp-8]` helpers), `fpu_set_ts`/`fpu_clear_ts`,
> `nm_handler`, `nm_isr_build` (→ `nm_isr[64]`), `fpu_deschedule_save`, the vector-7 IDT
> gate, and the **#XM (vector 19)** halting handler. **B3b** (wire it live) —
> `fpu_deschedule_save` under-lock-BEFORE-unfence at sched.cyr:337/556; `fpu_set_ts`
> post-restore on `do_context_switch` + `sys_sched_yield` + the completeness chokepoints
> `enter_ring3` and `kernel_resume`; `fpu_owner` cleared on the `fault_kill_current` /
> `exit#0` death paths + a `proc_alloc_slot` sweep. Production audit is now **exactly 2
> sanctioned fxsave/fxrstor, 0 stray xmm**. **Validated:** `FP_NM_SELFTEST` /
> `fp-nm-smoke.sh` 3/3 (forced `#NM` serviced + op retried), full battery green with the
> machinery LIVE (agnsh-smoke, ring3-smoke 6/6 — do_context_switch preemption +
> sched_yield#44 + slot recycle, exec-smoke death paths, FP_SELFTEST 4/4, FP_AREA 2/2).
> **IRON-GATED:** the SMP-migration fix is unvalidatable on single-core QEMU — an `-smp 4`
> migration soak + the context-switch-raw-zone burn are the dispositive B3 exit criteria
> (folded into B5). Also fixed a stale sched.cyr "INERT until exec_preempt" comment.


Core mechanism **CONFIRMED** (leaf-helper regalloc isolation; no-errcode `#NM` iretq
retries the faulting op; nested-`#NM` impossible — the 0x8E gate clears IF so no
timer lands mid-handler; production stays FP-free except the sanctioned sites; the
`#XM`/AP-resume paths are correct). **3 HIGH fixes reshape the wiring — implement THIS,
not the raw plan:**

**Regalloc-safe leaf helpers** (`fpu.cyr`) — each a standalone single-param fn, byte-identical
prologue to the proven `cr3_load` (`48 8B 45 F8` = `mov rax,[rbp-8]`). **MUST NOT gain a second
local/param** (shifts the ABI slot off `[rbp-8]` → revives the v1.28.3/spill class):
- `fpu_do_fxsave(addr)`: `mov rax,[rbp-8]` + `0F AE 00` (`fxsave [rax]`).
- `fpu_do_fxrstor(addr)`: `mov rax,[rbp-8]` + `0F AE 08` (`fxrstor [rax]`). *(These are the FIRST
  `fxsave`/`fxrstor` in production — B3 flips the audit from 0 to exactly 2 sanctioned sites.)*
- `fpu_set_ts()` / `fpu_clear_ts()`: CR0 raw RMW (`0F 20 C0` / `or eax,8` \| `and eax,~8` / `0F 22 C0`).
- `clts` (`0F 06`) immediately before every eager `fxsave` — so the save never depends on ambient
  `TS` (drops the unproven "fxsave isn't TS-gated" assumption).

**`nm_handler(rsp)`** — `fpu_clear_ts(); cpu=pcpu_cpu(); prev=fpu_owner[cpu]; cur=proc_current_get();
if prev!=cur { if prev!=-1: fpu_do_fxsave(fpu_area(prev)); fpu_do_fxrstor(fpu_area(cur));
fpu_owner[cpu]=cur }`. `fpu_area(...)` is the pure-arithmetic B2 fn, passed BY VALUE into the
`[rbp-8]` helper. **`nm_isr_build()`** mirrors `timer_isr_build` (pic.cyr:88) byte-for-byte into a
new `nm_isr[64]` (boot_data.cyr), `handler=&nm_handler`, keep `mov rdi,rsp`, plain `iretq` (no
errcode); wire `idt_set_gate(&idt + 7*16, &nm_isr, 0x08, 0x8E)` in main.cyr after `fpu_area_init()`.

**`#XM` (vector 19)** — extend `exc_handlers_init` (idt.cyr) to `nvec=8` with `v=19`: it takes the
plain CMOS-stamp + FB-canary + `cli;hlt` tail (not in the `{6,13,14}` ring3-kill set).

**★ HIGH-1 — SPLIT the deschedule-save from the TS-set** (they go at DIFFERENT sites; combining them
is the stale-area race):
- `fpu_deschedule_save(old)`: `cpu=pcpu_cpu(); if fpu_owner[cpu]==old { clts; fpu_do_fxsave(fpu_area(old));
  fpu_owner[cpu]=-1 }`. Placed **UNDER `sched_lock`, BEFORE the `on_cpu_set(...,-1)` unfence** — at
  `sched.cyr:337` (do_context_switch, after `proc_save_context(old)`) AND `sched.cyr:548`
  (sys_sched_yield, before `on_cpu_set(yp,-1)`). *(If placed after the unfence/unlock at :370, CPU1 can
  pick `old` and FXRSTOR a stale area before CPU0 saves it — the migration race B3 exists to close.)*
- `fpu_set_ts()`: post-restore, beside `tss_set_rsp0` at `sched.cyr:370` (do_context_switch) AND
  `sched.cyr:560` (yield). Pure register RMW, no area — safe outside the raw zone.

**★ HIGH-2 — TS-completeness: cover the out-of-band ring-3 entries + the exec-return.** `fpu_mark_switch`
on the two scheduler paths is NOT enough — the running proc also changes via `proc_current_set(pid);
exec_and_wait → enter_ring3 → iretq` at SIX sites (init/shell/syscall/main) that never set `CR0.TS`.
Two sequential f64 procs (`run /bin/naad` then `/bin/nidhi`) would leak XMM. Fix at the **two
chokepoints**, not the six call sites:
- `fpu_set_ts()` in **`enter_ring3`** right before its final `iretq` (~ring3.cyr:201) — covers all six
  exec/spawn entries.
- `fpu_set_ts()` in **`kernel_resume`** after `proc_current_set(0)` (syscall.cyr:301) — the
  foreground-exec-return to the parent shell.

**★ HIGH-3 — clear `fpu_owner` on death** (else a recycled slot's same-pid `prev==cur` fast-path SKIPS
the restore → silent XMM leak into a new proc). Mandatory, NO fxsave (dying XMM is garbage):
- After `proc_set_state(pid,0)` in `fault_kill_current` (syscall.cyr:370) AND `exit#0` (syscall.cyr:661):
  `var _c=pcpu_cpu(); if load64(&fpu_owner+_c*8)==pid { store64(&fpu_owner+_c*8,-1) }`.
- Belt-and-suspenders: `proc_alloc_slot` sweeps `fpu_owner[0..3]`, clearing any `==idx`, right after
  `fpu_area_reset(idx)`.

**Gates:** `FP_NM_SELFTEST` (force TS, XMM op, assert one-shot `fp: #NM serviced` latch + no loop/`#DF`,
+ a nested-#NM stress) + a **disassembly gate** grepping the built helpers for the exact `48 8B 45 F8`
prologue (catches a future cyrius regalloc move before iron) + the **FP-free audit hardened to "== exactly
2 sanctioned `fxsave`/`fxrstor`, 0 stray xmm"** (a build assertion, not a comment). **DISPOSITIVE EXIT
CRITERION: the migration-race fix is UNVALIDATABLE on single-core QEMU — B3 sign-off gates on an `-smp 4`
iron migration soak (an FP proc observed moving CPU0→CPU1 preserving XMM), folded into B5.**

### B4 — Ring-3 `f64` selftest (first-touch restore, end to end) — ✅ SHIPPED 1.53.3 (2026-07-05)
*As shipped:* `fp-test/fpex.cyr` (built `--agnos`, staged `/bin/fpex`) — a **compiled
cyrius** program (not hand-asm, per the refinement) that computes `7*3=21`, `+1=22`,
`/2=11` with native f64 codegen (mulsd/addsd/divsd/comisd) and exits 84 iff all correct.
`FP_RING3_SELFTEST` kernel block exec's it from disk; `scripts/fp-ring3-smoke.sh` asserts
`run: exit 84` — **PASS**. Proves B1→B3 end to end (enable → area → `#NM` restore →
ring-3 f64) AND that the B2 hand-built default image is FXRSTOR-legal (no `#GP` on the
first restore → the boot-captured-image fallback was not needed). Single-owner first-touch
only; the FXSAVE-of-previous-owner limb is B5. *Original plan below:*
- A tiny ring-3 exerciser proc does an `f64` mul (via the `f64_*` helpers naad
  uses) and syscalls the result back; `FP_RING3_SELFTEST` + `fp-ring3-smoke.sh`
  assert the byte-pattern. Proves BSP-enable → per-proc-area → `#NM`-restore →
  ring-3-use. **Claim scope (review fix):** this proves only the single-owner
  *first-touch `FXRSTOR`* path; the `FXSAVE`-of-previous-owner limb is
  unexercised until B5. Add a **first-`FXRSTOR`-into-a-never-run-proc-does-not-`#GP`**
  assertion here (proves the B2 default image is FXRSTOR-legal).
- **[2026-07-05] refinement:** build the exerciser as a **cross-built Cyrius app**
  (tonegen-form entry: bare top-level call + `SYS_EXIT`), NOT hand-assembled ELF —
  the `f64_*` helpers are only reachable from compiled Cyrius. `kprint_num` is
  SIGNED, so read the result back as an `f64_to`'d small int, never a raw f64
  bit-pattern (sign bit → misleading negative). Do NOT run B4 under `-smp` / let a
  2nd FP proc co-reside — that would smuggle B3's FXSAVE-of-previous-owner path
  (B5's proof surface) into a B4 pass and hide a B5 bug.
- **Repo:** agnos kernel.

### B5 — Two-proc FP-preservation stress (the correctness proof for lazy)
- Two ring-3 procs each load a **distinct known XMM pattern**, interleave, then
  re-read and assert their XMM **survived the other proc's FP use**. Run three
  ways: (a) timer-preempted, (b) **cooperative — switch driven by the
  `sys_sched_yield` syscall, not the timer** (review fix — without this the #1
  hole ships green), (c) under `-smp` with an **asserted migration** (prove the
  `-smp` run actually moves the proc across cores, exercising per-CPU
  `fpu_owner` + the deschedule-FXSAVE). `FP_CTXSW_SELFTEST` + `fp-ctxsw-smoke.sh`.
- **[2026-07-05] refinement (biggest false-green risk):** modes (a) timer + (b)
  cooperative-yield are **architecturally impossible via the foreground
  `exec_and_wait` path** (IF=0, single-proc, run-to-completion, timer-never-
  preempts, `sys_sched_yield` no-ops). They REQUIRE the `exec_preempt=1` / IF=1
  background co-scheduling model (`ring3.cyr:21-32`) — the launcher MUST use it or
  B5 ships green having performed ZERO inter-proc FP switches (the exact hole it
  exists to catch). Also: write a distinct pattern into **all 16 XMM regs
  (xmm0–15)**, not just the SysV-arg low 8; force a real migration in mode (c) with
  an **asymmetry** (e.g. 3 FP procs on `-smp 2` — a sticky affinity-free round-robin
  won't migrate 2-on-2); and confirm two concurrent FP procs' read-back syscalls
  are per-CPU-safe (a new two-proc concurrent-syscall load prior selftests never
  generated).
- **Repo:** agnos kernel.

### B6 — naad build + run on agnos ring-3 (the green end-proof)
- Cross-build `naad` `--agnos`, run an oscillator/synth exerciser in ring-3 under
  QEMU (`naad-smoke.sh`), assert **finite non-NaN samples** out. In **parallel,
  not blocking B1–B5**: file the cyrius issue-doc (below). Only after **all**
  QEMU-green: the **iron burn** (archaemenid) validating `f64` on real Zen ring-3.
  Once the path is proven, `tonegen` can optionally swap its hand-rolled integer
  waveforms for real `naad` oscillators as a richer audio test.
- **[2026-07-05] refinement:** naad `--agnos` (2.1.1) was cross-built + audited —
  **26,647 XMM but 0 YMM/AVX**, so **FXSAVE is confirmed sufficient** (Open Q#1
  resolved). Add a STANDING `objdump -d build/naad-agnos | grep -c '%ymm' == 0`
  guard in `naad-smoke.sh` (a future auto-vectorizer / `f64v4` would make FXSAVE
  silently truncate YMM = finite-but-wrong samples). The exerciser is a **net-new
  `audio-test/naadex.cyr`** (tonegen-form; naad's own `main.cyr` uses the forbidden
  `var r=main();syscall(60)` entry) — oscillator + one filter + one envelope,
  `naad_is_finite` on every sample, heap-alloc the buffer (~12 KB ring-3 stack).
  The cyrius issue-doc is **already filed** (`cyrius/…/issues/2026-07-04-…`): §2
  f64v2/v4 constructors RESOLVED v6.4.3, §3 int-SIMD noted, §1 scalar-f64-return
  still open on 6.4.5 — B6's only cyrius action is a one-line §1 status confirm
  (needs approval; non-blocking).
- **Repo:** agnos kernel + naad (consumer) + cyrius (issue-doc only).

### Cross-cutting (every bite)
- **Promote the FP-free `objdump` audit to a standing gate** across ALL bites (and
  beyond), not just B1 — a single future kernel `f64` (a driver stat, a bench
  print) would `#NM` on the interrupt path once `CR0.TS`-on-switch ships.
  **Hardened grep** *[2026-07-05]* (a plain `grep xmm` misses the FP-state ops that
  don't name a register): `objdump -d build/agnos | grep -Ec
  'xmm|fxsave|fxrstor|emms|femms'`. From B3 on, the ONLY sanctioned matches are the
  `fxsave`/`fxrstor` inside the `#NM` handler + deschedule path, so the gate becomes
  "no FP ops OUTSIDE the sanctioned save/restore sites" (verify the match locations).
- No `VERSION` bump without explicit approval; each bite = its own cut touching
  CHANGELOG + `state.md` + the agnosticos iron-log only.
- Register each new `*_SELFTEST` in `build.sh`'s allow-list; add its smoke to
  `sweep.sh`. Verify `build/agnos` reflects HEAD before any install/burn.

---

## Cyrius coordination — decoupled (confirmed by adversarial review)

**The kernel bites B1–B5 need ZERO cyrius changes.** naad's `f64`-returning fns
(e.g. `naad_directivity_gain_polar`, `acoustics_directivity.cyr:74`) compile fine
because the stdlib `f64_*` helpers are declared `: i64` (`math.cyr:204` — `f64`
bit-patterns transported as `i64`), so **no fn declares a scalar-`f64` return
type**. The XMM-state infrastructure is fully expressible with existing cyrius
(`asm` blocks + the `f64_*` helpers). Do **not** gate the kernel arc on the peer
repo (per the don't-chase-pin / opt-in-libs discipline).

**File ONE cyrius issue-doc** (the permitted cyrius interaction — do NOT edit
cyrius) at B6, covering consumer-ergonomics + future SIMD, with the observed
error strings:
- **Scalar `f64` is not an allowed fn RETURN type** — `error: fn return type must
  be struct or i8/i16/i32/i64/Result/Option/Tagged/cstring/f64v2/f64v4`. Gates
  natural `f64`-returning synth loops (naad works around it via `i64`-typed
  helpers, but it's an ergonomic wall for new f64 code).
- **`f64v2`/`f64v4` need intrinsic constructors** — `f64v2(a, b)` is a
  reachable-undefined symbol today.
- **Int-SIMD (SSE2 integer)** — the same XMM-state kernel infra enables it; frame
  the ask as "the kernel FP arc unblocks all three (scalar f64, float-SIMD,
  int-SIMD); here's what cyrius owes on the codegen side."

**This is the foundational XMM-state layer for ALL of cyrius SIMD** — not a narrow
audio detour. One arc unlocks scalar `f64` (naad/nidhi), float-SIMD, int-SIMD
(the "more int/simd support soon" cyrius roadmap), and the on-device-ML f64 future
(`rosnet`/`tyche`/`hisab`).

---

## Naming / scope

**No new repo.** This is a kernel-internal capability (an in-tree
`kernel/arch/x86_64/fpu.cyr` + `proc.cyr` sibling arrays + an IDT gate),
consistent with the SMEP/SMAP/KPTI/syscall-MSR precedent — none of which are
repos. If a user-facing name is ever wanted for the *capability*, it stays in the
Sanskrit/Hindi system-lib lane, but the arc itself needs none.

---

## Open questions

1. **`XSAVE` for `f64v4`/AVX — RESOLVED (2026-07-05): FXSAVE is sufficient.** naad
   `--agnos` (2.1.1) was cross-built + audited: 26,647 XMM but **0 YMM / 0 AVX**
   (`vaddpd`/`vmulpd`/`ymm`/`vzeroupper` all absent) — pure scalar SSE2 + 128-bit
   packed XMM (incl. `roundsd` SSE4.1, Zen baseline). So FXSAVE (512 B) covers it
   and `XSAVE`/`XCR0` stays deferred. **Now a live regression risk, not a one-time
   audit**: a future auto-vectorizer / `f64v4` inner loop would make FXSAVE silently
   truncate YMM[255:128] across a switch → finite-but-wrong samples (green smoke).
   B6 carries the standing `ymm==0` guard as the tripwire.
2. **First-`FXRSTOR` default image: static vs runtime-captured.** B2 writes an
   `fninit`-derived default; confirm (B3/B4) the first `FXRSTOR` of a never-run
   proc does not `#GP` on reserved MXCSR/FXSAVE-header bits — capture a real
   `FXSAVE` image once at boot if the hand-built default is reserved-bit-illegal.
3. **Migration actually observed under `-smp`.** B5 must *assert* a proc migrates
   cores (don't assume co-residency), or the per-CPU-`fpu_owner` + deschedule-
   FXSAVE path ships unexercised.
4. **Iron-only regalloc risk on the `CR0.TS` line.** The one switch-path write
   lives next to the zone that produced the 1.46.1 iron-only `iretq` `#GP`. QEMU
   cannot fully clear this class — the B3 iron burn is load-bearing.

---

## Validation harness (to build with the arc)

- `selftests.cyr` `#ifdef FP_SELFTEST` / `FP_AREA_SELFTEST` / `FP_NM_SELFTEST` /
  `FP_RING3_SELFTEST` / `FP_CTXSW_SELFTEST` blocks; `build.sh` `*_SELFTEST`
  allow-list entries; `scripts/fp-*-smoke.sh` (QEMU + KVM for real SSE/`#UD`/`#NM`/
  `CR0.TS`, per the iam-verify precedent). Each asserts a grep-able line.
- Standing gates carried across the arc: `sweep.sh`, `agnsh-smoke`, `exec-smoke`,
  and the `objdump -d build/agnos | grep -c xmm == 0` FP-free audit.
- Final consumer gate: `naad-smoke.sh` (ring-3 oscillator → finite non-NaN
  samples) → the archaemenid iron burn.

---

*Design + adversarial verification: multi-agent workflow, 2026-07-04. B1 shipped +
adversarially re-verified + B2–B6 grounded-refined: multi-agent workflow,
2026-07-05. Gap measurements (26,647 XMM / 0 YMM in `naad --agnos`; hardened
`objdump` FP-free baseline; f64→`addsd`/`mulsd` codegen; ring-0 f64 QEMU 4/4) are
empirical.*
