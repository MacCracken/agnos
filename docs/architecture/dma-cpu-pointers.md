# DMA CPU pointers — the direct map, never phys == VA (1.57.8)

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

## The gate

`DMA_SHADOW_SELFTEST=1` → `scripts/smoke/dma-shadow-smoke.sh` (sweep row). A static half greps the four drivers for
`(load|store)N(<name>_phys` and must find nothing. The boot half (`core/selftests.cyr`) builds a CR3 that is a copy
of the kernel's with PD[2..127] all pointing at ONE 2 MB region of 0xA5 — the worst a PT_LOAD over the window can
do, with supervisor PDEs so an identity access lands silently instead of faulting — and, IF=0 under it, runs every
block backend (1 + 8 sectors + FLUSH, NVMe's 24-sector PRP-list path) and two HDA verbs. `dmash: shadow PASS` is the
self-check that the window really is shadowed. Measured RED per driver by reverting its `dma_kva` at the
allocation site (1.57.8 DMA1): virtio `bad=31576`, nvme `bad=31576` (5 s timeout, then the controller disabled),
nvme-prp `bad=4536`, hda `shadowed=0`, ahci (CT) `bad=16576`. ⚠ The AHCI **command list** alone is not
discriminated: slot 0's header is nearly constant across commands (CFL=5, PRDTL=1, same CTBA), so a stale header
from the previous command still works under QEMU. It is converted all the same.

## Still on identity VAs (not this rule's drivers yet)

xHCI/HID (`arch/x86_64/usb/xhci_*.cyr`, `hid.cyr`) and USB mass storage (`msc.cyr` rings, CBW/CSW, data buffers)
— issue 2026-09-25-dma-cpu-pointers-still-use-identity-vas, another track. Also the framebuffer shadow
(`fb_shadow_init` → `pmm_alloc_2mb_run`, written phys == VA from the syscall-path `fb_putc` under per-process
CR3s — `pmm.cyr`'s comment above `pmm_alloc_2mb_run` states the assumption).
