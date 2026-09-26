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
  ahci `ahci_port_cl_kva[]`, per-call `ct_kva`/`id_kva`, demo `dk`/`dk2`; hda `hda_corb_kva[]`, `hda_rirb_kva[]`
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
- **iommu.cyr's tables** (Linux `intel-iommu` shape): `iommu_root_phys/_kva`, `iommu_ctx_phys/_kva`,
  `iommu_l2_phys/_kva`. The phys goes only into RTADDR, root entry [0]'s context pointer and the context entry's ASR;
  every memset/store uses the KVA. `iommu_map_mmio` walks to the PD with `dma_kva(pdpte & mask)` (Linux
  `pmd_page_vaddr`) and puts only a new PD's phys into the PDPT. **CR3 audit:** every writer runs at boot on 0x1000
  before any per-proc CR3 or AP (`iommu_init`; `iommu_register_dma` from `xhci_rings_init` is a no-op because it runs
  before `iommu_init`, and from `r8169_init_rx/tx` after it) — safe by call-site placement until 1.57.9, safe by
  construction now. Also fixed there: `ECAP.C` (hardware walk snoops CPU caches) is read before the first table write,
  and on non-coherent hardware every table write is clflushed (`iommu_flush_cache`, Linux `__iommu_flush_cache`).

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
`fb_shadow_init();` to be called once, after `pmm_bitmap_use_directmap();`. iommu.cyr's gate is that static half only:
its writers never run under a per-proc CR3 and no smoke publishes a DMAR (QEMU q35 `-device intel-iommu` would — a
possible follow-up smoke). The boot half (`core/selftests.cyr`) builds a CR3 that is a copy
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
⚠ **AHCI still has this defect:** `ahci_blk_read/_write/_read_sectors` → `ahci_issue_rw_inner` store the caller's
`buf` in PRDT DBA. It is safe today only because its callers pass `.bss` buffers.

## Status (1.57.9)

Converted: virtio-net/-blk, r8169, NVMe, AHCI, HDA and xHCI/HID/MSC DMA structures (1.57.8); fb_console's shadow,
the ramdisk and iommu.cyr's tables (1.57.9, above). This section read "xHCI/HID/MSC still on identity VAs" until the
1.57.9 merge, although 1.57.8 had converted them. Still open: AHCI's caller-buffer-in-PRDT (previous section).
