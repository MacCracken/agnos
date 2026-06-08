# DOOM on AGNOS — render blockers (handoff)

**Status (2026-06-08):** cyrius-doom **0.28.1** is the first port of the engine to
AGNOS. It builds `--agnos`, exec's from disk in ring 3 (the 584 KB ELF), and runs
through engine init (heap, `sakshi`, timing). **It does not render yet** — gated
on two *kernel-side* memory issues below. This doc is the handoff so the next
session doesn't re-derive any of it.

The DOOM port itself is done and shipped. Nothing in this doc is a port problem.

## Validation harness (in place, compile-gated, no production impact)

- `kernel/core/main.cyr` — `#ifdef DOOM_SELFTEST` gate: `sh_exec("run /bin/doom")`.
- `scripts/build.sh` — emits `#define DOOM_SELFTEST` when `DOOM_SELFTEST=1`.
- `scripts/doom-smoke.sh` — builds the DOOM_SELFTEST kernel, seeds an ext2 image
  with `/bin/doom` (+ `/DOOM1.WAD`), boots gnoboot+OVMF+NVMe, screendumps,
  gates on `cyrius-doom`/`wad loaded`/non-blank framebuffer. Serial →
  `build/doom-smoke-logs/serial.log`.

Re-validate any fix with `sh scripts/doom-smoke.sh`, and gate regressions with
`sh scripts/sweep.sh` (must stay 7/7 — the PMM is load-bearing).

## Blocker 1 — the PMM only manages 16 MB

`kernel/core/pmm.cyr`: `pmm_bitmap[512]` (= 4096 bytes = 32768 bits under the 8N
module-scope convention, but the code uses only the first 512 bytes), `pmm_total
= 4096` pages = **16 MB**; first 4 MB reserved → **12 MB usable**. The 2 MB pool
(`pmm_alloc_2mb` / `pmm_count_2mb_free`) scans only `r = 1..7` → **6 usable 2 MB
regions** (4–16 MB), shared with the 4 KB allocator and fragmented by KASLR.

DOOM needs far more than that: 4.2 MB WAD (a single contiguous `alloc`) + exec
regions + zone/screen/scaled-framebuffer heap = 10+ 2 MB pages. So the WAD
`alloc(WAD_DATA_MAX)` returns 0 → `wad_data == 0` → `read()` rejects it at
`is_user_range(0, …)` (ptr < 0x200000). That is the *real* reason the WAD never
loads (the earlier "CR3-safe ring-3 disk read" hypothesis was a misdiagnosis —
the read path was never reached with a valid buffer).

### Enlargement attempts — BOTH broke ring-3 execution (root cause NOT found)

Two attempts to grow the pool to 128 MB (32768 pages), both reverted:

1. **Blunt**: bitmap→full, `pmm_total=32768`, `pmm_page_valid >= 32768`,
   `pmm_alloc` top-down from page **32767**, `pmm_alloc_2mb`/`count` scan `r<64`.
   → sweep FAIL on `1.40.x exec-from-disk`.
2. **Surgical**: same, but left `pmm_alloc` (4 KB) at `4095`-down so page tables
   stay in 4–16 MB. → exec-smoke FAIL on **every** gate, incl. `exec: selftest
   done` missing — i.e. the exec selftest's *first* program (`prog2`, a trivial
   exit-42 binary that never mmaps) hangs/faults when it runs in ring 3.

So the break is **not** the 4 KB allocator placement and **not** BSS corruption
(`var[512]` is genuinely 4096 bytes — confirmed against `ext2_block_buf[512]` =
"4096 bytes"; `memset(&pmm_bitmap, 0, 4096)` is in-bounds). The common factor in
both failures is the set `{pmm_total=32768, memset(4096), 2 MB scan r<64,
pmm_page_valid ceiling 32768}` — and it breaks a *trivial non-mmap ring-3
program*. That points at boot-time or exec-time setup, not at mmap.

Relevant context the next session must hold:
- `pmm_alloc_2mb` comment (pmm.cyr ~166): a 2 MB huge page "must be backed by a
  **fully-reserved** 2 MB region or it aliases." Widening the scan into 16–128 MB
  exposes regions the rest of the kernel may not expect to be handed out.
- The **anti-fragmentation split** (1.41.12): 4 KB top-down, 2 MB bottom-up; they
  "only meet if total demand exhausts the 12 MB pool." This fixed a flaky agnsh
  ring-3 #PF. Any enlargement must preserve the invariant.
- Kernel identity map is **0–256 MB** (`proc.cyr:215`; `pt_init` maps 0–1 GB at
  `paging.cyr:16`), so 128 MB pages *are* reachable — not the cause.

**Next step:** boot the enlarged-PMM kernel under `qemu -d int` (TCG, so guest
exceptions log) and capture where `prog2` faults — CR2/RIP will name it. Likely a
specific structure (a page table, the syscall kstack at region 1, a DMA ring, or
a boot allocation) that the wider pool now collides with or whose page index the
`>= 4096 → >= 32768` ceiling change stops rejecting. Do NOT re-attempt blind.

## Blocker 2 — `alloc_init` Heisenbug (independent of Blocker 1)

On the **known-good 16 MB kernel**, doom's *first* `sys_mmap` after exec (inside
`alloc_init` → `_agnos_new_chunk` → `sys_mmap`) hangs/faults — doom prints its
entry marker, then silence, never reaching `alloc_init`'s exit. Deterministic:
without a warm-up it hangs 3/3; **with a prior raw `syscall(27, 2 MB)` "probe"
mmap it works** (1/1 — got past `alloc_init` + `sakshi`). Layout-sensitive →
almost certainly a fault, not a true hang.

Ruled out: it is **not** a cyrius wrapper/pin issue — `sys_mmap` is
`syscall(27, length)` and is byte-identical in 6.0.83 (doom's pin) and 6.0.87
(agnsh's pin), and `alloc_agnos.cyr` is identical between them. agnsh's heap
(same `alloc_agnos`) works, so the kernel `sys_mmap` path is generally sound —
something about the *first* mmap immediately after exec (TLB/CR3 staleness on the
fresh per-process arena PD entry? the first `proc_map_page` for vaddr
0x10000000?) faults unless primed.

**Next step:** `-d int` on a minimal repro (doom with no probe) → capture the
first fault after `exec: running /bin/doom`. Compare the page-table state at the
first `sys_mmap` with vs without the probe.

## Once both are fixed

The WAD loads → the title renders. For the render *output*, prefer the **PPM
path** (`framebuf_write_ppm`) writing a frame file to the ext2 root (e.g.
`/doom.ppm`) over the FB-blit/screendump — the file is extractable from the image
for a clean, deterministic render proof, and it exercises the ring-3 file *write*
path. (FB blit#39 + fbinfo#38 + timing#40/#41 already work and are validated.)
