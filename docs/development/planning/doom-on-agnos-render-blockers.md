# DOOM on AGNOS — render status

**Status (2026-06-08): DOOM RENDERS.** cyrius-doom **0.28.2** `--agnos` boots to
the title screen under AGNOS: the 584 KB ELF exec's from disk in ring 3, slurps
the 4.2 MB `DOOM1.WAD` into memory, parses it, builds the palette, and blits a
240-colour frame to the framebuffer via `fbinfo`#38 / `blit`#39. The "agnsh
launches DOOM" milestone — the first real userland app on AGNOS. Validated by
`scripts/doom-smoke.sh` (`doom-smoke: PASS — DOOM renders on AGNOS`).

## The two kernel fixes that unblocked it

### 1. PMM 2MB pool 16MB → 128MB  *(RESOLVED — `pmm.cyr`)*

The PMM managed only 16 MB (4096 pages, 12 MB usable, a 6-region 2MB pool). DOOM
needs ~24 MB (4.2 MB WAD as one contiguous `alloc` + heap). Surgical enlargement:
`pmm_total = 32768`, `pmm_alloc_2mb`/`pmm_count_2mb_free` scan regions `r=1..63`,
`pmm_page_valid` ceiling 32768, `memset(&pmm_bitmap, 0, 4096)` — **the 4 KB
allocator (`pmm_alloc`) is left UNCHANGED at `4095`-down** so page tables / slabs
stay in 4–16 MB. `pmm_bitmap[512]` was already 4096 bytes (8N convention); only
the constants changed. Sweep 7/7; agnsh boots with 31727 free pages.

> The earlier "enlargement breaks exec" conclusion was a **harness artifact** —
> exec-smoke.sh requires the kernel pre-built with `EXEC_SELFTEST=1`, and the test
> runs had built it plain, so the selftest never ran and every gate "failed."
> Build with the flag. (`sysi` validator: 16 MB pool → exit 66, 128 MB → exit 73;
> exec-smoke.sh updated.)

### 2. Per-process CR3 must map the whole pmm range  *(RESOLVED — `proc.cyr`)*

`sys_mmap` zeroes a freshly-allocated 2 MB region via its **identity** address
(`memset(phys, 0, 2MB)`) under the per-process CR3. The per-process CR3 copies
PD[0..127] from the boot PD@0x3000, but the boot identity map it inherits only
covers **0–16 MB** (PD[0..7]). With the old 16 MB pool every phys was <16 MB
(mapped); the enlarged pool returns phys ≥16 MB → `memset` faults **ring-0 #PF →
#DF** (caught via `qemu -d int`: `e=0002 cpl=0 CR2=0x011f0000`). Fix:
`proc_create_address_space` now also maps **PD[8..63] = 16–128 MB as identity-
SUPERVISOR 2 MB pages**, so the kernel can reach the whole pmm range. U/S=0 keeps
ring 3 out; user code/stack live in PD[2]/PD[4], the mmap arena in PD[128+], so no
user VA aliases these slots.

## The "first-mmap RIP=0" bug — ROOT-CAUSED + FIXED (2026-06-09)

**It was never a first-mmap or SYSRET bug — it was the user stack living in the
kernel identity-mapped range.** `elf.cyr` placed user stacks at
`0x800000 + pid*0x400000`; for **pid ≥ 2** that is **≥ 16 MB**, inside the
`PD[8..63]` identity-**SUPERVISOR** pmm pool. `proc_map_page` then overrode that
PD slot to point at `stack_phys`, **breaking the identity map for that VA**. So
when a later `sys_mmap` did `memset(phys, 0, 2 MB)` on a page whose *identity* VA
aliased the stack VA, it wrote to the **live ring-3 stack** instead of the new
page, zeroing the saved return addresses → the next ring-3 `ret` jumped to
**RIP=0** (`v=0e e=0015 cpl=3 RIP=0`).

**Why it hid:** doom-smoke runs doom via the in-kernel recovery `run` (lower pid
→ stack below 16 MB → no aliasing), so it always rendered; the user hit it via
`agnsh` → `execwait` #37 (higher pid → stack at ~20 MB, in the pool). A
multi-page mmap (the 4.2 MB WAD) reliably grabs a region whose identity VA hits
the stack; the warm-up mmap only papered over the recovery path.

**Fix (`elf.cyr` + `proc.cyr`):** user stacks now live at the **top of the
non-identity arena** (`0x3FC00000`, PD[510]); the mmap ceiling dropped to
`0x3FA00000` (below the stack + its guard page). Each process has its own CR3 so
a fixed stack VA is safe, and no pmm phys aliases the arena. `proc_map_page` also
gained an explicit `invlpg` after the PDE store (latent-TLB hardening). The doom
warm-up workaround is **removed** (cyrius-doom `main.cyr`). Validated in QEMU:
the mm-repro + doom via **both** `execwait` and recovery `run` render with **0
RIP=0 faults**; `sweep.sh` **7/7**; `doom-smoke` PASS. **Iron burn pending** — the
QEMU repro of the exact iron-failure path (agnsh→execwait, multi-page WAD mmap)
now passes.

## Validation harness (kept)

- `main.cyr` `#ifdef DOOM_SELFTEST` gate (`sh_exec("run /bin/doom")`),
  `build.sh` `DOOM_SELFTEST=1` flag, `scripts/doom-smoke.sh` (the full
  exec→WAD→render gate). Re-validate any change with `doom-smoke.sh`; gate kernel
  regressions with `sweep.sh` (7/7).
