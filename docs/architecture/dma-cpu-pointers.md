# DMA CPU pointers — the direct map, never phys == VA (1.57.8; CPU-only pmm buffers 1.57.9)

A driver's DMA structures (rings, command tables, bounce pages) are `pmm_alloc` pages. The device is given their
**physical** address; the CPU must reach them through their **direct-map alias** (`dma_kva(phys)` =
`DIRECTMAP_BASE + phys`), never by dereferencing the physical value as a pointer.

## Why phys == VA is unsafe

`pmm_alloc` draws from [0x400000, 0x10000000) — PD[2..127] of GB 0. Under the kernel CR3 that window is identity
mapped, so `load64(phys)` happens to work. Under a **per-process CR3** it is the process's window: the ELF loader
writes a ring-3 PT_LOAD's PDEs over exactly those slots (heap.cyr's 1.56.51 slab banner has the same argument for
kmalloc). Block I/O runs from fs syscalls under the caller's CR3, and ISRs run under whatever CR3 is live, so a
driver that reaches its SQ, descriptor ring or CORB by identity VA reads and writes the **process's page** — the
device never sees the command, and the kernel parses bytes the process controls. (With the loader's US=1 PDEs the
CPL0 access is a SMAP #PF instead: a ring-3-triggerable kernel fault.) The direct map (kernel PDPT[8+]) is copied
into every per-process PDPT by pointer and sits above the loaders' 0x10000000 ceiling, so no process can shadow it.

## The rule

- A `*_phys` value goes only into a device register (queue base, CLB/FB, CORB/RIRB base), a descriptor/SQE/PRP/
  CTBA/PRDT address field, or `pmm_free`. Never into `load*`/`store*`/`memcpy` as the address.
- The CPU pointer is computed ONCE, at allocation, and stored as `*_kva` (or in a pointer that names no `_phys`):
  virtio_blk `vblk_desc/avail/used`; nvme `nvme_asq_kva`, `nvme_acq_kva`, `nvme_ident_kva`, `nvme_iosq_kva`,
  `nvme_iocq_kva`, `nvme_scratch_kva`, `nvme_prp_list_kva` (`nvme_zero_page` takes a phys and converts inside);
  ahci `ahci_port_cl_kva[]`, per-call `ct_kva`/`id_kva`, demo `dk`/`dk2`, the block layer's bounce page `ahci_bb_kva`
  (1.57.10); hda `hda_corb_kva[]`, `hda_rirb_kva[]`
  (the BDL and PCM ring were already direct-map). The NICs (virtio-net, r8169) were converted in 1.57.7 S4.
- `.bss` buffers inside the kernel image (e.g. `vblk_dma_buf`, `vblk_req_hdr`) are fine as they are: the image is
  below 4 MB (PD[0..1]), identity mapped in every CR3, so their VA **is** their phys.
- `dma_kva` returns phys in a `BOOTCR3_KEEP_GNOBOOT_CR3` build (no direct map in kmain's context there).
- It is only valid after `cr3_load(0x1000)` + `pmm_bitmap_use_directmap()` (CLAUDE.md); every driver init runs
  after that point.

## CPU-only pmm buffers (1.57.9)

The rule is not about DMA; it is about **any pmm page a CPU touches from a syscall or an ISR**. Three buffers no device
ever reads were still reached at phys == VA until 1.57.9 (issue 2026-09-25-cpu-only-pmm-buffers-still-use-identity-vas):

- **fb_console's shadow** (`fb_shadow`, from `pmm_alloc_2mb_run`). `fb_putc` runs on the `write(1,..)` path under the
  caller's CR3, so glyph stores went into the process's pages, the scroll copied the process's bytes onto the screen,
  and with US=1 PDEs the CPL0 access was a SMAP #PF ring 3 could trigger. `fb_shadow` now holds `dma_kva(run)`; no
  phys is kept. Because the alias is live only under 0x1000, `fb_shadow_init` moved from before `cr3_load(0x1000)` to
  after `pmm_bitmap_use_directmap()` / `kfont_init()` in `main.cyr` (outside the `#ifndef`, so a
  `BOOTCR3_KEEP_GNOBOOT_CR3` build still gets a phys == VA shadow under gnoboot's CR3, as before).
- **the ramdisk** (`RAMDISK_ENABLE`): `ramdisk_page_kva[]` holds each page's direct-map pointer; the per-page
  `vmm_map(p, p, 0x83)` into the live CR3 is gone.
- **iommu.cyr's tables** (Linux `intel-iommu` shape): `iommu_root_phys/_kva`, `iommu_top_phys/_kva`, and since 1.57.10
  every per-bus context table and lower second-level table, reached by `dma_kva(entry & mask)` (Linux
  `phys_to_virt(dma_pte_addr(pte))`). The phys goes only into RTADDR, a root entry's context pointer, a context entry's
  SLPTPTR and a second-level non-leaf entry; every memset/store uses the KVA. (1.57.9's `iommu_map_mmio` PD walk is gone:
  the register block is mapped by `vmm_remap_uc_2mb` like every other MMIO BAR.) **CR3 audit:** until 1.57.9 every
  writer ran at boot on 0x1000 — safe by call-site placement; since 1.57.10 a grant made after translation is on can come
  from a syscall (msc's data page, hda's stream buffers) under a process's CR3 or from an AP, which is exactly why the
  KVA rule matters here. `ECAP.C` (the hardware walk snoops CPU caches) is read before the first table write, and on
  non-coherent hardware every table write is clflushed (`iommu_flush_cache`, Linux `__iommu_flush_cache`) — QEMU
  reports C=0, so vtd-smoke runs that path.

**Boot assert.** Each stored-pointer site runs `dma_kva_ok(kva)` once, at allocation: the pointer must lie inside the
direct map actually installed, `[DIRECTMAP_BASE, (directmap_pdpt_top + 1) GB)` (FreeBSD's `PHYS_TO_DMAP` KASSERT without
an assertion framework). A failure refuses the buffer (direct-paint console / ramdisk disabled / IOMMU not enabled)
instead of storing an address a process can own. Always 1 in a KEEP_GNOBOOT build.

**Why the direct map is safe here (the invariant this rests on).** Linux puts its direct map in the upper canonical half;
agnos's is at kernel PDPT[8 .. directmap_pdpt_top] in the LOWER half. It is unshadowable only because no user mapping
reaches it: ring-3 PT_LOADs are capped below 0x10000000 (`elf.cyr`, PD[2..127]), the low mmap arena is in PDPT[0], and
the high mmap arena starts at `himmap_floor()` = the first GB above `directmap_pdpt_top` (`proc.cyr`, asserted by the
`userwin` selftest). A new user mapping class that could reach PDPT[8+] breaks every pointer in this document.

**Placement vs. pointer.** `pmm_alloc_2mb_run` keeps its 256 MB ceiling, but its stated reason (phys == VA under every
CR3) is gone — both callers now use the direct map. Lifting it would move the shadow and the kfont region into the
top-of-RAM pool sys_mmap's 2 MB allocator draws from; that is an operator call, not taken in 1.57.9.

## The gate

`DMA_SHADOW_SELFTEST=1 RAMDISK_ENABLE=1` → `scripts/smoke/dma-shadow-smoke.sh` (sweep row). A static half greps the four
drivers plus iommu.cyr / ramdisk.cyr / fb_console.cyr for `(loadN|storeN|memset|memcpy)(<name>_phys` and must find
nothing; it also requires every `*_kva =` in iommu.cyr / ramdisk.cyr to come from `dma_kva`/`pmm_kva_for_access`, and
`fb_shadow_init();` to be called once, after `pmm_bitmap_use_directmap();`. For iommu.cyr's table POINTERS that static
half is the gate (dma-shadow-smoke publishes no DMAR); the tables themselves are booted with translation on by
`vtd-smoke.sh` (§ "VT-d: the grant model" below). The boot half (`core/selftests.cyr`) builds a CR3 that is a copy
of the kernel's with PD[2..127] all pointing at ONE 2 MB region of 0xA5 — the worst a PT_LOAD over the window can
do, with supervisor PDEs so an identity access lands silently instead of faulting — and, IF=0 under it, runs every
block backend (1 + 8 sectors + FLUSH, NVMe's 24-sector PRP-list path) and two HDA verbs. `dmash: shadow PASS` is the
self-check that the window really is shadowed. Measured RED per driver by reverting its `dma_kva` at the
allocation site (1.57.8 DMA1): virtio `bad=31576`, nvme `bad=31576` (5 s timeout, then the controller disabled),
nvme-prp `bad=4536`, hda `shadowed=0`, ahci (CT) `bad=16576`. ⚠ The AHCI **command list** alone is not
discriminated: slot 0's header is nearly constant across commands (CFL=5, PRDTL=1, same CTBA), so a stale header
from the previous command still works under QEMU. It is converted all the same.

The CPU-only arms (1.57.9) must cross the CR3 switch, because a store and a load of the SAME identity VA under the
shadow both hit the 0xA5 region and agree: `dmash: fb` paints a '#' in a unique ink with `fb_putc` under the shadow
and checks, on the kernel CR3, that the `fb_shadow` cell equals the FB cell and holds the ink; `dmash: ramdisk` writes
a sector on the kernel CR3 and reads it under the shadow, then the reverse. `dmash: window PASS dirty=0` requires the
0xA5 region untouched after every arm. Measured RED (1.57.9 CPUVA): `fb_shadow = base` (phys) → `fb FAIL bad=100424`,
`window dirty=256 (fb 256)`; ramdisk storing `p` → `ramdisk FAIL bad=1088`, `window dirty=512 (ramdisk 512)`;
`memset(iommu_root_phys, ..)` → the static grep; `fb_shadow_init()` back at its pre-switch slot → the ordering grep.

## A caller's buffer is a CPU pointer, never a DMA address (1.57.9)

The rule's other half: a block backend's `*_blk_read/_write/_read_sectors(…, buf)` receives a **CPU pointer**.
It may be `.bss`, kmalloc, a direct-map VA or the stack, and it must never reach a descriptor field. Linux draws
the same line: drivers get a `dma_addr_t` from the DMA API and never DMA to stack or kernel-image addresses by pointer.
usb-storage bounces through `us->iobuf`, and swiotlb bounces when a buffer is not device-addressable. virtio-blk
(`vblk_dma_buf`) and NVMe (`nvme_read_scratch`) bounce. USB mass storage now does too: `msc_blk_*` copy through
the row's data page (`msc_ensure_data_buf`, a pmm page whose phys the driver owns, reached through `dma_kva`), at
most one page per READ(10)/WRITE(10). The copy-out happens only after `msc_read_lba` succeeded, including its short-data-phase reject,
and a write runs `msc_settle` before its copy-in (a timed-out IN may still own the page). Until this cut,
`msc_blk_*` put `buf` itself in the bulk Normal TRB. It worked only for `.bss` callers.
Gate: `MSC_BOUNCE_SELFTEST` → `msc-cdb-smoke.sh` [bounce] (kmalloc / direct-map rows plus a `.bss` control).

**AHCI (1.57.10).** Until 1.57.10 `ahci_blk_read/_write/_read_sectors` → `ahci_issue_rw_inner` stored the caller's
`buf` in PRDT DBA, safe only because its callers passed `.bss` buffers (issue
2026-09-26-ahci-puts-the-caller-buffer-in-the-prdt). Now they bounce through one pmm page the driver owns
(`ahci_bb_phys` / `ahci_bb_kva`, allocated and iommu-registered once by `ahci_register_block_dev`), at most 8 sectors
per command, one `ahci_lock` hold per command (`ahci_bounce_rw`): `ahci_port_ready` (the 1.57.9 settle) runs before the
page is touched, a read pre-fills the page with the caller's bytes (swiotlb's rule: a "successful" short DMA must not
expose a previous transfer, and AHCI has no portable byte count, since some HBAs never update PRDBC), and the copy-out
happens only after the command completed. `ahci_read_lba`/`_write_lba` stay phys-taking primitives (demos, selftest).
Gate: the `AHCI_SELFTEST` `bounce` arm → `ahci-late-smoke.sh` (kmalloc / unaligned direct-map rows plus a `.bss`
control). Measured RED with the pre-fix blk layer restored: `bounce-kmalloc bad=512`, `bounce-sectors bad=8192`,
`bounce-write bad=4080` (err=0: QEMU took the VA as an unassigned phys), `bounce-bss` PASS. The dma-shadow `ahci` arm
now also covers the bounce page's CPU pointer: `ahci_bb_kva = phys` measured `dmash: ahci FAIL bad=576` and
`window FAIL dirty=512`.

## VT-d: the grant model (1.57.10)

`kernel/arch/x86_64/iommu.cyr` drives ONE Intel VT-d remapping unit. acpi.cyr picks it: the only DRHD whatever its flags
(QEMU q35's is scoped, flags 0), or the INCLUDE_PCI_ALL one when there are several — the scoped units (on Intel clients the
integrated GPU's) stay off; several scoped units and no catch-all leave VT-d off. Until 1.57.10 no boot had ever turned
translation on, QEMU's included (issue 2026-09-26-vt-d-xhci-never-granted-and-iommu-never-booted).

- **One domain, identity.** DID 1 (0 is reserved under Caching Mode), IOVA == phys, 2 MB second-level leaves (4 KB leaves
  where CAP.SLLPS has no 2 MB), 4-level tables when SAGAW offers 48-bit (else 3-level, else 5), intermediate tables made on
  demand. Every devfn on every bus pci_scan populated points at it, so requester-ID aliasing cannot miss. A device may DMA
  into a 2 MB region only if it is the first 16 MB (the kernel image and its `.bss` DMA buffers), a firmware RMRR, or a
  region a driver GRANTED — 2 MB granularity, so a grant opens its region's other pages too.
- **The rule for drivers:** every pmm page a device reads or writes is granted at allocation — `iommu_register_dma(phys)`,
  beside the `dma_kva(phys)` that gives the CPU its pointer. The device keeps getting the phys (the domain is identity).
  A `.bss` buffer inside the kernel image needs no grant. 1.57.10 added the grants virtio-blk, virtio-net and AHCI had
  never made; the virtio drivers accept `VIRTIO_F_ACCESS_PLATFORM` (the spec's SHOULD; QEMU refuses FEATURES_OK when a
  device offers it — `iommu_platform=on` — and the driver declines), and main.cyr now inits a pure-modern virtio-net.
- **Before `iommu_init`** (xHCI rings and contexts, HID, MSC — main.cyr brings the keyboard up first): a grant is recorded in
  `iommu_pend[]` (64 regions, dedup'd) and replayed into the tables before TE, under `iommu_lock` with the TE write, so no
  grant can fall between them. A grant that did not fit refuses translation (it would be a certain fault). Until 1.57.10
  these grants were silently dropped.
- **After TE:** a NEW leaf gets exactly the invalidation the unit needs — CM=1: a page-selective IOTLB invalidation of the
  2 MB range (AM 9, IH 0, which also drops cached non-leaf entries), domain-selective without PSI; CM=0: a write-buffer
  flush on RWBF hardware, otherwise nothing (Linux `cache_tag_flush_range_np`, FreeBSD `dmar_map_buf`, spec §6.1 / §6.8).
  Grants are never revoked, so no present→changed invalidation exists. `iommu_lock` (smp.cyr, IRQ-saved) covers the log,
  every table edit and the single-command invalidation registers; lock order iommu < pmm; nothing prints under it.
- **Bring-up** (`iommu_init`): turn off any TE / QIE firmware left on; tables (default 16 MB, RMRRs, per-bus contexts);
  RTADDR, SRTP, global context-cache then global IOTLB invalidation (register-based, CAIG / IAIG checked), write-buffer
  flush; replay + TE; PMRs off. GCMD is always written as `GSTS & 0x96FFFFFF | bit` (it is write-only). Any failure prints
  `iommu: translation NOT enabled - <reason>` and leaves translation off. VER major ≥ 6 is refused: register-based
  invalidation is an error there and queued invalidation is not implemented (issue 2026-09-26-vt-d-queued-invalidation).
- **Reporting:** `IOMMU: VT-d unit … levels= cm= … buses= rmrr= replayed= iotlb=` at enable, and — after every boot DMA user
  (main.cyr, after DHCP) — `IOMMU: boot DMA check - faults=N leaves= late= psi= dsi= wbf= inv_fail= refused=`, draining the
  unit's fault-recording registers (each fault printed as `iommu: FAULT dev bb:dd.f addr … reason …`). ext2's direct-to-
  caller DMA path stays off while `iommu_active` is set.

**The gate:** `scripts/smoke/vtd-smoke.sh` → `scripts/harness/vtd-iommu-test.py` (sweep row) boots a `VTD_SELFTEST`
kernel on q35 + `-device intel-iommu,intremap=off` twice: -smp 1 with caching-mode=on, aw-bits=39 (3-level, CM=1), and
-smp 4 with caching-mode=off, aw-bits=48 (4-level, the xHCI behind a pcie-root-port on bus 1). Typed agnsh lines over the
xHCI keyboard, a USB stick's and a SATA disk's LBA 0 byte-exact, agnsh loaded from NVMe, an exFAT mounted from virtio-blk,
DHCP over virtio-net and HDA's LPIB must all work under translation with `faults=0`; the selftest proves an ungranted page
is BLOCKED (untouched, the fault recorded against the NVMe) and that a grant after TE takes exactly the invalidation CM
needs; QEMU's own trace must show every device's DMA translated (`vtd_iotlb_page_update` per requester id), no fault but
the selftest's, GCMD written exactly SRTP then TE, and the IVA / IOTLB registers written exactly as CM dictates. ⚠ QEMU
never caches a failed translation, so a missing CM invalidation is invisible to its devices — the register trace is the
check that catches it.

## Status (1.57.10)

Converted: virtio-net/-blk, r8169, NVMe, AHCI, HDA and xHCI/HID/MSC DMA structures (1.57.8); fb_console's shadow,
the ramdisk and iommu.cyr's tables (1.57.9, above). This section read "xHCI/HID/MSC still on identity VAs" until the
1.57.9 merge, although 1.57.8 had converted them. AHCI's caller-buffer-in-PRDT closed in 1.57.10 (previous section):
no `*_blk_*` entry point puts a caller's CPU pointer in a descriptor any more. The one deliberate pass-through left is
NVMe's opt-in `blk_*_sectors_direct` path, whose callers must prove the buffer kernel-owned and identity-mapped
(`ext2_dma_direct_ok`, ext2.cyr's 1.56.51 gate); every other backend falls back to its bounce there.
