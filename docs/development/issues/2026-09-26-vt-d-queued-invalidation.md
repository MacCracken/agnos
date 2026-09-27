# 2026-09-26 — VT-d: no queued invalidation, so a VT-d 6.x unit (and any unit that only offers QI) is refused

**Status:** 🟡 **OPEN** — filed by 1.57.10 step VTD (the fix for `2026-09-26-vt-d-xhci-never-granted-and-iommu-never-booted`).
**Checked against:** agnos **1.57.10**, `kernel/arch/x86_64/iommu.cyr` (`iommu_init`, `iommu_inv_context_global`, `iommu_inv_iotlb`).
**Severity:** a refusal, not a fault. Translation stays OFF on such a unit, which is the state every boot before 1.57.10
was in; DMA is simply not restricted there.

## What happens

iommu.cyr invalidates through the **register-based** interface only (CCMD at 0x28, the IOTLB register at ECAP.IRO×16+8).
The VT-d spec deprecated that interface in Rev 3.3 (§6.5.1), and says that "on hardware implementations with Major
Version 6 or higher (VER_REG), all invalidation requests through this register are treated as incorrect invalidation
requests". So `iommu_init` refuses to enable translation at VER major ≥ 6, printing
`iommu: translation NOT enabled - VER >= 6.0 needs queued invalidation`. It also refuses whenever a register invalidation
reports granularity 0 (CAIG / IAIG), which is how a unit that honours only QI would answer.

## Why it was not done in step VTD

It is a second invalidation mechanism with its own failure modes, and it deserves its own gate. The pieces are:

- the invalidation queue page, programmed through IQA / IQT;
- `GCMD.QIE`;
- context-cache, IOTLB and wait descriptors, with status-write completion;
- IQE / ITE / ICE error recovery in FSTS.

Linux uses QI first (`dmar_enable_qi`, register-based only when `!ecap_qis`). FreeBSD forces register-based under Caching
Mode (`dmar_init_qi`).

QEMU's intel-iommu offers QI (ECAP.QI), so `scripts/smoke/vtd-smoke.sh` can verify it. It needs a mode that exercises
both interfaces, because QEMU also accepts register commands while QIE is clear.

## The fix

Implement queued invalidation, the Linux way (`intel/dmar.c` `__dmar_enable_qi` / `qi_submit_sync`, `iommu.c`
`qi_flush_context` / `qi_flush_iotlb`). Use it whenever ECAP.QI is set, and keep the register interface as the fallback.
Then lift the VER ≥ 6 refusal, while keeping the CAIG / IAIG checks on the register path.

Gate it on q35 + `-device intel-iommu` in both modes, with QEMU's `vtd_inv_desc_*` / `vtd_inv_qi_*` trace events as the
oracle. They play the part `vtd_reg_write` plays for the register path today.
