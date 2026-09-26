# 2026-09-25 — CPU-only pmm buffers (fb_console's shadow, the ramdisk, iommu's tables) are still addressed by identity VA

**Status:** 🟡 **OPEN**, unslotted. Found by 1.57.8 step DMA1. 1.57.8 converted every driver's DMA structures to the
direct map (`dma_kva`), but these three buffers are not DMA structures and were out of that issue's scope.
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
