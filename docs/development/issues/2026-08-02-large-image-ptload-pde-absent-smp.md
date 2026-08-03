# The APs never enabled `EFER.NXE`, so every NX page was a reserved-bit `#PF` on an AP

*(Filed as "a large binary reaches ring 3 with one of its own PT_LOAD PDEs absent (SMP only)". The PDE
was never absent — see the root cause. Title kept in the body for searchability.)*

**Opened** 2026-08-02 · **RESOLVED 2026-08-03** · **Repro** QEMU `-smp 4`, no hardware needed

---

## ⭐ ROOT CAUSE — one line

`kernel/arch/x86_64/smp.cyr:514`, the AP trampoline's EFER write:

```
    or eax, 0x100      # LME only            <- BUG
    or eax, 0x900      # LME | NXE           <- FIX
```

The **BSP** sets `EFER |= 0x900` (LME | **NXE**) in `kernel/arch/x86_64/boot_shim.cyr:100`. The **APs**
set only `0x100` (LME). `EFER.NXE` (bit 11) is what makes bit 63 of a paging-structure entry mean
*no-execute*; **with NXE clear, bit 63 is a RESERVED bit.**

`proc_map_page_nx` stamps `0x8000000000000087` — bit 63 set — on **every W^X data page and every user
stack**. So the first time any AP touched an NX page, the CPU raised a **reserved-bit page fault**.

### Why every symptom followed

| symptom | explanation |
|---|---|
| `-smp 4` fails, `-smp 1` passes | only APs lack NXE; the BSP has it |
| Only the 15.6 MB image | more NX pages and a longer run ⇒ far likelier to be scheduled onto an AP |
| Victim index MOVED between runs (`0x1fe`, `5`, `3`) | whichever NX page the AP happened to touch first |
| **PD[2] never faulted** | code is mapped by `proc_map_page` — **no NX bit** — so the code page was always legal |
| PDE verified present at load, spawn, every CR3 install, every tick | it *was* present. The entry was always correct |
| Error code `0xc` / `0xe` | **bit 3 = RSVD** was set the whole time |

### ⛔ What hid it for a day — an instrument, again

`fmt_hex_buf` **emits zero characters for a value with bit 63 set.** The fault recorder printed
`pde=0x`, which was read as *"the PDE is zero"* when it actually meant *"the PDE has NX set and the
formatter cannot print it."* Every hypothesis in this document followed from that single misreading.

The error code had been reporting `RSVD` in bit 3 from the very first capture on 2026-08-02. Bits 0-2
were decoded; bit 3 was not. **The answer was in the first measurement.**

⚠ This is the same failure class as the four instrument warnings already listed below, and the third
distinct way `fmt_hex_buf` has produced a false reading on this issue. `epp_hex` and the fault recorder
now split bit 63 and print `NX|<rest>` explicitly.

### Verification

```
-smp 4 foreground : connected 2, presented 2, exit 95
-smp 4 repeat     : connected 2, presented 2, exit 95
-smp 4 background : connected 2, presented 2
-smp 1 regression : connected 2, presented 2, exit 95
```

### Landed alongside (keep)

- **TLB shootdown IPI** — `apic.cyr`: `tlb_shootdown_all()` (local CR3 reload → IPI all-but-self on
  vector 0xF0 → bounded ack spin), `tlb_isr_build()`, `tlb_shootdown_handler()`; vector installed in
  `main.cyr`; called from `proc_free_address_space`, `proc_unmap_page`, `proc_unmap_2mb_hi`. agnos had
  **zero** cross-CPU invalidation — a real latent hole under SMP with recycled address spaces. Verified
  running (`TLB_SHOOT_PROBE=1` → `TLBSHOOT want=3 ack=3 cpus=4 apic=1`). **Not** this bug, but correct.
- **`ELF_PDE_PROBE=1`** diagnostics: per-PDE write verification, live page-table registry checked by
  `pmm_alloc`/`pmm_alloc_2mb`, `pd_audit`/`pd_tripwire`, subject-controlled CR3-install and tick
  watches, and hardware CR3/CR2 capture stamped in the `#PF` stub itself.

---

## (original filing) A large binary reaches ring 3 with one of its own PT_LOAD PDEs absent (SMP only)

## ⭐ 2026-08-03 — THE MAPPING LANDS. SOMETHING UNDOES IT.

`ELF_PDE_PROBE` (build flag, `scripts/build.sh`) reads every PT_LOAD and stack PDE back **immediately
after** `elf_load_from_file` maps it, through the same `cr3 → PML4[0] → PDPT[0] → PD` walk, **and
through the PD[511]-stashed user PML4 as well**. Result:

| run | probe at map time | outcome |
|---|---|---|
| `-smp 1` | **21 MATCH, 0 MISMATCH** | passes, `exit 95`, 2 connected + presented |
| `-smp 4` | **18 MATCH, 0 MISMATCH** | `exit 142`; pid 6 and 7 fault at `idx=1fe` with `pde=0` |

**Every PDE is correct in BOTH tables when the loader writes it.** The entry the CPU later consults
reads 0. So of the two stories no fault address could separate:

