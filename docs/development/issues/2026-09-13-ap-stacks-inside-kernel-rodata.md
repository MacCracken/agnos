# The AP boot/TSS stacks sit inside kernel .rodata since the embedded face — relocate them

**Status:** 🔴 **OPEN — layout invariant broken, tolerated at 1.57.2 by a gate, needs an operator decision.**
**Filed:** 2026-09-13, from the 1.57.2 review of the kernel-embedded default face (`core/kfont.cyr`).
**Affects:** every boot with `-smp >= 2` (the harness boots `-smp 4`; SMP iron). Not the served face,
which is the verified 2 MB direct-map copy and never the literals. Not `-smp 1` QEMU smokes, which
cannot see it at all.
**Severity:** **Medium and patient.** No observable misbehaviour in the current tree; 275 bytes of
margin, zero enforcement until this filing, and a bug class this tree has paid for twice on iron.

## What the review measured

`readelf` on the 1.57.2 `build/agnos` (plain kernel, rekha face embedded):

| thing | before 1.57.2 | at 1.57.2 |
|---|---|---|
| single `LOAD` end (`p_vaddr + p_memsz`) | ~0x2FA2xx | **0x35E770** |
| `.rodata` | ~0xE6xx bytes | 0x2DBBD0..0x34E769 (0x72B99 bytes) |
| rekha chunk literals (101 × 4096 B, stride 4097) | — | 0x2DBBEB..0x340113 |
| first live kernel literal above them (`"fb: mode="`) | — | 0x340114 |

The fixed kernel stacks in PMM region 1 were each placed by reading an image end off a build and
picking a number above it — and nothing has re-checked them since:

| stack | where set | address |
|---|---|---|
| AP1-3 boot stack (trampoline `add eax, 0x310000`) | `arch/x86_64/smp.cyr` | tops 0x320000 / 0x330000 / 0x340000 |
| AP1-3 TSS.RSP0 (`tss_get_cpu_stack`) | `arch/x86_64/gdt.cyr` | same three tops |
| BSP boot stack | `arch/x86_64/boot_shim.cyr` step 12 / ELF64 step 1 | top 0x380000 |
| BSP TSS.RSP0 (`tss_kernel_stack`) | `arch/x86_64/gdt.cyr` | top 0x3C0000 |

So **[0x310000, 0x340000) — all three AP windows — now lies inside `.rodata`, on rekha chunks
52..100.** The window is identity-mapped RW by the boot shim's 2 MB pages, `smp_start_aps` sees it
mapped and allocates nothing, and every AP write — the trampoline's `push 0x08` / `push rax` before
`lretq` (the first two land at 0x31FFF8 / 0x31FFF0 = chunk 68 + 969), `ap_entry`'s frames, the AP
idle's CPL0 timer frames, the initial RSP0 — goes into the loaded kernel image with no fault and no
signal. `smp_wake_enabled = 1`, so this happens on every boot that has an AP to wake.

The design's only fit check was "image+bss end under the 4 MB identity map" (`kfont.cyr`'s COST
paragraph as first written). That bound is true and irrelevant: it never looked at the stacks
inside the 3-4 MB window. The brief's *"if it does not fit, STOP and report"* condition was met and
did not fire because "fit" was checked against the wrong address.

## Why it is harmless today — and why that is an accident, not a design

1. The chunk literals are read **once**: `rekha_face_default_copy` from `kfont_init`
   (`main.cyr` ~line 436), ~5,500 lines before `smp_start_aps` (~line 5977). The face that `/fonts`
   serves is the verified copy in the 2 MB direct-map region. So AP frames scribbling on chunks
   52..100 after init change nothing anyone reads.
2. Stacks grow **down**, and the first live kernel byte above CPU3's stack top (0x340000) is at
   0x340114 — **0x113 = 275 bytes** of dead-chunk margin. A `.text`/`.bss` shrink over that (the
   closeout dead-code audit is exactly such an event), a regenerated face 275+ B smaller, or any
   literal re-ordering slides kernel `kprint` strings under CPU3's frames — corrupting boot lines
   on SMP iron only, silently, while every `-smp 1` gate stays green.

