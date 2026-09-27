# 2026-09-26 — VT-d: xHCI's rings are never granted, a runtime grant is never invalidated, and no smoke boots `iommu.cyr`

**Status:** ✅ **RESOLVED 1.57.10 (2026-09-26)** — `iommu.cyr` boots with VT-d translation ON for the first time (the baseline QEMU boot printed `IOMMU: init failed`): pre-init grants are recorded and replayed before TE under `iommu_lock`; a post-TE grant gets exactly the invalidation Caching Mode needs; virtio-blk, virtio-net and AHCI now grant their DMA pages; seven further `iommu.cyr` defects fixed. Gate: `vtd-smoke` (q35 + `intel-iommu`, `-smp 1` CM=1 3-level and `-smp 4` CM=0 4-level; every DMA device working under translation, `faults=0`, an ungranted page BLOCKED) 61/61 + 4/4 static; mutations RED. See § Resolution.
**Filed by:** agnos, from the 1.57.9 CPUVA step report (`open_problems`).
**Checked against:** agnos **1.57.9**, `kernel/arch/x86_64/iommu.cyr`, `kernel/arch/x86_64/usb/xhci*.cyr` (`xhci_rings_init`).
**Severity:** latent on today's QEMU boots (no DMAR is published, so translation is never on); a DMA fault on iron with VT-d on.

## What happens

1. `iommu_register_dma` is called from `xhci_rings_init`, which runs BEFORE `iommu_init`, so the grant is a no-op: with translation
   enabled, xHCI DMA outside the first 16 MB would be blocked.
2. A grant made after translation is on (TE) issues no context-cache / IOTLB invalidation. That is harmless for not-present →
   present on hardware without caching mode, but wrong under caching mode (CM=1, e.g. QEMU's intel-iommu with `caching-mode=on`).
3. No smoke boots `iommu.cyr` at all: the `ECAP.C` clflush path and every table writer are only gated statically.

## The fix

Record grants made before `iommu_init` and replay them at init; after TE, follow each grant with the required invalidation
(Linux `drivers/iommu/intel/iommu.c` `iommu_flush_context` / `iommu_flush_iotlb_psi`, the VT-d spec §6.5). Add a smoke on QEMU q35
`-device intel-iommu,intremap=off` (virtio devices need `iommu_platform=on`) that boots with translation on and exercises xHCI,
NVMe and virtio DMA.

## Resolution (1.57.10, 2026-09-26)

Prior art followed: Linux `drivers/iommu/intel/iommu.c` (`cache_tag_flush_range_np`, `__mapping_notify_one`; flush on
not-present→present only under Caching Mode), FreeBSD `dmar(4)` `dmar_map_buf`, the Intel VT-d spec §6.1 / §6.5 / §6.8.
`docs/architecture/dma-cpu-pointers.md` § "VT-d: the grant model".

What it broke: nothing observed. Not fixed here: queued invalidation (a VER ≥ 6 unit is refused and translation stays off — filed as
`2026-09-26-vt-d-queued-invalidation.md`); grants are 2 MB-granular and never revoked (a neighbour's grant can mask a missing one);
no DMAR fault interrupt (faults are drained at the boot check). Paths QEMU cannot show — RMRRs, several DRHDs, 4 KB leaves, RWBF — are
gated by reading only.
