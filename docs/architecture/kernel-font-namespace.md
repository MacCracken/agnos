# The kernel-owned `/fonts` namespace — invariants behind the embedded TrueType face

> **Last Updated**: 2026-09-13 (1.57.2 — the cut that shipped it)
>
> Code: [`kernel/core/kfont.cyr`](../../kernel/core/kfont.cyr) (the whole kernel half, ~150 lines) · the
> three intercepts in [`kernel/core/syscall.cyr`](../../kernel/core/syscall.cyr) (`open`#7, `stat`#33,
> `lstat`#102) · the call site in [`kernel/core/main.cyr`](../../kernel/core/main.cyr) · the fold-in in
> [`scripts/build.sh`](../../scripts/build.sh) / [`test.sh`](../../scripts/test.sh) / [`bench.sh`](../../scripts/bench.sh).
> Ring-3 contract: [`../development/agnos-userland-abi.md` §3.5](../development/agnos-userland-abi.md).
> Origin: crab's filing, archived at
> [`../development/issues/archived/2026-09-13-no-proportional-face-on-the-target.md`](../development/issues/archived/2026-09-13-no-proportional-face-on-the-target.md).
>
> This note records *why the world is shaped this way*, for the things reading `kfont.cyr` alone will not
> tell you. The measured numbers are from the 1.57.2 build; re-measure them, do not copy them forward.

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
`rekha_face_default_chunk(i)` is the only accessor and `kfont_init` is its only kernel caller.

⛔ **That "read once, at boot, before the APs wake" is now a locked invariant, not a description** —
see Invariant 5. What ring 3 gets through `/fonts` is the **verified direct-map copy**, never the
`.rodata` literals. Do not add a re-verify, a second copy, or any later reader of the chunks.

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

## Invariant 5 — the image grew 410 KB, and "under the 4 MB identity map" was the wrong fit check

The boot shim identity-maps `0x0–0x400000` with 2 MB pages and the image loads at `0x100000`, so the
design's stated bound was "image + bss end under `0x400000`". Measured at 1.57.2 (`readelf -lW`):

| thing | before 1.57.2 | at 1.57.2 |
|---|---|---|
| `build/agnos` | 1,999,616 B | **2,418,896 B** (+419,280) |
| single `LOAD` end (`p_vaddr + p_memsz`) | ~0x2FA2xx | **0x35E770** |
| `.text` | — | 0x1000A8..0x223310 |
| `.bss` | — | 0x223310..0x2DBBD0 (unchanged) |
| `.rodata` | ~0xE6xx bytes | 0x2DBBD0..0x34E769 |
| rekha chunk literals (101 × 4096 B, stride 4097) | — | 0x2DBBEB..0x340113 |
| first live kernel literal above them (`"fb: mode="`) | — | 0x340114 |

`0x35E770 < 0x400000` — the stated bound holds. ⛔ **But the window `0x300000–0x400000` is not empty.**
PMM region 1 holds the kernel's *fixed* stacks, each placed by reading an image end off a build at the
time and picking a number above it — and nothing re-checked them since: AP1–3 boot/TSS stacks at **`0x310000–0x340000`**
(`smp.cyr` trampoline, `gdt.cyr` `tss_get_cpu_stack` = `0x300000 + cpu*0x10000 + 0x10000`), the BSP boot
stack top at `0x380000` (`boot_shim.cyr` step 12), TSS RSP0 at `0x3C0000`, syscall kstacks at
`0x3D0000`/`0x3F0000`. **The AP windows now sit inside `.rodata`, on rekha chunks ~52..100.** On any
`-smp ≥ 2` boot, CPUs 1–3 push their frames into the loaded kernel image through the RW identity pages —
no fault, no signal.

It is **inert today** for exactly two reasons, and `scripts/check/image-layout-check.sh` (check.sh
gate 34, "kernel image vs fixed kernel stacks") now locks both:

1. the chunks are read **once**, in `kfont_init` (~0.3 s), and the APs are woken by `smp_start_aps`
   ~5,500 lines of `main.cyr` later (~5.2 s) — confirmed with an extra `-smp 4` boot: `kfont … OK`,
   `smp: cpus online: 4`, agnsh banner. The gate locks the single reader chain
   (`rekha_face_default_copy` has one kernel caller; `rekha_face_default_chunk` one module caller) and
   proves every byte of `[0x310000, 0x340000)` is a dead chunk byte or NUL;
2. the first **live** kernel byte above CPU3's stack top is at `0x340114` — a margin of **0x113 = 275 B**.
   Any `.text`/`.bss` shrink or literal re-ordering over that slides `kprint` strings under an AP stack.
   The gate hard-fails a `LOAD` end above `0x370000` (the BSP boot stack's 64 KB budget; headroom at
   1.57.2 is `0x21890` = 137 KB, not the ~1.4 MB `boot_shim.cyr` used to claim) and reports the margin.

The real fix — relocating the AP stacks above the image (the region-7 kstack pool is the suggestion) —
is a layout redesign and the operator's decision:
[`../development/issues/2026-09-13-ap-stacks-inside-kernel-rodata.md`](../development/issues/2026-09-13-ap-stacks-inside-kernel-rodata.md).

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
| `scripts/check/image-layout-check.sh` — check.sh gate 34 | the AP stack window holds only dead chunk bytes; the single reader chain; `LOAD` end ≤ `0x370000` | mutation-tested (flipped chunk byte, patched byte under CPU1's stack top, `p_memsz` past `0x370000`) |
| `binary size` / `x86 size reasonable` | kernel-minus-face under the unchanged 2 MiB grant | check.sh / test.sh, lockstep |

**Not changed, and checked before the crab issue was archived:** `vfs.cyr` (`vfs_mount_init`,
`FsBackend`), `tests/mountlist/mlist.cyr` and `scripts/harness/mountlist-test.py` are byte-unchanged;
`mountlist`#104 still emits backend ids 1..3 only and `mlist.cyr:33`'s `be > 3 → 83` rule still passes.
