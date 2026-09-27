# 2026-09-26 — AHCI puts the caller's buffer pointer in the PRDT (the class MSC fixed in 1.57.9)

**Status:** ✅ **RESOLVED 1.57.10 (2026-09-26)** — `ahci_blk_read` / `_write` / `_read_sectors` bounce through one driver-owned, iommu-granted pmm page reached through `dma_kva`; only its physical address reaches the PRDT; settle before copy-in, copy-out only after a completed command. Gate: `ahci-late-smoke` `bounce` arm (kmalloc and unaligned direct-map buffers vs a `.bss` control) — RED with the fix reverted at `-smp 1` and `-smp 4` (bad = 512 / 8192 / 4080), GREEN 30/0 after. See § Resolution.
**Filed by:** agnos, from the 1.57.9 MSCBUF / MERGE step reports (`open_problems`).
**Checked against:** agnos **1.57.9**, `kernel/core/ahci.cyr` `ahci_blk_read` / `ahci_blk_write` / `ahci_blk_read_sectors` →
`ahci_issue_rw_inner` (~:1072).
**Severity:** latent. Safe today only because every in-tree caller passes a buffer in kernel `.bss` (identity-mapped under every CR3).

## What happens

`ahci_issue_rw_inner` stores the CALLER's `buf` as the PRDT entry's data base address (DBA). A buffer that is not identity-mapped
— a ring-3 page, a direct-map alias, a kmalloc page above the identity window — would make the HBA DMA into whatever physical page
that number happens to name. 1.57.9 removed exactly this from MSC (`msc-puts-the-caller-buffer-in-a-data-trb`, archived).

## The fix

The MSC/NVMe shape: bounce through a driver-owned pmm page reached through `dma_kva`, copy out after a complete transfer, settle
before reuse (the AHCI recovery of 1.57.9 already provides the settle). Prior art: Linux DMA API (`dma_map_sg`) + swiotlb bounce,
FreeBSD `busdma` bounce pages.

## Gate

An AHCI read/write with a caller buffer outside the identity window (the `msc-cdb-smoke` arm's shape, on an AHCI disk): RED before,
GREEN after; `ahci-late-smoke` stays green.

## Resolution (1.57.10, 2026-09-26)

Prior art followed: agnosticos `prior-art/ahci-iron-burn-audit.md`; Linux libata `ata_sg_setup` / `dma_map_sg` and swiotlb (including
its pre-fill of a READ bounce with the caller's bytes); FreeBSD `busdma` bounce pages; the MSC bounce of 1.57.9.

What it broke: throughput only — `ahci_blk_read_sectors` over 8 sectors issues one command per 8 sectors (was 128); ext2 4 KB blocks
are unchanged. `ahci_write_lba` is now unreachable in the plain build (kept: the `AHCI_RW_DEMO` / `AHCI_SELFTEST` primitive). AHCI's own
command list / FIS / CT / IDENTIFY pages are granted by 1.57.10's VT-d step.
