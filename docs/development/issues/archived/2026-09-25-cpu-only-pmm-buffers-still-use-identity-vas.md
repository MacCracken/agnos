# 2026-09-25 — CPU-only pmm buffers (fb_console's shadow, the ramdisk, iommu's tables) are still addressed by identity VA

**Status:** ✅ **RESOLVED 1.57.9 (2026-09-26)** — fb_console's shadow, the ramdisk pages and `iommu.cyr`'s root / context / L2 tables hold a stored direct-map pointer (`dma_kva`) computed at allocation; the physical address is kept only where hardware or a PTE consumes it; `fb_shadow_init` runs after `cr3_load(0x1000)` + `pmm_bitmap_use_directmap`; the CR3 each iommu writer runs under is recorded. Gate: `dma-shadow-smoke` (a ring-3 PT_LOAD over the old identity VAs; `RAMDISK_ENABLE=1`) 27/0 at `-smp 1` and `-smp 4`. See § Resolution.
**Filed by:** agnos, from the 1.57.8 DMA1 step report (`open_problems[1..3]`).
**Checked against:** agnos **1.57.8**, `kernel/arch/x86_64/fb_console.cyr` `fb_shadow_init` (~:337),
`kernel/core/ramdisk.cyr` and `kernel/arch/x86_64/iommu.cyr`.
**Severity:** the same shadowing class as the archived DMA issue. `fb_shadow` is reachable from ring-3 syscalls;
the other two are a flag build and boot-only.

## What happens

1. **`fb_shadow`** comes from `pmm_alloc_2mb_run` and is written as phys == VA by `fb_putc` on the syscall path,
   under per-process CR3s. A ring-3 PT_LOAD that covers that identity VA would take the console's glyph stores.
2. **`ramdisk.cyr`** (`RAMDISK_ENABLE` only, not production) uses identity pointers from syscall block I/O.
3. **`iommu.cyr`** writes its page tables and root table through identity phys. It runs at boot under the kernel CR3,
   so it is probably safe, but it has not been audited.

## The fix

Store a direct-map pointer (`pmm_kva_for_access` / `dma_kva`) for each buffer and keep the phys only where a device
or a PTE needs it. Audit `iommu.cyr` and record which CR3 each of its writers runs under.

## Gate

Extend `DMA_SHADOW_SELFTEST`: under the shadow CR3, print a console line and require the shadow junk to be untouched
and the fb shadow to hold the glyphs. Add the ramdisk to the same run under `RAMDISK_ENABLE`.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/DMA1-report.json` (`open_problems`).

## Resolution (1.57.9, 2026-09-26)

Prior art followed: Linux reaches all RAM through the linear map (`page_address`, `phys_to_virt`), never a user-reachable identity
mapping, and writes IOMMU tables through kernel virtual addresses (`drivers/iommu/intel/iommu.c`); FreeBSD amd64 `PHYS_TO_DMAP`.

What it broke: nothing observed; the image SHRANK (the ramdisk pointer array went from 8 KB to 1 KB of .bss). Found and not fixed:
xHCI's rings are never IOMMU-granted (`iommu_register_dma` runs from `xhci_rings_init` before `iommu_init`), a runtime grant after
translation is on issues no invalidation, and no smoke boots `iommu.cyr` — filed as
`2026-09-26-vt-d-xhci-never-granted-and-iommu-never-booted.md`. `pmm_alloc_2mb_run`'s 256 MB ceiling no longer has a reason; lifting
it is on the roadmap.
