# `sys_mmap`'s low arena advances a GLOBAL cursor unlocked — concurrent multi-page mmaps punch holes

**Status:** ✅ **RESOLVED — the race closed at 1.56.36, and a SECOND defect in the same function closed at 1.56.53.** Swept 2026-08-30. The unlocked read-modify-write is gone (whole-span claim under `mmap_spin_lock`). ⛔ The sweep then found the *rollback* was gated on VA arithmetic alone: a process that had never called `mmap` could rewind the global cursor past a span it never owned, then `mmap` twice and alias — leaking the first mapping's pages permanently, since `proc_map_page_nx` overwrites the PDE and the exit sweep only reclaims present+user entries. Now gated on `freed == npages`.

**Original status:** ✅ **FIXED — and this header was WRONG for four days.** Opened 2026-08-03, fixed the same
day, still labelled OPEN until an issue-rot audit on 2026-08-07 caught it. ⛔ A fixed defect still
marked OPEN is worse than an unfiled one: it is a standing invitation to re-investigate solved work,
and it makes every other OPEN label in the directory less trustworthy.

**The fix** (`kernel/core/proc.cyr:1682-1688`): `mmap_spin_lock()` now wraps the cursor read, the
ceiling check and the advance as **one critical section**, and the mapping loop writes into
`base_vaddr + i*2MB` — a span this caller already owns — instead of re-reading a global another CPU is
advancing. The whole span is claimed before the lock is released.

⛔ **It was not theoretical.** Iron-confirmed 2026-08-03: `fault: pid=7 cr2=0x1043c000 err=0x6 pde=0
idx=82` — a user WRITE inside this arena to a page that was never mapped. It cost the desktop its
second client on that burn.

**Repro (historical)** QEMU `-smp 4`, no hardware.

## The defect

`kernel/core/proc.cyr:1385` — `var mmap_next_vaddr = 0x10000000;` is a **single module-global shared by
every process**. `sys_mmap`'s low-arena path (`proc.cyr:1433-1445`) captures a base from it, then
read-modify-writes it inside the mapping loop **with no lock**:

```cyrius
if ((mmap_next_vaddr + len) <= 0x3FA00000) {
    var base_vaddr = mmap_next_vaddr;                 # captured ONCE, before the loop
    for (var i = 0; i < npages; i = i + 1) {
        var phys = pmm_alloc_2mb();
        proc_map_page_nx(cr3, mmap_next_vaddr, phys);
        mmap_next_vaddr = mmap_next_vaddr + 0x200000; # unlocked RMW on a GLOBAL
    }
    return base_vaddr;
}
```

There is no giant kernel lock to save it: `syscall_handler` (`arch/x86_64/syscall_hw.cyr:103`) and
`ksyscall` take none — only FS arms take `fs_spin_lock`. Two CPUs genuinely interleave here.

### Consequence, by page count

- **`npages == 1` — benign.** Both CPUs hand out base X into *different* CR3s; one cursor increment is
  lost. Wasteful, not fatal.
- **`npages > 1` — a HOLE.** CPU0 maps X, CPU1 advances the cursor and maps X+2M in *its own* address
  space, CPU0's second iteration then lands at X+4M. **Process A is returned `base=X, len=4M` while
  X+2M was never mapped in A's CR3.** First touch → `#PF` → `exit 142`.

⭐ **The identical hazard was already fixed one arena over.** The HIGH arena immediately below
(`proc.cyr:1447`) reserves from a **per-process** cursor — `himmap_reserve(proc_current_get(), len)`,
commented "from THIS process's own cursor (1.50.4)". The low arena kept the global.

## The trigger exists on the compositor's client path

`aethersafha/src/setu_dispatch.cyr:57-58` accepts `nbytes` up to **16 MB** and calls `alloc(nbytes)`,
which spills through `_agnos_new_chunk(asz)` → `sys_mmap(sz)` (`aethersafha/lib/alloc_agnos.cyr:41-46`)
with a multi-page size. Two clients allocating concurrently at `-smp 4` are the interleaver.

## ⚠ This is NOT the 2026-08-02 large-image fault

Scope it honestly. A cursor race produces a PDE **never written**; the large-image fault
(`2026-08-02-large-image-ptload-pde-absent-smp.md`) has a PDE that is **written, verified, then reads 0**.
They are different failure modes. Also decisive: the low arena begins at `0x10000000` (PD[128]) and the
observed faults are at **PD[510]** (`cr2=0x3fc02cb0`, the user stack) and **PD[9]** (`cr2=0x124f170`,
image data) — both far below the mmap arena. **This bug cannot produce those addresses.**

It is a real, separate SMP defect on the same code path, found while auditing whether userland was
calling the kernel incorrectly (it is not — see that audit's verdict).

## Fix

Kernel-side, and the shape is already in the file: either take a lock around the whole
capture-map-advance sequence, or — better, matching the high arena — **reserve the entire span
atomically before mapping any of it**, so the returned base and every page under it come from one
uninterrupted claim.

## Distinguishing probe

One `klug` record of `mmap_next_vaddr` at `sys_mmap` entry and exit, with `npages`, the caller pid and
the CPU. Interleaved entry/exit pairs from two CPUs with `npages > 1` confirm it directly. ⚠ Give the
probe a positive control before trusting a silent result — see the instrument-warning list in the
large-image issue, where five diagnostics were wrong before they were right.
