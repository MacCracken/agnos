# The kernel-owned `/fonts` namespace — invariants behind the embedded TrueType face

> **Last Updated**: 2026-09-13 (1.57.3 — Invariant 5 rewritten for the AP-stack relocation; first written at 1.57.2, the cut that shipped the face)
>
> Code: [`kernel/core/kfont.cyr`](../../kernel/core/kfont.cyr) (the whole kernel half, ~150 lines) · the
> three intercepts in [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr) (`open`#7, `stat`#33,
> `lstat`#102) · the call site in [`kernel/core/main.cyr`](../../kernel/core/main.cyr) · the fold-in in
> [`scripts/build.sh`](../../scripts/build.sh) / [`test.sh`](../../scripts/test.sh) / [`bench.sh`](../../scripts/bench.sh).
> Ring-3 contract: [`../development/agnos-userland-abi.md` §3.5](../development/agnos-userland-abi.md).
> Origin: crab's filing, archived at
> [`../development/issues/archived/2026-09-13-no-proportional-face-on-the-target.md`](../development/issues/archived/2026-09-13-no-proportional-face-on-the-target.md).
> The layout finding this face triggered, and its 1.57.3 resolution:
> [`../development/issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md`](../development/issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md).
>
> This note records *why the world is shaped this way*, for the things reading `kfont.cyr` alone will not
> tell you. The measured numbers are from the 1.57.2 build except where a figure is labelled 1.57.3
> (Invariant 5's resolution); re-measure them, do not copy them forward.

## What it is, in one paragraph

AGNOS carries **one proportional face** — Liberation Sans Regular 2.1.5, unmodified, 410,820 bytes,
SIL OFL 1.1 — inside the kernel image, the way it has always carried kashi's bitmap console fonts.
**rekha** (`../rekha`, the first-party outline-font library; kashi is the bitmap sibling) generates it as
a freestanding Cyrius module (`fonts/face_data.cyr`: 101 string literals of 4 KB plus copy/verify
helpers, no stdlib, no includes), and `scripts/build.sh` concatenates that module into the prepped kernel
source. At boot `kfont_init` assembles the chunks into one contiguous 2 MB region, **hashes them against
the generator's hash of the source `.ttf`**, and only on a match serves the copy read-only under two
names — `/fonts/default.ttf` (the stable contract) and `/fonts/LiberationSans-Regular.ttf` (the same
bytes; the name is the provenance). Everything below is a consequence of one of those sentences.

## Invariant 1 — verify before expose, and it is load-bearing, not hygiene

`kfont_ready` is set by exactly one statement, and it runs only after `rekha_face_default_verify`
(FNV-1a-64 of the assembled buffer) returned 1. A 0 leaves every arm answering -1 — the namespace
behaves as if 1.57.2 had never shipped — and prints `kfont: face verify FAILED - not exposed` so a bad
embed is a **visible boot fact**, not a garbled glyph an hour later in some client.

⛔ **The reason this is not merely defensive:** while generating `face_data.cyr`, rekha found that
**cyrius 6.6.3 emits a string literal of even length ≥ 65536 shifted by one byte on every alternate
literal** — silently: `rc=0`, the byte *count* is intact, only the *content* is wrong, and the wrong
content is a plausible one-byte shift of the right content. Nothing short of hashing detects it. It is
filed in the compiler repo as
[`cyrius/docs/development/issues/2026-09-13-agnos-large-string-literal-loses-first-byte.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/2026-09-13-agnos-large-string-literal-loses-first-byte.md)
(reproduced on 6.6.0 / 6.6.1 / 6.6.3; the repro proves itself). The kernel is downstream of a compiler
that has been *measured* corrupting exactly this class of data, so **the kernel never exposes bytes it
has not hashed** — and the build being green says nothing about the bytes being right.

⚠ **The hash does not protect the serving path — the ring-3 gate does.** The boot line proves the
kernel can see the bytes under *its* CR3. A memfile serving the wrong region under a *caller's* CR3
would still print `OK`. That is why `scripts/smoke/kfont-smoke.sh` hashes what a real ring-3 process
*received* through `read`#5 (mutant (a) in its header: the kernel's own `OK` line still printed while the
ring-3 hash caught the corruption).

## Invariant 2 — 4 KB chunks, read exactly once, and the served bytes are never the literals

rekha chunks the face at 4,096 bytes **to stay clear of the defect above** (the failure needs even
length ≥ 65,536). `rekha_face_default_copy` walks the 101 chunks into the caller's buffer;
`rekha_face_default_chunk(i)` is the accessor and `kfont_init` is its only *production* kernel caller.

What ring 3 gets through `/fonts` is the **verified direct-map copy**, never the `.rodata` literals — so
the literals are read once, at boot. ⚠ At 1.57.2 that "read once, before the APs wake" was briefly a
*locked* invariant with a "do not add a second reader" rule, because the AP stacks sat on the literals
(Invariant 5). **That rule is retired at 1.57.3**: the literals are ordinary `.rodata` again, and the
one other reader in the tree — `smp_stack_selftest` in `main.cyr`, under `#ifdef SMP_STACK_SELFTEST`
only — re-hashes them in place *to prove nothing is stacked on them*. Still do not add a re-verify or a
second copy to the production path; there is no reason to.

## Invariant 3 — one 2 MB region, addressed through the direct map, allocated after the CR3 switch

`kfont_init` takes one `pmm_alloc_2mb_run(1)` region — the `fb_shadow_init` precedent in
`arch/x86_64/fb_console.cyr`: allocated once, never freed (`pmm_alloc_2mb_run` has no free twin), from
the top of the ≤ 256 MB window down (the 1.57.2 boot landed at phys `0xEC00000`, region 118). The face
uses 20 % of it. On a verify failure the region **stays allocated** and `kfont_phys` keeps the address
so a later dump can look at what went wrong; a 2 MB hole is a smaller cost than a second allocator
path exercised only by a compiler defect.

⭐ **The region is filled and served through its DIRECT-MAP alias** (`pmm_kva_for_access(phys)` =
`DIRECTMAP_BASE 0x200000000 + phys`), **not the identity VA** that `fb_shadow` uses. The reason is
where `vfs_read` runs: its `VFS_MEMFILE` arm does `memcpy(buf, data + pos, count)` **under the
caller's CR3**, and in a per-process address space the low identity window is the *user image*, not
the kernel's view of physical memory. Every per-process PML4 mirrors kernel PDPT[8..] (the direct map),
so `DIRECTMAP_BASE + phys` is the one address that means the same thing under every CR3. `proc.cyr`'s
`ptw_pd_kva` header and `heap.cyr`'s `slab_grow` 1.56.51 note are the two earlier moves off identity for
the same reason; `kfont` starts there.

⛔ **And that alias is only usable after `cr3_load(0x1000)` — a measured fact, not a guess.** The
design slotted `kfont_init` "right after `fb_shadow_init()`", and the first boot printed
`kfont: face verify FAILED`. A debug boot showed the literals hashing to the expected
`0xbb32949696578ce6` *in place* while the buffer at `0x20EC00000` read back **all zeros**. At that
point the direct map is *installed* in the kernel PDPT but the CPU is still on gnoboot's boot CR3,
whose PDPT[8] maps an unrelated identity GB — so every store landed nowhere at `-m 512M` and would
land in someone else's RAM on a big box. `fb_shadow` gets away with the early slot because it uses the
identity VA. `kfont_init` therefore runs **after** the switch, next to `pmm_bitmap_use_directmap`, and
**inside `#ifndef BOOTCR3_KEEP_GNOBOOT_CR3`**: a keep-gnoboot build never has the direct map in its boot
context and simply gets no face (no line printed, `/fonts` answers -1). Do not move it back.

## Invariant 4 — it is a prefix intercept, not a mount, and that is deliberate

`/fonts` is **not** in `vfs_mount_init`, `FsBackend`, or `mountlist`#104. The three arms ask
`kfont_path_index(path, len)` *after* their `sc_path_ok` / `is_user_range` validation and the
relative→absolute normalisation, and *before* `vfs_resolve_mount`; a hit short-circuits into
`kfont_open` / `kfont_stat` and **-1 from those is final — no fallthrough to disk**.

Why not a fourth backend: `tests/mountlist/mlist.cyr:33` refuses backend ids `> 3`, and crab's VOLUMES
sidebar consumes that table with a capacity bar per row. A font namespace is not a volume; giving it a
backend id would put a phantom disk in every client's sidebar and break the gate that guards the table.
`statfs`#103 on the face path is *not* intercepted either — it routes to disk and returns -1 on a root
that has no such file, which is the right answer to "how big is the volume under this path".

**Shadowing follows from the shape and is the contract**: an on-disk `/fonts` directory is shadowed for
`open`/`stat`/`lstat` of the two names only. `getdents`, `readdir`, `mkdir`, `unlink`, `rename`,
`statfs` and everything else still see the disk. So `ls /fonts` on a root without that directory lists
nothing while `open("/fonts/default.ttf")` succeeds. A client opens the face **by name**.

Two consequences a client must know: the fd is a `VFS_MEMFILE`, so **`write`#1 is -1** (no memfile
arm in `vfs_write`) and **`lseek`#58 is -1** (`#58` repositions `VFS_EXT2_FILE` only) — the face is
read front-to-back in one pass, and a rewind is a re-open. `read`#5 returns 0 at EOF, never -2.

## Invariant 5 — the image grew 410 KB, the AP stacks were under it, and 1.57.3 moved them out

The legacy multiboot1 shim identity-maps `0x0–0x400000` with 2 MB pages (its step 4; the production
ELF64 shim builds no tables and runs under gnoboot's, which cover the same window) and the image loads at
`0x100000`, so the design's stated bound was "image + bss end under `0x400000`". Measured at 1.57.2
(`readelf -lW`; the 1.57.3 tree is 320 B longer, LOAD end `0x35E8B0`, `build/agnos` 2,419,216 B):

| thing | before 1.57.2 | at 1.57.2 |
|---|---|---|
| `build/agnos` | 1,999,616 B | **2,418,896 B** (+419,280) |
| single `LOAD` end (`p_vaddr + p_memsz`) | ~0x2FA2xx | **0x35E770** |
| `.text` | — | 0x1000A8..0x223310 |
| `.bss` | — | 0x223310..0x2DBBD0 (unchanged) |
| `.rodata` | ~0xE6xx bytes | 0x2DBBD0..0x34E769 |
| rekha chunk literals (101 × 4096 B, stride 4097) | — | 0x2DBBEB..0x340113 |
| first live kernel literal above them (`"fb: mode="`) | — | 0x340114 |

`0x35E770 < 0x400000` — the stated bound held. ⛔ **But the window `0x300000–0x400000` was not empty.**
PMM region 1 held the kernel's *fixed* stacks, each placed by reading an image end off a build at the
time and picking a number above it, and nothing re-checked them since. At 1.57.2 the AP1–3 boot/TSS
stacks were at `0x310000–0x340000` (`smp.cyr` trampoline `add eax, 0x310000`; `gdt.cyr`
`tss_get_cpu_stack` = `0x300000 + cpu*0x10000 + 0x10000`) — **inside `.rodata`, on rekha chunks
~52..100**: on any `-smp ≥ 2` boot CPUs 1–3 pushed their frames into the loaded kernel image through
the RW identity pages, no fault, no signal, and every `-smp 1` gate stayed green. It was inert only
because the chunks are read once in `kfont_init` (~5,500 lines before `smp_start_aps`) and 275 B of
dead chunk lay above CPU3's top. 1.57.2 shipped it under a tolerance gate that decoded the chunk bytes
under the window and locked the single reader chain; that was the accommodation, not the fix, and the
filing is archived at
[`../development/issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md`](../development/issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md).
(The same paragraph used to list the syscall kstacks at `0x3D0000`/`0x3F0000`; those left region 1 for
region-7 direct-map VAs at 1.46.x/1.51.x — `syscall_hw.cyr` — and were stale even then.)

**1.57.3 — the resolution (operator decision 2026-09-13): the AP stacks moved to region 7.** AP *n*
(1..3) now owns phys `[0xFC0000 + n*0x10000, +0x10000)` in the region-7 kstack pool (`0xE00000–0x1000000`,
pmm-reserved by `pmm_init`, which the image can never reach), reached through its **direct-map alias**
— top `DIRECTMAP_BASE + 0xFD0000 + n*0x10000`. Both placement sites hand the AP the same VA: the
trampoline's 64-bit section does `add eax, 0xFD0000; mov rcx, imm64 DIRECTMAP_BASE; add rax, rcx;
mov rsp, rax` (section 92 → 105 B; its comment had read "77" since the 1.46.x lretq block's +15 went
uncounted — re-derived in place), and `tss_get_cpu_stack` returns the identical expression for RSP0.
Never the identity VA: region 7's identity range (14–16 MB) is inside the user-segment range and ark's
per-proc CR3 overrides PD[7], while an AP idle's stack outlives the boot CR3 — the rule the syscall
kstacks and IST1 already follow. Region 7 is now **full** (`gdt.cyr`'s IST1 note carries the five-consumer
map); `smp_start_aps` allocates nothing and refuses to send INIT-SIPI unless both the identity PD entry
and the direct-map PDPT[8] entry (the one the AP's first push actually walks) are present.

The BSP is untouched — boot stack top `0x380000`, RSP0 `0x3C0000` — because its boot stack is live from
the shim's first instruction under gnoboot's CR3, before any kernel page table (and so the direct map)
exists; region 1 is the one window every CR3 from power-on onward maps. So the image's **only** region-1
neighbour is the BSP boot stack, and the one invariant left is:

> **`LOAD end <= 0x370000`** — the BSP boot stack's 64 KB budget. `scripts/check/image-layout-check.sh`
> (check.sh gate 34, *"kernel image vs BSP boot stack (LOAD end <= 0x370000)"*) parses the ELF, hard-fails
> above that, and prints the headroom (`0x11750` = 71,504 B at 1.57.3). It no longer decodes chunks or
> counts readers — that branch is gone with the layout it described. Mutation: `p_memsz` → `0x370001` FAILs.

**Where an AP stack actually is** is proven at runtime, not by a static grep of the trampoline's hex:
`SMP_STACK_SELFTEST` (`scripts/build.sh` define; `smp_stack_selftest` in `main.cyr`, run after
`smp_start_aps` and 5 further ticks, before `sched_active = 1`) prints, per online AP, (1) the live RSP
sampled in `ap_entry` — must lie in `[DIRECTMAP_BASE + 0xFC0000, DIRECTMAP_BASE + 0x1000000)`; (1b) the
TSS.RSP0 read back from `tss_array` — must *equal* the trampoline's top (that RSP0 is dead until a
ring-3 proc lands on the AP and is overwritten by the first real switch, so this read is the only
observer of the `gdt.cyr` half); and (2) the rekha chunk literals re-hashed **in place** (FNV-1a-64, as
`rekha_face_default_verify`) against the generator hash — the load-bearing oracle for "no stack is in
the image". `scripts/smoke/ap-stack-smoke.sh` (sweep.sh row *"1.57.3 AP stacks in region 7"*, `-smp 4`)
builds that kernel and gates all three plus `smp: cpus online: 4` and `kybernet:`. Mutations, restored
byte-exact: both sites back on the 1.57.2 placement → `rsp=0x31ffa8/0x32ffa8/0x33ffa8` OUT OF WINDOW ×3 +
`rodata CORRUPTED by AP stacks`, still booting to kybernet (the corruption is silent — the finding);
`gdt.cyr` alone reverted → `rsp0 NOT the region-7 top` ×3 with the boot stacks and rodata still clean
(evidence lines in the smoke header).

⚠ **The 2 MiB size gates did not move.** `scripts/check.sh` `binary size` and `scripts/test.sh`
`x86 size reasonable` both cap the kernel at 2,097,152 B and both went red at 2,418,896 B. The comment
at each says the cap is "a grant, not a measurement … do not simply move it again", so it was not
raised: each gate now weighs `SZ` **minus the face length read live from the very face module the build
cat'd in** (`fn rekha_face_default_len() { return N; }`, fail-closed to 0 if unreadable), so what sits
under the grant is kernel code + tables + kashi — what the grant was measured against (kashi was already
inside it). Weighed figure at 1.57.2: **2,008,076 B**, the same ~89 KB headroom the tree had before the
face. The two subtractions must move together, like the ceiling itself. check.sh is 34 gates now.

## Invariant 6 — how the bytes reach the kernel: the kashi mechanism, mirrored line for line

`cyrius.cyml` carries `[deps.rekha] path = "../rekha" modules = ["fonts/face_data.cyr"]` after
`[deps.kashi]` — as **documentation of the contract**. The **mechanism** is `scripts/build.sh`: it
resolves `REKHA_DIR` (the sibling checkout `../rekha` by default, else `git clone --branch $REKHA_REF`
for a clean CI checkout; `REKHA_REF=0.3.8`) and `cat "$REKHA_DIR/fonts/face_data.cyr"` into the prepped
source immediately before `cat kernel/agnos.cyr`, exactly where kashi's `src/font_data.cyr` goes.
`scripts/test.sh` and `scripts/bench.sh` carry the **same** `REKHA_DIR`/`REKHA_REF` defaults and must
move with it — the kashi triple diverged three times before 1.56.51 for exactly this reason, and
`[deps.rekha] path` winning locally means a stale default is invisible until a clean checkout builds
against a different face than the one that was tested. Nothing was added to `[deps].stdlib`; the
kernel stays `[deps] stdlib = []` and the module is freestanding by construction (string literals,
integer arithmetic, `load8`/`store8` only).

⛔ **The clone fallback refuses to `rm -rf` a git checkout** (build.sh, test.sh, bench.sh — both the
rekha and the kashi blocks since 2026-09-13). The sentinel it probes (`fonts/face_data.cyr`) is
*untracked* in a rekha tree that has not committed `fonts/` yet, so ordinary sibling hygiene (`git stash
-u`, `git clean -fd`, `git checkout 0.3.7`) makes the branch fire against a **live** checkout; the
unconditional delete that used to sit there would have erased the whole sibling including `.git` before
a clone that cannot succeed on an uncut tag — silently, because check.sh/sweep.sh run the build with
output to `/dev/null`. The kashi block was only ever safe because kashi commits its `font_data.cyr` on
every tag, a precondition that does not carry over by copying lines. The fallback exists for an
**absent** sibling; a checkout that lacks the file is the operator's to fix. ⚠ As of 2026-09-13
`../rekha` is at `VERSION` 0.3.8 uncommitted with tags only to 0.3.7, so the CI clone fails until the
operator cuts the tag; the sibling path wins locally.

`kfont.cyr` is included from `kernel/agnos.cyr`'s unconditional core block after `pmm`/`vmm`/`vfs`
(which it calls). It is x86-safe only through what it calls: its one x86-only callee is
`pmm_kva_for_access`, which `heap.cyr` already leaves undefined on aarch64, and its callers (`main.cyr`,
`syscall.cyr`) are x86-only — so no aarch64 stub was needed and the port's undefined-symbol count is
unchanged (33 functions / 46 variables before and after; the face module is cat'd into the aarch64
prep line too, with a comment on why kashi is not).

## Provenance and licence

Liberation Sans Regular **2.1.5**, **unmodified**: 410,820 bytes, sha256
`baccc64becc3eb7d104b7c84d99f5314a0a1f896e2b3ea6c2f22fc08d2003bee`, FNV-1a-64 `0xbb32949696578ce6`,
`sfntVersion 0x00010000`, 19 tables (`glyf` outlines + `cmap`, which is what `rekha_font_open`
accepts). **SIL Open Font License 1.1** — Copyright (c) 2012 Red Hat, Inc., Reserved Font Name
*Liberation*; digitized data copyright (c) 2010 Google Corporation. The licence text is
`../rekha/fonts/LICENSE-LiberationFonts` and **must travel with any redistribution of these bytes**;
the OFL permits bundling with GPL-3.0 software and does not permit dropping the notice. Source face:
`../rekha/fonts/LiberationSans-Regular.ttf`; generator: rekha `scripts/face2cyr.py`.

## Gates

| Gate | What it proves | Where |
|---|---|---|
| boot line `kfont: /fonts/default.ttf 410820 bytes OK` | the kernel assembled and hashed the face under its own CR3 | every boot; `kprint-len-check` covers the literal lengths |
| `scripts/smoke/kfont-smoke.sh` + `tests/kfont/kfont.cyr` — **exit 95** | a real ring-3 process, exec'd from disk, opens by name, reads all 410,820 bytes, **hashes them** (the oracle), parses the sfnt header, probes each refused flag bit, both non-names, `stat`#33 and `lstat`#102 field-for-field, the alias; a `run: exit 128+vector` arm catches a fault-killed exerciser | `scripts/sweep.sh` row "1.57.2 kernel-embedded face"; six mutants recorded in the smoke header |
| `scripts/check/image-layout-check.sh` — check.sh gate 34 *"kernel image vs BSP boot stack (LOAD end <= 0x370000)"* | `LOAD` end ≤ `0x370000` — the image stays under the BSP boot stack, the only region-1 neighbour left (1.57.3; the 1.57.2 chunk-decode / single-reader branch is gone) | mutation-tested (`p_memsz` past `0x370000`); prints the headroom |
| `scripts/smoke/ap-stack-smoke.sh` + `SMP_STACK_SELFTEST` — **-smp 4** | each AP's live RSP in the region-7 direct-map window, each AP's TSS.RSP0 equal to the trampoline's top, the rekha chunk literals hash-intact **in place** after the wake, `smp: cpus online: 4`, kybernet | `scripts/sweep.sh` row "1.57.3 AP stacks in region 7"; two mutants in the smoke header (1.57.2 placement; `gdt.cyr`-only revert) |
| `binary size` / `x86 size reasonable` | kernel-minus-face under the unchanged 2 MiB grant | check.sh / test.sh, lockstep |

**Not changed, and checked before the crab issue was archived:** `vfs.cyr` (`vfs_mount_init`,
`FsBackend`), `tests/mountlist/mlist.cyr` and `scripts/harness/mountlist-test.py` are byte-unchanged;
`mountlist`#104 still emits backend ids 1..3 only and `mlist.cyr:33`'s `be > 3 → 83` rule still passes.