- ~~(1) the PDE write never landed~~ — **ELIMINATED BY MEASUREMENT.**
- **(2) it landed and something undid it later — this is what is happening.**

That retires the whole "loader is wrong" class: header TOCTOU, bad `p_vaddr`, allocation failure,
wrong segment bounds. **The next question is solely: what clears PD[510] after load?**

⚠ **Both `-smp 4` victims were the USER STACK (`idx=1fe` = PD[510])**, not image data, on procs 6 and 7
simultaneously, each on its own CR3.

### ⭐ TWO ELF LOADS LAND IN ONE PD, WITH OVERLAPPING PHYSICAL PAGES

The probe's `pd=` field (the PD's physical page) shows the compositor performing **two** loads into the
**same** page directory, and the second reusing physical memory the first still maps:

```
pid=5  idx=0x2..0x9  (8 pages, 15 MB image)  pd=0xffd5000  ustash=0xffd7000   <- load A
       idx=0x4 want=0x1c00000                                                 <- A maps phys 0x1c00000
pid=5  idx=0x2..0x3  (2 pages)               pd=0xffd5000  ustash=0xffd7000   <- load B, SAME PD
       idx=0x1fe (stack) want=0x1c00000                                       <- B's STACK takes it
```

**`0x1c00000` is mapped twice inside one address space** — as image data at `va=0x800000` (load A,
idx 4) and as the user stack at `va=0x3fc00000` (load B). Load B writes only idx 2, 3 and 510; **A's
idx 4..9 are never cleared**, so the stale high mappings survive into B's address space. And
`ustash=0xffd7000` is precisely **pid 6's faulting CR3**.

⚠ **NOT YET ESTABLISHED that this causes the fault.** It is a real aliasing defect and the first
structural anomaly the probe has surfaced, but the causal chain to `PD[510] == 0` is not proven. Do
not write it up as the root cause until it is.

### ⛔ RETRACTED SAME DAY — "two loads cause the fault" is BACKWARDS

The section below was written from grouped-by-address-space counts, **before the events were put in
order**. Instrumenting `proc_create_user` / `proc_free_address_space` (`asalloc` / `asfree` records)
gives the actual sequence:

```
asalloc 0xffd7000 by=5
  load idx=0x2..0x9 + stack idx=0x1fe      <- LOAD A completes, 9 PDEs, ALL verified MATCH
FAULT pid=6 cr3=0xffd7000                  <- THE FAULT HAPPENS HERE
asfree  0xffd7000 by=5                     <- freed AFTER the fault (cleanup)
asalloc 0xffd7000 by=5                     <- same PML4 handed back (LIFO pmm)
  load idx=0x2,0x3 + stack                 <- LOAD B: the RETRY, a different program
```

**The second load and the physical aliasing are CONSEQUENCES of the fault, not causes.** They are the
shell retrying after the kill. The `0x1c00000` "alias" is simply the allocator reissuing a page whose
owner had already died. Counting occurrences per address space cannot see this; only ordering can.

⚠ **`0xffd7000` IS allocated twice — but with a free in between, and the free is post-fault.** The PMM
is behaving correctly. There is no double-allocation under a live occupant.

**What this leaves, and it is much sharper than before:** the stack PDE was written and **verified
correct at map time** (`idx=0x1fe -> phys 0x2800000`, MATCH on both reads), **nothing else loaded into
that address space**, and it reads **0** when pid 6 first touches the stack. The wipe happens between a
verified write and the first touch, with no competing loader.

### ⛔ REFUTED — the allocator does NOT reissue a live page-table page

A live-PT registry (`ptpage_live[128]`, registered in `proc_create_user` + `proc_map_page_hi`,
unregistered in `proc_free_address_space`) is consulted by **`pmm_alloc` on every 4 KB allocation**.
It prints `PTREISSUE` if it is about to hand out a page still serving as a live PML4/PDPT/PD.

**Result: zero PTREISSUE at `-smp 1` AND at `-smp 4`.**

⭐ **The null is calibrated** — `ptpage_selftest_once()` runs on first address-space creation and
prints `PTSELFTEST before=0 registered=1 after=0 PASS` on every boot, proving the registry and lookup
can actually fire. Without that, "no alarm" would be indistinguishable from "no detector". It is the
positive control this issue's instrument-warning list demands.

So `proc_create_user`'s `memset` and `proc_map_page_hi`'s 512-entry clear are **exonerated**: they only
ever zero pages the allocator legitimately owned. The PD page itself is not being recycled — **individual
PDEs are being cleared inside a live, correctly-owned page directory.**

⚠ The victim continues to move: `idx=0x1fe` (user stack) on one boot, **`idx=0x9`** (image data,
`cr2=0x124f170`, `rip=0x5d6008`) on the next. Same kernel, same binaries.

### ⛔ REFUTED — neither unmap function clears the victim, and the WALK is not diverging

`unmap_probe` now logs every PDE clear in both `proc_unmap_page` and `proc_unmap_2mb_hi`: the target
`cr3`, `virt`, resulting `pd_idx`, the entry's prior value, caller pid and CPU — and flags
`DESTROYED_LIVE` when a **present + user** entry is cleared.

