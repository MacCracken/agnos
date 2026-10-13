# 2026-09-26 — VT-d: no queued invalidation, so a VT-d 6.x unit (and any unit that only offers QI) is refused

**Status:** ✅ **RESOLVED 1.57.13 (2026-10-13)** — `iommu.cyr` implements VT-d queued invalidation and uses it whenever
ECAP.QI is set (Linux `dmar.c` / `iommu.c` shape, FreeBSD `intel_qi.c` second); the register interface is the fallback, and
the VER ≥ 6 refusal now applies to the register interface only. Gate: `vtd-smoke` — boots A (-smp 1, CM=1) and B (-smp 4,
CM=0) on the queue with QEMU's `vtd_inv_qi_*` / `vtd_inv_desc*` trace as the oracle, boots AR (A's machine) and BR (B's)
on the register interface from a `VTD_REGISTER_INV` kernel; selftest arm D recovers a malformed descriptor's IQE. Five
mutants measured RED. The cut's review added four fixes (the unit's own memory moved out of every device's reach —
arm E; a timeout STALLS the queue instead of killing it — arm F; the grant path says a stall / death; boot BR), four
more mutants RED. See § Resolution and § Review follow-up. Filed by 1.57.10 step VTD (the fix for `2026-09-26-vt-d-xhci-never-granted-and-iommu-never-booted`).
**Checked against:** agnos **1.57.13**, `kernel/arch/x86_64/iommu.cyr` (`iommu_qi_enable`, `iommu_qi_submit`,
`iommu_qi_fault`, `iommu_qi_disable`, `iommu_flush_context_global`, `iommu_flush_iotlb`, `iommu_init`).
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

## Resolution (1.57.13)

**Built** (`kernel/arch/x86_64/iommu.cyr`, banner § "1.57.13 (QI)"):

