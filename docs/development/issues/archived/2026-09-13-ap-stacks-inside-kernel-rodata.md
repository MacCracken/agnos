# The AP boot/TSS stacks sit inside kernel .rodata since the embedded face — relocate them

**Status:** ✅ **RESOLVED 1.57.3 (2026-09-13) — AP1-3 boot/TSS stacks relocated to region 7 (direct-map
tops `DIRECTMAP_BASE + 0xFD0000 + cpu*0x10000`); the image gate reduced to `LOAD end <= 0x370000`; runtime
guard `scripts/smoke/ap-stack-smoke.sh`, mutation-proven (OUT OF WINDOW ×3 + CORRUPTED on the 1.57.2
placement; `rsp0 NOT the region-7 top` ×3 on a gdt.cyr-only revert). See § Resolution at the end.**
**Filed:** 2026-09-13, from the 1.57.2 review of the kernel-embedded default face (`core/kfont.cyr`).
**Operator decision:** 2026-09-13 — relocate into the region-7 kstack pool (the first alternative below).
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

## What 1.57.2 shipped (the accommodation, not the fix — HISTORICAL, the branch described here is gone)

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

## The decision this filing asked for (taken 2026-09-13: the first option)

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

## Resolution (1.57.3, 2026-09-13)

**What moved.** The three AP windows left region 1 for the last 256 KB of the region-7 kstack pool
(phys `0xE00000–0x1000000`, PD[7], pmm-reserved by `pmm_init`): AP *n* (1..3) owns
`[0xFC0000 + n*0x10000, +0x10000)`, top `0xFD0000 + n*0x10000` = `0xFE0000 / 0xFF0000 / 0x1000000`.
Slot 0 `[0xFC0000, 0xFD0000)` is unused — the BSP keeps its region-1 boot stack (top `0x380000`) and
RSP0 (`0x3C0000`). **Region 7 is now FULL** (16 + 4 + 4 + 4 + 4 × 64 KB); `gdt.cyr`'s IST1 note carries the
five-consumer map. Both halves hand the AP the *same* VA, as before:

| site | 1.57.2 | 1.57.3 |
|---|---|---|
| `smp.cyr` trampoline, 64-bit section | `add eax, 0x310000` → `mov rsp, rax` | `add eax, 0xFD0000` (`05 00 00 FD 00`); `mov rcx, imm64 DIRECTMAP_BASE` (`48 B9` + the variable's live value, not a literal); `add rax, rcx` (`48 01 C8`); `mov rsp, rax` — section **92 → 105 B** (+13; its comment had read "77" since the 1.46.x lretq block's +15 went uncounted — re-derived and tallied twice), ends 0x8129, 87 B under the GDT16 pointer at 0x8180; `cs_off` is captured after the new bytes so the lretq target is unmoved |
| `gdt.cyr` `tss_get_cpu_stack(cpu)` | `0x300000 + cpu*0x10000 + 0x10000` | `DIRECTMAP_BASE + 0xFD0000 + cpu*0x10000` |
| `smp.cyr` `smp_start_aps` | `vmm_alloc_at` loop over the region-1 windows | no allocation; refuses INIT-SIPI unless PD@0x3000[7] (identity) **and** PDPT@0x2000[8] (the direct map the push actually walks) are present |

**Why the direct-map VA and never the identity VA.** Region 7's identity VA (14–16 MB) is inside the
user-segment range; a large binary (ark, segments to ~20 MB) overrides PD[7] in its per-proc CR3, and an
AP idle's stack outlives the boot CR3 (the scheduler resumes it under whatever CR3 is live). Same rule as
the syscall kstacks (`syscall_hw.cyr`) and IST1 (`gdt.cyr`).

