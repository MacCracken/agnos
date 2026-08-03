# A large binary reaches ring 3 with one of its own PT_LOAD PDEs absent (SMP only)

**Opened** 2026-08-02 · **Status** OPEN — root cause not established, but **the field is halved** · **Repro** QEMU, no hardware needed

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