- `iommu_qi_enable` (Linux `dmar_enable_qi` + `__dmar_enable_qi`, FreeBSD `dmar_init_qi`): a queue page (256 × 128-bit
  descriptors, IQA.QS 0, DW 0) and a status page — own-chunk pages since the review below (first cut: from pmm), both
  reached by `dma_kva` (docs/architecture/dma-cpu-pointers.md:
  the phys goes only into IQA and the wait's Status Address); stale IQE / ICE / ITE cleared; IQT = 0 before IQA; GCMD.QIE
  and a GSTS.QIES wait. Run ahead of the root-entry flushes (Linux `init_dmars` → `intel_iommu_init_qi`).
- `iommu_qi_submit` (Linux `qi_submit_sync`): one descriptor and an invalidation-wait (type 5 | SW, Status Data = a
  sequence number — FreeBSD's `inv_waitd_seq`, so only this wait's write matches), one IQT write, the status word polled
  with `iommu_qi_fault` (Linux `qi_check_fault`) every turn; room from IQH (FreeBSD `dmar_qi_ensure`).
- IQE: the wait is copied over the malformed descriptor, IQE cleared, IQT rewritten (QEMU's FSTS handler does not restart
  the fetch; an IQT write does) — the invalidation is reported NOT performed; a second IQE in one submission, or one at
  the wait itself, is not recoverable. ITE: cleared, the submission fails (no device-TLB invalidation is ever issued).
  ICE: cleared, the wait continues. A wait that never completes (1 M polls), QIES clear at submit, no room, an
  unrecoverable IQE or an ITE marks the queue DEAD (`iommu: queued invalidation DEAD - <reason>`); later invalidations
  then count as `inv_fail` (register invalidation is not allowed while QIE is set).
- `iommu_flush_context_global` / `iommu_flush_iotlb` (Linux `qi_flush_context` / `qi_flush_iotlb`): the queue when it is
  on, `iommu_inv_context_global` / `iommu_inv_iotlb` (CAIG / IAIG still checked) otherwise. `iommu_init`'s two root-entry
  flushes and `iommu_after_new_leaf`'s CM invalidation go through them.
- `iommu_init`: the VER ≥ 6 and ECAP.IRO = 0 refusals apply only when the queue is not in use; the unit line ends
  `inv=queued|register`, a queue line follows it, the boot DMA check gains `qi= iqe= ite= ice=`.

**Decisions** (recorded in iommu.cyr and docs/architecture/dma-cpu-pointers.md): the queue under Caching Mode too (Linux;
FreeBSD's `dmar_init_qi` forces registers under CM — not followed, the issue names Linux); no memory for the queue → the
register interface (Linux falls back when `dmar_enable_qi` fails), QIES not latched → translation refused (fail closed,
like every other wait here); the queue and status pages are not clflushed (neither Linux nor FreeBSD flushes
descriptors; an mfence precedes the IQT write); a 1 M-poll bound (Linux and FreeBSD spin without one — the issue's
negative needs the path named). ⛔ This paragraph first also said the two pages were "neither granted": they were
`pmm_alloc` pages inside the replayed xHCI grant's region — corrected by the review below, together with the 1.57.10
tables that sat there too. The bound's first cut DIED at a timeout; since the review a timeout STALLS the queue.

**Defect fixed on the way:** `iommu_init` cleared a firmware-left QIE without draining the queue first; the spec forbids
that with requests pending and QEMU refuses it (QIES stays set → translation refused). `iommu_qi_disable` now waits for
IQH == IQT first (Linux `dmar_disable_qi`). Not reachable on QEMU + OVMF (firmware never enables the queue): static.

**Gate:** `scripts/smoke/vtd-smoke.sh` (sweep row "1.57.10/1.57.13 VT-d translation ON …"), boots A + B on the queue,
AR on the register interface: the processed descriptors exactly (context-cache global `lo 0x11`, IOTLB global `lo 0xd2`,
CM=1's page-selective `lo 0x100f2` / `hi page | 9`), every wait's status write to the kernel's status page in the issued
sequence, no CCMD / IVA / IOTLB register write while QIE is set, GCMD = QIE, SRTP|QIE, TE|QIE; AR keeps the 1.57.10
register checks and shows no queue event. Selftest arm D (`vtdst: qi recovery`): a type-0 descriptor → IQE recovered,
NOT performed, the queue drained (IQH == IQT), FSTS clear, a wait behind it completes.

**Measured RED** (1.57.13, boot A): IQT never written → `DEAD - the wait descriptor never completed (timeout)`, init
refused; reserved bit 6 in the context-cache descriptor → QEMU `invalid cc inv desc … (reserved nonzero)`, `IQE recovered …
NOT performed`, init refused; GCMD.QIE never set → `DEAD - GSTS.QIES clear at submit: QIE was never set`, init refused; the
recovery's wait copy removed → arm D FAIL (`iqe=+2 … dead=1`, `DEAD - an IQE that could not be recovered`); the post-TE
page-selective submission deleted → the selftest still PASSES (QEMU caches no failed translation) and the trace check of
the processed descriptors fails. Source restored byte-identical after each.

**Not tested:** ITE / ICE (QEMU never sets them: its FSTS write-1-clear mask is PFO | IQE); VER ≥ 6 (QEMU's unit reads
1.0); the firmware-left-QIE drain (above).

**What it broke:** nothing observed. The two changed report lines (` inv=` on the unit line; ` qi= iqe= ite= ice=` on the
boot DMA check) are read only by `scripts/harness/vtd-iommu-test.py` (grep over scripts/, tests/, docs/), which was
updated with them; vtd-smoke is green on A, B and AR.

**Review follow-up (1.57.13, the same cut — four findings, all fixed):**

- **The unit's own memory was reachable by every device** (major). `pmm_alloc` allocates top-down, so the queue page,
  the status page — and, since 1.57.10, the root, context and SL tables — landed inside the 2 MB region the replayed
  pre-init xHCI grant had opened read/write in the one shared domain (measured, boot A: RTADDR `0xffe1000`, queue
  `0xffe3000`, status `0xffe2000` under the leaf `0xfe00083` virtio-net translated through). A device could rewrite the
  SL tables, write the status word early, or forge a wait whose Status Address the unit writes untranslated. Fixed:
  `iommu_table_new` carves every such page from an own 2 MB chunk (`iommu_own_grow`: a whole free region no grant can
  ever cover); `iommu_map_2mb` and `iommu_register_dma` refuse one. Gate: selftest arm E + the trace checks (RTADDR / IQA
  / status in the chunk and in no region a device translated through). RED with `pmm_alloc` restored (`outside=6`,
  RTADDR in `0xfe00000`) and with the map refusal removed (`mapped=1 granted=2`).
- **A queue that died on a grant after the boot DMA check was never said** (minor). The DEAD reason was printed only by
  `iommu_init`'s refusals and the one-shot boot check. Fixed: `iommu_qi_tell` prints lock-free (klug + COM1), and the
  grant path says a stall / a death once each after dropping `iommu_lock`. Measured: with the stall arm's late hand-over
  removed, arm F's grant prints `DEAD - the wait descriptor never completed (timeout)` before the boot DMA check.
- **A timeout killed a slow but working queue for the rest of the boot** (minor). Fixed: a wait that outlasts the bound
  STALLS the queue (that call NOT performed); the next submission gives it one more full bound and only then declares it
  dead; `iommu_init` re-issues a stalled init flush once. Gate: selftest arm F (a held wait stalls, settles late, the
  queue drains); RED with the timeout death restored (`stalled=0 dead=1`). The boot DMA check gains ` stall=`.
- **The register fallback was no longer booted in its CM=0 / SMP / 4-level form** (minor): vtd-smoke gains boot BR (B's
  machine on the register kernel), which reaches the CM=0 "global flush ONLY" register check again.
