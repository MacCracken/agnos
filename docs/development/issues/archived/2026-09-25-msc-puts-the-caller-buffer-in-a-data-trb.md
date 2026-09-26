# 2026-09-25 — USB MSC: `msc_blk_*` put the caller's buffer pointer straight into a data TRB as a DMA address

**Status:** ✅ **RESOLVED 1.57.9 (2026-09-26)** — `msc_blk_read` / `_write` / `_read_sectors` bounce through a driver-owned pmm page (`msc_ensure_data_buf`, iommu-registered, reached through `dma_kva`); a READ copies out only after a complete transfer, a WRITE settles before copying in; the caller's pointer never reaches a TRB. Gate: `msc-cdb-smoke` 49/0 at `-smp 1` and `-smp 4`, including a caller buffer outside the identity window. See § Resolution.
**Filed by:** agnos, from the 1.57.8 XHCI step report (`open_problems[0]`) and the XHCI end review.
**Checked against:** agnos **1.57.8**, `kernel/arch/x86_64/usb/msc.cyr` `msc_blk_read` (~:1752),
`msc_blk_write` (~:1761) and `msc_blk_read_sectors` (~:1804).
**Severity:** wrong-address DMA if a caller ever passes a kmalloc or direct-map buffer. Not observed: every in-tree
caller the review checked passes a `.bss` or pmm-identity buffer.

## What happens

The block-layer entry points hand the caller's `buf` to the bulk data TRB unchanged. Where `buf` is a
direct-map or kmalloc address (`0x2_0000_0000+`), the xHC DMAs to that value taken as a physical address, which is
somewhere else entirely. This is only reachable when MSC is the active, ext2 or FAT backend (third, after NVMe and
AHCI), and no smoke exercises MSC as a filesystem backend.

## The fix

Bounce through the row's data page (a pmm page whose phys is known; access it through `dma_kva`), as the NVMe and
AHCI block paths do, or translate `buf` with a checked virt-to-phys that refuses anything outside the identity window.

## Gate

An `msc` smoke arm that reads and writes through `msc_blk_*` from a kmalloc'd buffer and compares bytes. It must be
RED on today's code. Also run `msc-short` and `msc-cdb` at `-smp 1` and `-smp 4`.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/XHCI-report.json`, `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/XHCI-endreview.json`.

## Resolution (1.57.9, 2026-09-26)

Prior art followed: Linux usb-storage/SCSI map buffers through the DMA API and bounce through swiotlb when memory is not
DMA-addressable; FreeBSD `busdma` bounce pages. TRB data pointers are only ever physical addresses the driver owns.

What it broke: throughput — `msc_blk_read_sectors` now issues one READ(10) per 4 KB (was up to 65,024 B per command); an ext2 4 KB
block is still one command. The settle-before-copy hunk on WRITE is not discriminated by a test (QEMU usb-storage cannot produce a
late data-phase DMA). The same defect class remains in AHCI's PRDT — filed as `2026-09-26-ahci-puts-the-caller-buffer-in-the-prdt.md`.