Neither reason was written down, gated, or even known until the review. Two other consumers of the
layout carried numbers that had been stale for many minors: `gdt.cyr`'s note quoting the image end
as 0x2334E8, and `boot_shim.cyr`'s "~1.4 MB of downward headroom" for the BSP boot stack (137 KB at
1.57.2).

## Precedent — this exact class, twice, on iron

- `gdt.cyr` `tss_kernel_stack` note: BSP RSP0 at 0x200000 sat ~210 KB inside live `.bss`; the first
  IF=1 ring-3 proc's timer tick corrupted the scheduler → triple fault → the 1.44.x "locks up right
  after the agnoshi banner" symptom. Fix: move to 0x3C0000, "above the image end (0x2334E8)".
- `boot_shim.cyr` step 12: the 0x200000 boot stack grew into `.rodata` and overwrote
  `"exfatu: upcase-checksum OK"`, caught only by a gdb watchpoint. Fix: move to 0x380000, "above the
  image top (~0x210000)".

Both fixes were "pick a higher number" with a comment quoting the image end of the day. This filing
is the third instance; the pattern is the finding.

## What 1.57.2 ships (the accommodation, not the fix)

- **`scripts/check/image-layout-check.sh`**, wired into `check.sh` as the gate *"kernel image vs
  fixed kernel stacks"* right after the binary-size gate, behind the same fossil-binary vacuity
  guard. It parses the ELF, and:
  - **hard-fails** a `LOAD` end above **0x370000** (the BSP boot stack keeps the same 64 KB budget
    every per-CPU window gets) — no exceptions, do not raise it;
  - passes cleanly when the end is ≤ 0x310000 (the real invariant);
  - otherwise — the 1.57.2 state — decodes the chunk literals from `face_data.cyr` itself, proves
    **every byte** of `[0x310000, min(0x340000, end))` is a chunk byte or a chunk NUL, prints the
    margin to the first live byte, and locks the single-reader chain (`rekha_face_default_copy` has
    one caller in `kernel/`; `rekha_face_default_chunk` one caller in the face module).
  - Mutation-tested on scratch copies: a flipped chunk byte in the face module, a byte patched under
    CPU1's stack top in the ELF, and `p_memsz` bumped past 0x370000 each FAIL with the named reason.
- ⛔ notes at the three placement sites (`gdt.cyr`, `boot_shim.cyr` ×2) and in `kfont.cyr`'s COST
  paragraph, with the measured numbers and the "do not add a reader of the chunks" rule.

## The decision this filing asks for

**Relocate the AP boot/TSS stacks (and, while there, derive the BSP boot stack from something) out
of `[0x100000, LOAD end)`.** The syscall kstacks already left this window for region 7
(`0xF10000 + cpu*0x10000`, `syscall_hw.cyr`); the same pool is the natural home for the three AP
windows, and `tss_get_cpu_stack` / the trampoline's `add eax, 0x310000` / `smp_start_aps`'s
`vmm_alloc_at` loop are the only three sites. Once that lands, the gate's tolerated-overlap branch
becomes dead and should be removed so the clean `end <= 0x310000` invariant is the only PASS.

Alternatives the operator may prefer instead:
- keep the windows and **raise them** to a derived address (e.g. `LOAD end` rounded up) — still a
  number chosen from a build, which is the pattern that produced this filing three times;
- accept the overlap indefinitely on the strength of the gate — the 275-byte margin makes that a bet
  on every future `.text`/`.bss` change.

## Not in this filing

- The BSP boot stack overflowing into the image: 137 KB of headroom, largest function-local array
  in `kernel/` is 4 KB. Real, but not near.
- Write-protecting kernel `.rodata` (the pages are 2 MB RW identity mappings). Would turn this class
  into a fault instead of silent corruption; a separate arc.
