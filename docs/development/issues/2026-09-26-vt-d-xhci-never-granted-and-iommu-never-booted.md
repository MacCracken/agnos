# 2026-09-26 — VT-d: xHCI's rings are never granted, a runtime grant is never invalidated, and no smoke boots `iommu.cyr`

**Status:** 🟡 **OPEN** — for the next release. Found by 1.57.9 step CPUVA (adjacent to its issue; not in its scope).
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
