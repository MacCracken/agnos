# 2026-09-26 — AHCI puts the caller's buffer pointer in the PRDT (the class MSC fixed in 1.57.9)

**Status:** 🟡 **OPEN** — for the next release. Found by 1.57.9's MSCBUF prior-art note and carried by its report and the merge.
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