**Result: every unmap at both `-smp 1` and `-smp 4` is the loader's guard unmap hitting an ALREADY-ABSENT
slot** — `tag=0 va=0x3fa00000 idx=0x1fd was=0x0 p=0 u=0`. **Zero `DESTROYED_LIVE` on either run.**
No live PDE is cleared by kernel code.

**And the page-table walk is not diverging.** `fault_kill_current` now logs the PML4 and PD pages its
walk lands on, for comparison with the PD the loader recorded writing into:

| proc | fault walked | probe wrote | same page? |
|---|---|---|---|
| pid 6 (`cr3=0xffd7000`) | `fpd=0xffd5000` | `pd=0xffd5000` | **yes** |
| pid 7 (`cr3=0xffd4000`) | `fpd=0xffd2000` | `pd=0xffd2000` | **yes** |

So `PML4[0]` and `PDPT[0]` are intact and both readers consult the identical physical PD.

### Where that leaves it — the entry is destroyed by something OUTSIDE the paging code

Established, each with a calibrated instrument:
1. The PDE is **written correctly** (45/45 MATCH at `-smp 4`, verified in the same table the fault reads).
2. The PD **page is not recycled** (`PTREISSUE` silent, `PTSELFTEST PASS` proves it can fire).
3. The PDE is **not cleared** by either unmap path (`DESTROYED_LIVE` = 0, probe demonstrably logs).
4. The **walk is correct** (fault-side PD == loader-side PD).

A correct entry, in the right page, that no paging code touched, reads 0. That points away from the
page-table logic entirely and toward **the PD page's memory being overwritten** — a stray write, a
buffer overrun, or DMA landing on it.

⚠ Note the addresses: page-table pages cluster at the **top** of the pool (`pmm_alloc` is deliberately
top-down: `0xffd7000` / `0xffd6000` / `0xffd5000` for one proc, `0xffd4000`… for the next), while
`pmm_alloc_2mb` fills low-to-high for user pages. `pmm.cyr` states the two classes "only meet if total
demand exhausts the pool." **A 15 MB image plus two clients is the largest demand this system has ever
placed on it** — worth testing whether they now meet.

### ⛔⛔ THE TRIPWIRE NEVER WATCHED THE FAULTING PROC — every conclusion resting on it is VOID

`pd_tripwire` was made to log the PD it actually watches, a bounded number of times. Result:

```
PDWATCH as=0xffda000 pd=0xffd8000 pd510=0xa00000 p=1      <- the ONLY address space it ever saw
fault:  cr3=0xffd7000 fpd=0xffd5000 n510=0x0 idx=1fe      <- the one that dies
```

**It only ever ran for `0xffda000`. The faulting address space `0xffd7000` was never observed.** So
"PD[510] is present at every scheduler dispatch" was measured on a *different proc*, and the silence
that made this fault look impossible — correct tables, correct CR3, nothing writing, yet not-present —
was an artifact of an instrument pointed at the wrong target.

⛔ **RETRACTED as a consequence:** "the page tables are correct at every dispatch", and the
stray-write / overrun theory built on top of it (the "victim moves = different offsets in one page"
reasoning). Neither is supported. The `pd_audit` tag-1/tag-2 results still stand — those are keyed to
the load and spawn of the proc being built — but nothing establishes the PD's state once the faulting
proc is running.

⭐ **And this is the lead.** `do_context_switch` was reached only a handful of times, never for the
faulting proc — so **that proc does not reach ring 3 through the scheduler dispatch path**. It is
entered some other way (the `spawn_path` / `kernel_resume` / direct-entry family), which means its CR3
install and its first ring-3 transition have been **outside every instrument built for this issue**.

**A chokepoint watch was added at `cr3_load()`** (`proc.cyr`) — the single function every CR3 install
passes through, whichever path reached it. It logs when the space being installed has PD[510] absent.
Result: **one hit, `CR3BAD as=0x7fc01000 pd=0x0 pd2=0x0 by=0 cpu=0`** — an address that is none of the
proc CR3s and whose PML4[0] resolves to zero, seen once on CPU 0. Not the faulting space.

⚠ **Do not read that as "the install is healthy" — it has the SAME defect as the tripwire.** It only
logs on the bad case, so it does not establish that `cr3_load` was ever called with `0xffd7000` at all.
Before trusting it, make it log the *subject* (every install of the faulting CR3, bounded), not just
the anomaly. That is the check that was missing all day.