**Why the BSP boot stack stays in region 1.** It is live from the shim's first instruction under gnoboot's
CR3, before any kernel page table — and so before the direct map — exists; region 1 (PD[1]) is the one
window every CR3 from power-on onward maps. (Not "the boot shim maps only 0–4 MB": that is the legacy
multiboot1 shim's step 4; the production ELF64 shim builds no page tables.) So the single remaining image
invariant is **`LOAD end <= 0x370000`**, that stack's 64 KB budget.

**What changed in the gate.** `scripts/check/image-layout-check.sh` (check.sh gate 34, relabelled
*"kernel image vs BSP boot stack (LOAD end <= 0x370000)"*) lost its tolerated-overlap branch — no chunk
decoding, no single-reader lock — and is now one number: PASS iff `LOAD end <= 0x370000`, printing the
headroom (0x11750 = 71,504 B at 1.57.3: LOAD end 0x35E770 → **0x35E8B0**, `build/agnos` 2,418,896 →
2,419,216 B — the code that emits the 13 new trampoline bytes, the two-alias guard and its 48-byte
literal; the trampoline itself is built at runtime into 0x8000 and weighs nothing in the image). Mutation: `p_memsz` →
0x370001 FAILs, 0x370000 exactly PASSes with headroom 0. The gate is deliberately about the IMAGE only —
no hex grep of the trampoline; where the stacks ARE is the runtime guard's job. The
"do not add a reader of `rekha_face_default_chunk`" rule is **retired**: the literals are ordinary `.rodata`.

**Runtime guard.** `SMP_STACK_SELFTEST` (`scripts/build.sh` define) + `scripts/smoke/ap-stack-smoke.sh`
(sweep.sh row *"1.57.3 AP stacks in region 7"*, `-smp 4`): after the wake and 5 ticks, per online AP it
prints the live RSP sampled in `ap_entry` (must lie in the region-7 direct-map window), the TSS.RSP0 read
back from `tss_array` while `sched_active == 0` (must *equal* the trampoline's top — the only observer of
the `gdt.cyr` half, since that RSP0 is dead until a ring-3 proc lands on the AP), and re-hashes the rekha
chunk literals **in place** (FNV-1a-64, as `rekha_face_default_verify`) against the generator hash — the
load-bearing oracle for "no stack is in the image". Restored tree, `-smp 4` under TCG, first QEMU attempt:
`smp: cpus online: 4`; `ap 1/2/3 rsp=0x200fdffa8 / 0x200feffa8 / 0x200ffffa8` (88 B under each top — one
`dm_read_rsp` frame below `ap_entry`'s, inside its own 64 KB window); `rsp0=0x200fe0000 / 0x200ff0000 /
0x201000000`; `rodata intact after AP wake`; `agnos>` at ~10 s. Mutations, restored byte-exact (sha256 + cmp):
(a) both sites back on the 1.57.2 placement → `rsp=0x31ffa8/0x32ffa8/0x33ffa8` OUT OF WINDOW ×3 +
`rodata CORRUPTED by AP stacks`, still `cpus online: 4` and kybernet (the corruption is silent — the
finding); (b) `gdt.cyr` only → three `rsp0 NOT the region-7 top` with the boot stacks still OK and rodata
intact (evidence lines in the smoke header).

**What the change broke — checked before archiving.** Nothing found, on the PLAIN kernel rebuilt last
(`build/agnos` carries 0 `smpstk` strings): `smp-smoke.sh` (production `-smp 4`) `smp: cpus online: 4`,
`agnos>` marker at 9 s, first attempt; `agnsh-smoke.sh` all three assertions (agnoshi 1.9.11 banner +
`[ASSIST] >`; the known ~30 % OVMF hand-off flake retried by the banner-gated dwell, as it always is);
`kfont-smoke.sh` `run: exit 95`; `check.sh` **34 passed, 0 failed** with the relabelled gate; `fmt-check`
"all kernel files formatted"; `kprint-len-check` 4169 literals, 0 mismatched. ⚠ Note what did NOT catch
the 1.57.2 placement: the mutant still counted four CPUs and reached kybernet — a boot-continuity line is
not an oracle for this class, which is why the guard is a runtime hash and a sampled RSP, not a marker.

**Docs.** The 1.57.2 notes at `gdt.cyr` (the IST1 map, `tss_get_cpu_stack`, `tss_kernel_stack`),
`boot_shim.cyr` ×2 and `kfont.cyr`'s COST paragraph were rewritten to the 1.57.3 truth;
`docs/architecture/kernel-font-namespace.md` (Invariant 2's reader rule retired, Invariant 5 rewritten as
the arc, the Gates table) and `docs/doc-health.md` (1.57.3 block) follow. Left for the release sync:
`CLAUDE.md` Closeout step 1 / the Architecture-Notes bullet, `state.md` rows 15/17/100, the `CHANGELOG.md`
1.57.3 entry.