⚠ Also worth chasing on its own: **what is `0x7fc01000`, and why is a CR3 with an empty PML4[0] being
installed?** It may be benign (a boot/transition CR3 the guard's `0x1000` exemption does not cover) or
it may be a second defect. It was not investigated.

**Next: instrument the OTHER ring-3 entry paths**, not the scheduler. Find every site that loads CR3 or
performs an `iretq`/`sysretq` to ring 3, log the proc and CR3 at each, and confirm which one carries
`0xffd7000`. The fault is on that path.

⚠ The generalisable lesson, and it cost most of a day: **an instrument that never fires must be proven
to have observed the thing it was watching for.** `PTSELFTEST` proved the *mechanism* could fire; it
did not prove the *subject* was ever in scope. Those are different checks and only the second one
matters for a silent result.

### SUBJECT-CONTROLLED MEASUREMENTS (2026-08-03, late) — the ones that are admissible

Both probes below log the SUBJECT (the faulting space `0xffd7000`), present-or-absent, so their output
proves the path ran for it. That is the check every earlier silent instrument lacked.

**1. `cr3_install_watch` at `cr3_load()` — the universal CR3 chokepoint:**
```
CR3INST as=0xffd7000 pd510p=1 by=6 cpu=0
CR3INST as=0xffd7000 pd510p=1 by=6 cpu=3      <- the proc MIGRATES CPU 0 -> CPU 3 -> CPU 0
CR3INST as=0xffd7000 pd510p=1 by=6 cpu=0
```
**PD[510] is present at every CR3 install, on every CPU.** The proc migrates across CPUs — worth noting,
but each install sees a healthy stack PDE.

**2. `pd510_tick_watch` in `timer_handler` — samples the current proc's own PD[510] at 100 Hz:**
```
PD510 p=1 after_ticks=1 pd=0xffd5000 by=6 cpu=0
```
Present at the first tick, and **`after_ticks=1` means the proc never survives to a second tick** — it
dies inside ~10 ms of starting. The PD is `0xffd5000`, matching the loader and the fault handler.

**So: present at load, present at spawn, present at every CR3 install, present at the only timer tick
it lives to see — and absent when ring 3 touches it, within 10 ms, on a correct hardware CR3, with the
TLBs provably shot down.**

⚠ **What has NOT been measured:** the PDE's VALUE at those checkpoints — only its present bit. If the
entry is present but points at a wrong or freed physical frame, every "p=1" above is consistent with a
fault. **Log the full 64-bit PDE, not the present bit.** That is the next measurement and it is one
edit to the two probes above.

⚠ **Cyrius trap that cost a run here:** `pd510_tick_watch` was defined OUTSIDE the `#ifdef
ELF_PDE_PROBE` block while its no-op shim sat later in the file. Cyrius **silently shadows duplicate
fns, last definition wins** — so the no-op won and the probe printed nothing. A silent probe was, once
again, not evidence. See `reference_cyrius_duplicate_fn_shadow`.

### ⭐ HARDWARE TRUTH — the CPU's own CR3 is CORRECT at fault time

The `#PF` stub now stamps the CPU's own `CR3` and `CR2` to memory (`pf_hw_cr3` / `pf_hw_cr2`) in the
first instructions after the trap — `mov rax,cr3` + `mov [moffs64],rax` — **before any kernel code
runs**. Every earlier probe read CR3 via `proc_get_cr3()` / `dm_read_cr3()` from Cyrius executing
DOWNSTREAM of the handler, so a CR3 that was wrong at fault time and corrected on the way here would
have been invisible. It is not:

```
fault: pid=6 cr2=0x3fc02fb0 err=0xe rip=0x5cd30c cr3=0xffd7000 own=0xffd7000
       HWCR3=0xffd7000 HWCR2=0x3fc02fb0
       fpd=0xffd5000 n2=0x18000a7 n509=0x0 n510=0x0 stash=0xffd7000 idx=1fe
```

**`HWCR3 == own == cr3`.** The proc is genuinely on its own address space; this is not a CR3-install or
scheduling-CR3 bug. `HWCR2` matches too, so the address is real.

### Where it actually stands

| fact | instrument |
|---|---|
| PD[510] **present** at end of load, at spawn, and at **every scheduler dispatch** | `pd_audit` tag 1/2, `pd_tripwire` tag 3 (never fires) |
| PD[510] **zero** when the proc touches it | `n510=0x0` in the fault dump |
| Hardware CR3 correct at fault | `HWCR3` stamped in the stub |
| Nothing clears a PDE | `unmap_probe`, 0 `DESTROYED_LIVE` |
| No allocator reuse of a live PT page | `PTREISSUE` / `PTREISSUE2M`, `PTSELFTEST PASS` |
| TLBs coherent across all 4 CPUs | `TLBSHOOT want=3 ack=3` |
| All three guard unmaps target idx `0x1FD`, never `0x1FE` | `stack_base = 0x3FC00000` at `elf.cyr:145`, `:345`, `ring3.cyr:271` |

**So PD[510] goes from present to zero while the proc runs, on a correct CR3, with no instrumented
writer touching it.** The victim moves between runs (`0x1fe`, `5`, `3`) — different *offsets within the
same page*, which is the signature of a **stray write into the PD page**, not of paging logic.

⚠ The PD sits at `0xffd5000` — the top of the pool, where `pmm_alloc` deliberately clusters 4 KB
allocations (page tables, DMA rings, and whatever else takes 4 KB pages). **The next probe is a
write-watch on the PD page**: stamp a canary into unused PD slots at creation and check them from the
tripwire on every dispatch, which brackets the corruption to a scheduling quantum and tells you whether
neighbouring slots die together (a run of bytes = an overrun) or independently (a targeted write).
⛔ Do NOT assume paging code again — seven hypotheses of that shape are already dead.

### ⛔ REFUTED — TLB shootdown implemented, VERIFIED WORKING, and the fault survives it

The stale-TLB reading below was wrong. It is retracted, and the retraction is the honest kind: the fix
it predicted was built, proven to run, and changed nothing.

**agnos genuinely had NO cross-CPU TLB invalidation** — that part stands. `grep` for
`shootdown|tlb_flush_ipi|invlpg_ipi|remote_invlpg|tlb_ipi` across `kernel/` returned nothing, and all
five `invlpg_va()` sites flush only the executing CPU. So a shootdown was implemented (2026-08-03):

- `apic.cyr` — `tlb_shootdown_all()` (local CR3 reload → IPI all-but-self on vector **0xF0** → spin for
  acks, bounded by `TLB_SHOOT_WAIT` so a wedged CPU degrades to stale-TLB risk rather than hanging),
  `apic_send_ipi_allbutself()`, `tlb_isr_build()` (timer_isr_build's shape, caller-saved only),
  `tlb_shootdown_handler()` (CR3 reload, ack, EOI).
- `main.cyr` — vector 0xF0 installed at boot.
- Called from `proc_free_address_space` (before pages return to the allocator), `proc_unmap_page`
  (only when a user PDE was actually cleared) and `proc_unmap_2mb_hi`.

⭐ **It demonstrably works** (`TLB_SHOOT_PROBE=1`): `TLBSHOOT want=3 ack=3 cpus=4 apic=1 spins=0x130b`
— every one of the other three CPUs acknowledges, every time.

**And `-smp 4` still fails with `exit 142`.** `-smp 1` still passes. **Stale TLB is not the cause.**

⚠ Keep the shootdown regardless. A kernel with SMP, recycled address spaces and zero cross-CPU
invalidation is incorrect on its own terms; this was a real latent bug, just not *this* bug. It is
cheap (rare path, bounded wait) and inert single-core (`cpu_count < 2` short-circuits to a local flush).

### (superseded) THE PAGE TABLES ARE CORRECT. THE CPU IS NOT SEEING THEM.

Three instruments, each calibrated, now agree:

- **`pd_audit` tag 1** (end of `elf_load_from_file`) — `nuser=9 lo16=0x3fc pd510=0x2800000`. Bits 2..9
  exactly, stack present.
- **`pd_audit` tag 2** (`sys_spawn_path`, immediately before `proc_set_state(pid,1)`) — **identical**:
  `nuser=9 pd510=0x2800000`. The address space is complete at the moment it becomes schedulable.
- **`pd_tripwire` tag 3** (every scheduler dispatch, silent unless PD[510] is absent) — **NEVER FIRES.**
  PD[510] is present on every single dispatch, on every CPU, for the whole run.

And yet the proc is fault-killed with a not-present `#PF`, **and the victim index moves between
otherwise-identical runs: `idx=3`, `idx=5`, `idx=0x1fe`.**

⚠ **This reframes the bug.** Every hypothesis so far assumed a PDE goes missing. It does not. The tables
are correct and complete at load, at spawn, and at every dispatch. What varies is *which* address the
CPU refuses — which is the signature of **stale translation, not a missing translation**: a TLB entry
cached on another CPU from a previous occupant of that CR3 value, never shot down when the address
space was rebuilt. `asfree` → `asalloc` handing back the **same PML4** (confirmed, LIFO `pmm_alloc`) is
exactly the condition that makes a CR3 value ambiguous across CPUs without PCID.

**Next probe:** log `invlpg` / CR3-reload activity around address-space teardown and reuse, and check
whether any TLB shootdown exists at all for a PML4 being recycled while other CPUs may hold entries for
it. `proc_map_page_nx` calls `invlpg_va(virt)` on the mapping CPU only — there is no cross-CPU IPI
shootdown in this kernel. That is very likely the whole bug.

⚠ The earlier "selectively zero entries" reading below is **an artifact of reading the PD after the
fault handler had already begun teardown**, not a live state. Treat the tripwire result above as
authoritative: nothing clears a PDE.

### (superseded) THE PD PAGE IS NOT WIPED — INDIVIDUAL ENTRIES ARE SELECTIVELY ZERO

`fault_kill_current` now dumps neighbouring PDEs alongside the victim, which separates "one entry
cleared" from "the page's memory destroyed" — indistinguishable from a `pde=0` alone:

```
fault: pid=6 cr2=0xace358 rip=0x5d8a3e cr3=0xffd7000 own=0xffd7000
       fpml4=0xffd6000 fpd=0xffd5000
       n2=0x18000a7      <- PD[2]   INTACT (phys 0x1800000 | flags 0xa7)
       n509=0x0          <- PD[509] guard, correctly absent
       n510=0x0          <- PD[510] stack GONE
       stash=0xffd7000   <- PD[511] user-PML4 stash INTACT
       idx=5             <- victim this run is PD[5]
```

**PD[2] and the PD[511] stash survive.** So the page was not overwritten wholesale — no stray write, no
DMA, no memory corruption of the PD. **Individual entries are selectively zero** while their neighbours
in the same page are valid.

⚠ **And that contradicts the unmap probe, which logged ZERO PDE clears on this same run.** Both
instruments are calibrated (`unmap_probe` demonstrably logs; the guard unmaps appear correctly as
`was=0x0 p=0 u=0`). So entries are becoming zero **without passing through either function that clears a
PDE.**

Exactly one of these must be true, and they are cheaply separable:
1. **A third writer touches PDEs** that neither `proc_unmap_page` nor `proc_unmap_2mb_hi` covers — some
   path doing a raw `store64` into a PD. Grep every `store64(` whose target could be a PD address, not
   just the ones reached via the two unmap helpers.
2. **The entries were never written for THIS incarnation.** The probe verifies each write, but if the
   address space is rebuilt (`asfree` → `asalloc` reusing the same PML4, which is confirmed to happen)
   the *new* occupant only maps what its own smaller load needs — idx 2, 3, 510 — leaving idx 4..9 zero
   from `proc_create_user`'s `memset`. A proc still executing the OLD image would then fault at idx 5.
   **This fits every observation**, including why the victim moves and why PD[2] survives (both loads
   map it identically, to `0x1800000`).

⚠ Hypothesis 2 makes a sharp, falsifiable prediction: **the faulting proc is running an image that no
longer matches its own address space.** Test it by logging, at fault time, how many PDEs in the victim's
PD are present, and comparing against the number the LAST load into that PML4 wrote. Old-image-still-
running gives a small count with a live `rip` pointing above it — which is what `rip=0x5d8a3e` (≈6.1 MB,
inside idx 2) against a nearly-empty PD already hints at.

**Superseded next probe** (kept: the wholesale-overwrite question it was written to answer is now
ANSWERED — the page is intact): write a known sentinel into every PD immediately after `proc_create_user` fills it, and
re-check the sentinel at fault time. If the sentinel is also gone, the page is being overwritten
wholesale (stray write / DMA) rather than having one entry cleared — which are very different bugs.
Also log `pmm_alloc_top` and the highest 2 MB allocation to see whether the two allocation classes have
started to overlap.

### (superseded) Next probe — the two functions that CLEAR a PDE

Only two places zero a page-directory entry in a live address space:

- **`proc_unmap_page(cr3, virt)`** — `proc.cyr:1324`, `store64(pd_addr + pd_idx * 8, 0)`
- **`proc_unmap_2mb_hi(cr3, virt)`** — `proc.cyr:1209`, same

Everything measured is consistent with one of these running with a **wrong `cr3` or wrong `virt`** under
SMP: the write lands, the page is legitimately owned, no allocator involvement, and the victim index
moves with timing. Instrument both to record `cr3`, `virt`, the resulting `pd_idx`, the caller pid and
the CPU — then check whether any clear targets an address space or an index its caller does not own.
⚠ Apply the same discipline: give the new probe a positive control before believing a silent result.

Remaining candidates, in order of cheapness to test:
1. **A live PD page reclaimed and zeroed.** Both `proc_create_user` (`memset(new_pd, 0, 4096)`) and
   `proc_map_page_hi` (a 512-entry zero loop on a fresh `pmm_alloc`) will wipe a page the allocator
   hands them. Both are correct **iff** `pmm_alloc` never returns a live page — so the test is whether
   any page is freed while still referenced. Instrument `pmm_alloc` to record every page it issues and
   cross-check against live PD/PDPT/PML4 addresses.
2. **A missing TLB shootdown** on a PML4 reissued to a new occupant while another CPU still caches the
   old mappings. Note this predicts a WRONG-page access, not a not-present fault, so it is a weaker fit.
3. `sys_munmap` / arena teardown clearing a PDE outside the mmap range.

---

### (superseded — kept for the record) ATTRIBUTED — TWO LOADS TARGET PID 6's ADDRESS SPACE

No rebuild was needed to attribute them: **`ustash` IS the target proc's CR3** (PD[511] stashes the
proc's own PML4, `proc.cyr:611`), and `fault_kill_current` prints `cr3=` for the victim. Grouping every
probe line by `ustash` over one `-smp 4` boot:

| target CR3 | loads | evidence |
|---|---|---|
| `0xffda000` | **1** | idx 2, 3, 510 — one clean load |
| **`0xffd7000`** | **2** | idx 2,3 written **twice**; idx 4..9 from A only; **idx 510 written twice** |

`0xffd7000` is **pid 6's faulting CR3**. Inside that one address space:

```
load A   idx=0x2..0x9   (8 pages)      idx=0x4   -> phys 0x1c00000
                        stack idx=0x1fe -> phys 0x2800000
load B   idx=0x2..0x3   (2 pages)
                        stack idx=0x1fe -> phys 0x1c00000     <-- A's idx=4 page
```

**PD[510] is written twice with two different physical pages, and `0x1c00000` is mapped twice at once
— as image data at `va=0x800000` and as the user stack at `va=0x3fc00000`.** Load B also leaves A's
idx 4..9 in place, so a second program inherits the first's high mappings.

This is a **shared / doubly-loaded address space**, not a lost PDE write — consistent with everything
measured: the writes all land (0 MISMATCH), the entry is later wrong, the victim slot moves, and it
needs more than one CPU because two children only interleave destructively when they run concurrently.

**The correlation is exact within a boot.** Every distinct address space the probe saw, against every
distinct faulting CR3:

| target address space | ELF loads | faults? |
|---|---|---|
| `0xffda000` | 1 | no |
| `0xffd7000` | **2** | **yes** |

The only doubly-loaded address space is the only one that faults. One boot is not causation, but no
singly-loaded address space has faulted.

**Both live call sites allocate a fresh CR3** via `proc_create_user` inside `elf_load_from_file`:
`#37 execwait` (`syscall.cyr:7136`) and `#43 spawn_path` (`syscall.cyr:7682`). One PML4 serving two
loads therefore means either the first was freed and immediately re-allocated (LIFO `pmm_alloc`) while
its occupant still ran, or the two handlers collided over per-CPU staging. ⚠ Note `vfs.cyr:706`:
`elf_load_from_file` is `vfs_read_file_at`'s sole caller and **does not hold `fs_lock`** under
`smp_sched_aps=1` — an already-documented unlocked concurrency surface on this exact path.

⚠ Still to prove: the exact step that leaves `PD[510] == 0` rather than merely aliased. The likely
chain is that one occupant's teardown (`proc_free_address_space`, which frees every present+USER 2 MB
page across PD[1..511]) reclaims pages the other occupant is still running on — but that is the
hypothesis to test next, not a result.

**The question this replaces:** it is no longer "what zeroes a PDE?" but **"why do two `elf_load_from_file`
calls target one address space?"** Look at `spawn_path #43`'s proc/CR3 allocation when the compositor
launches its two clients — whether a slot or a PML4 is handed out twice while the first occupant lives.

### Superseded next-probe note — the probe logs the loader's pid (attribution solved another way)

`elf_pde_probe` records `proc_current_get()`, which is the **loader's** pid, not the proc whose tables
are being written. That is why **no probe line exists for pid 6 or 7** — the faulting procs — while
every line says `pid=5`. Resolve the target pid from `new_cr3` (match it against each slot's
`proc_get_cr3`) and log that instead, so a load can be attributed to the proc that later faults. Until
then, "two loads into one PD" cannot be tied to a specific victim.

### Also eliminated by source review the same day (no runs spent)

- **PMM double-allocation under SMP** — `pmm_alloc`, `pmm_free`, `pmm_alloc_2mb`, `pmm_alloc_2mb_run`
  and `pmm_free_2mb` all hold `pmm_spin_lock` across scan-and-claim.
- **Reap frees an address space still in use** — `proc_reap_off_cpu_fence` is present and correctly
  ordered on **both** `proc_reap` and `proc_reap_child`: `proc_set_state(pid,0)` → detach CR3 → fence
  → `proc_free_address_space`.
- **ELF header TOCTOU between two CPUs** — already fixed at 1.46.8; `pcpu_elf_hdr_buf` is per-CPU and
  its sizing is correct (`var[2048]` = 2048×u64 = 4 CPUs × 4096 B, matching `pcpu_cpu() * 4096`).

### ⛔ Instrument note — this probe was wrong once before it was right (make it five)

The first version walked only the **kernel-view** PD (the `new_cr3` handed to `proc_map_page_nx`),
while `fault_kill_current` walks `dm_read_cr3()` — the **live** CR3, which for a ring-3 fault is the
**user** PML4 from the PD[511] stash. **Two different tables.** It reported "63 MATCH" against a
`pde=0` fault, which reads as a proven "landed then undone" and is nothing of the sort — the two
readings were not about the same memory. `proc_map_page_nx` mirrors into the user PML4 **only if the
stash is non-zero**, so "kernel PD fine, user PD empty" was a live possibility the probe could not
see. Now it reads both and its verdict names which table is wrong (`KPD_BAD` / `UPD_BAD` / `NOSTASH`).
**Checking one table and concluding about the other** is the fifth way a diagnostic has been wrong on
this fault. Validate against the `-smp 1` boot that passes before believing anything it says.

## Symptom

`run /bin/aethersafha` (15.6 MB) is fault-killed — `run: exit 142` (128 + vector 14, `#PF`) — after it has
printed its startup and bound its setu listener, at or just after the nested `sys_spawn_path` that launches
its first client. First seen on archaemenid; **reproduces in QEMU under `-smp 4`** and passes under `-smp 1`.

⭐ **`-smp 4` is not an approximation of the iron.** `smp.cyr:398` parks every AP with APIC id ≥ 4
(`if (my_id >= 4) { while (1 == 1) { hlt } }`), so a 5800H (8c/16t) runs exactly 4 CPUs and reports
`cpus online: 4`. The per-CPU arrays are all `[4]`; nothing overflows at higher core counts.

## Measured

`fault_kill_current` now records to the klug ring (read with `run /bin/klug`):

```
fault: pid=6 vec=e cr2=0x615828 err=0xe rip=0x5d1bc5 cr3=0xffd7000 own=0xffd7000 pde=0 idx=3
fault: pid=6 vec=e cr2=0x3fc02cb0 err=0xc rip=0x4019f2 cr3=0xffd7000 own=0xffd7000 pde=0 idx=1fe
```

- **The page is ABSENT, not refused** — error-code bit 0 = 0. Not W^X, not NX, not a US violation.
- **The proc is on its OWN address space** — live CR3 == the pid's recorded CR3. Not a context-switch defect.
- **The PDE for the faulting address reads 0**, via a walk that mirrors `proc_map_page_nx`'s exactly.
- **The victim slot MOVES between runs**: `idx=3` (image data, 6-8 MB) and `idx=1fe` = 510 (the user stack).
  RIP is always early in the image. A moving victim is why it needs more than one CPU to appear.

## Eliminated by measurement — do not re-derive

- **Permissions / NX / W^X** — error bit 0 = 0 (absent, not a protection violation).
- **Scheduler CR3 mix-up** — `cr3 == own` on every captured fault. The tempting story (a small child's CR3
  maps PD[2] where the parent executes but lacks the parent's higher slots) is ruled out.
- **PMM double-allocation under SMP** — `pmm_alloc_2mb` holds `pmm_spin_lock` across scan-and-claim.
- **The syscall-kstack restore bug** (fixed same day, `syscall.cyr` step (h) using the raw identity VA
  instead of its direct-map alias). Real, controlled, and **not this fault**: with agnoshi's foreground now
  routed through `spawn_path`, `execwait #37` never runs in these boots, so that path is not even exercised.

## The structural suspicion (unproven)

`proc_create` builds every address space as: PD[0..7] kernel identity (0-16 MB, incl. the syscall kstacks at
`0xF10000`-`0xFD0000`), PD[8..127] identity-**SUPERVISOR** (16-256 MB, so `sys_mmap` can `memset` a fresh
region by its physical address), PD[128..510] zero (the mmap arena), PD[510] the user stack.

User images load at **`0x400000`** and `elf_load`'s only ceiling is `p_vaddr + p_memsz > 0x10000000` — **256 MB**.
So a large image may map PD[8]+ as USER pages, replacing the kernel's identity-supervisor mapping *inside that
proc's CR3*. **This exact hazard was already fixed once for STACKS** (`elf.cyr:133`, 1.44.x — stacks used to be
striped at `0x800000 + pid*0x400000`, landing pid ≥ 2 above 16 MB and "overwriting the identity-SUPERVISOR map
of the pmm pool with a USER mapping"). Stacks were pinned to `0x3FC00000` to escape it; **images were not.**

⚠ **This does not yet explain the observed fault.** A 15.6 MB image at 4 MB reaches PD[9], but the captured
failures are at PD[3] (6-8 MB) and PD[510] — both *below* the fixtures. Recorded as the strongest structural
lead, not as the diagnosis. The RAM ceiling was lifted (direct map at 8 GB+, 2 MB pool spanning 62 GB,
`pmm_kva_for_access` above 256 MB) while this per-process layout was never revisited.

## Next probe

Instrument the **PT_LOAD mapping loop** of `elf_load_from_file` (the `#43 spawn_path` path — NOT `elf_load`,
the in-memory `#3` path, which is what the first attempt wrongly probed), reading each PDE back immediately
after `proc_map_page` / `proc_map_page_nx` through the same cr3 → PML4[0] → PDPT[0] → PD walk. That separates
"the write never landed" from "it landed and was undone later", which no address can.

## ⛔ Instrument warnings — four diagnostics were wrong before they were right (2026-08-02)

1. **An arming step that armed nothing.** The repro types a small foreground program first, because a
   *completed* `execwait` was what poisoned the next large binary. Routing agnoshi's foreground through
   `spawn_path` made `execwait` unreachable, so the arming step silently became a no-op — while still being
   reported as the test's premise.
2. **`fmt_hex_buf` emits ZERO characters for a zero value**, so `pde=0x` read as a *missing field* rather
   than a zero one. Guard every hex print of a possibly-zero value.
3. **The harness parsed `run: exit N` with `startswith`.** agnos interleaves output from several procs with
   no locking, so the code lands mid-line (`a11y nodes synced:run: exit 142`) and was missed — the verdict
   read `None` and the klug dump was skipped on a boot that had produced the evidence. Now a regex search.
4. **A page-table read-back with one `load64` too many** (it read the *contents* of PD[0] and used that as a
   table base) reported `stackpde=0` for **every** proc, including procs that boot and run fine — which is
   impossible, and is what exposed the probe rather than the kernel as the broken party.

⭐ The general rule this cost four readings to learn: **a diagnostic must be provable against a known
answer before its output is trusted.** The fault recorder was validated against `fault_disk_selftest`, which
faults at a *known* 5 GB address, and reported `cr2=0x140000000` exactly — that is why its output is trusted
and the probes above are not.

## Repro

```sh
AE_CLIENTS_SMP=4 AE_CLIENTS_MODE=fg python3 scripts/harness/aethersafha-clients-test.py
grep -a "fault: pid=" build/ae-clients/serial.log
```

Passes at `AE_CLIENTS_SMP=1` (2 clients connect and present), fails at 4. Same kernel, same binaries.
