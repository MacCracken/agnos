# 2026-09-25 — block, USB and HDA drivers still reach their DMA structures through identity VAs of pmm pages

**Status:** ✅ **RESOLVED 1.57.8 (2026-09-25)**. Steps DMA1 (virtio-blk, NVMe, AHCI, HDA) and XHCI (xHCI, HID, MSC) moved every CPU load and store into a driver's pmm DMA structure onto the direct map, through `dma_kva` (renamed from `net_dma_kva` tree-wide at the merge). The physical value is kept only in descriptors, TRBs, contexts and registers. Gates: `scripts/smoke/dma-shadow-smoke.sh` (`DMA_SHADOW_SELFTEST`, plus a static grep half) and `scripts/smoke/xhci-shadow-smoke.sh` (`XHCI_SHADOW_SELFTEST`), both sweep rows at `-smp 1` and `-smp 4`. Built, gated, NOT burned. See § Resolution.
**Filed by:** agnos, from the 1.57.7 S4 step report (`s4_8b_dma_audit`).
**Checked against:** agnos **1.57.7**, the audit table below (line numbers from the S4 tree).
**Severity:** a ring-3-reachable wrong-memory access class, not observed to fail. The same class the 1.56.51 slab
banner in `heap.cyr` (~:52-69) and state.md's "Kernel structures are addressed through the DIRECT MAP" line describe.

## What happens

`pmm_alloc` draws from [0x400000, 0x10000000). A driver that stores the physical address of a DMA structure and
then dereferences that value as a CPU pointer relies on the identity map. Under a per-process CR3 that window can be
shadowed: a ring-3 ELF's PT_LOADs live in [0x400000, 0x10000000) too, and the loader writes their PDEs into that
process's page tables. A CPU access through the identity VA made under that CR3 (syscall-context block I/O, or an
ISR on whatever CR3 is live) then reads or writes the process's page instead of the DMA structure.

## The audit (S4.8b)

| driver | CPU-pointer sites | runs under a non-kernel CR3 |
|---|---|---|
| `virtio_blk.cyr` | setup :316-326 (p1..p3 identity-mapped, zeroed via phys); every desc/avail/used + request header/status access (~40 refs) | YES — block I/O from fs syscalls |
| `nvme.cyr` | admin asq/acq/ident :390-415, :468, :505, :538-606; I/O iosq/iocq/scratch/prp :676-700, :761, :787, :851; blk read/write bounce :1076-1095, :1149-1186; `nvme_rw_demo` :971-1024 (~74 refs) | YES for the I/O queues and the bounce; admin/identify/demo are boot-only |
| `ahci.cyr` | cl/fis :496-497, per-command ct/id :792-798, :1032, :1132, demo bufs :1211-1252 (~93 refs) | YES — command tables built from syscall block I/O |
| xHCI (`xhci_ring/cmd/ctx/port/xhci.cyr`) + `hid.cyr` | dcbaa, command ring, event ring, EP0/interrupt transfer rings, HID report buffers (~150 refs) | YES — `hid_poll` runs from the 0x51 MSI-X ISR and the BSP tick |
| `msc.cyr` | row table already direct-map; ring :494, cbw/csw :624-629, cr_buf :1160, data bufs :1330, :1921-1968 | YES — `msc_blk_*` from syscall block I/O |
| `hda.cyr` | PCM ring already `DIRECTMAP_BASE + phys` (:1594); BDL/CORB/RIRB not audited in detail | `hda_stream_service` runs from the BSP timer ISR — needs the detailed pass |
| `gpu.cyr` / `atom.cyr` | none: no `pmm_alloc` in gpu.cyr; `atom_work_va = DIRECTMAP_BASE + p` | n/a |

## The fix (1.57.8)

Convert every site that can run under a non-kernel CR3 to the direct-map alias (`net_dma_kva` at filing; renamed `dma_kva`
tree-wide at the 1.57.8 merge), driver by driver, the physical value kept only in descriptors and device
registers — the shape S4 used for virtio-net and r8169. One driver per bite; finish HDA's detailed audit first.

## Gate

Per driver: a grep gate that no `load*/store*` takes a `*_phys` value as its address (S4's §2.5 grep shape), plus
the driver's smokes (`msc-short`, `msc-cdb`, `hda`, `hda-dual`, `shutdown` 3 arms, `ext2-write`, the blk smokes) and
a ring-3 shadow test: a process whose PT_LOAD covers a pool page's identity VA does block I/O, and the transfer is
byte-exact (RED on the unconverted driver).

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S4-report.json` (`s4_8b_dma_audit`), `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S4.md` (N-6, E4).

## Resolution (1.57.8, 2026-09-25)

**What shipped:** the HDA audit came first. The BDL and PCM ring were already on the direct map; the CORB and RIRB
were not, and are now converted (`hda_corb_kva[]` / `hda_rirb_kva[]`). The other conversions:
- **virtio-blk**: desc, avail, used.
- **NVMe**: ASQ, ACQ, IDENTIFY, IOSQ, IOCQ, scratch and PRP list (`*_kva` twins).
- **AHCI**: `ahci_port_cl_kva[]`, plus per-command CT and IDENTIFY.
- **xHCI**: DCBAA, command, event and descriptor buffers (twins), the slot-table bases, input and device contexts, and
  the EP0 ring. `xhci_zero_page` and `xhci_dma_check` take a phys.
- **HID**: rings and report slots.
- **MSC**: bulk rings, CBW/CSW and the reply page.

TRB addresses matched against events stay physical. The gate is a CR3 whose PD[2..127] (the whole pmm identity window)
all map ONE 2 MB junk region. Under it, at IF=0, every driver's transfer must be byte-exact and the junk untouched.
Each converted site was mutation-proven RED except AHCI's command list alone, which is not discriminated under QEMU
(`docs/architecture/dma-cpu-pointers.md`). `hid_reclaim_selftest` moved after `cr3_load(0x1000)`. New doc:
`docs/architecture/dma-cpu-pointers.md`.

**What the change broke — checked before archiving:**
1. **A defect found and fixed.** virtio-blk's 2M-iteration polls (~20 ms under TCG) abandoned a slow FLUSH, whose late
   completion was then consumed by the next request (3 of 4 `-smp 1` runs). DMA1 fixed it: `vblk_wait` uses a
   wall-time budget and marks a timed-out request late, and `vblk_settle` reaps it before reuse. A request that never
   completes resets the device and takes it offline.
2. **Out of scope and filed, not fixed.**
   - MSC's `msc_blk_*` put the CALLER's buffer straight into a data TRB as a DMA address:
     `2026-09-25-msc-puts-the-caller-buffer-in-a-data-trb.md`.
   - CPU-only pmm buffers still on identity VAs (fb_console's `fb_shadow`, the `RAMDISK_ENABLE` pages, iommu's tables):
     `2026-09-25-cpu-only-pmm-buffers-still-use-identity-vas.md`.
   - AHCI's abandoned-command shape: `2026-09-25-ahci-timeout-abandons-an-in-flight-command.md`.
3. **Left as-is, boot-only.** `xhci_probe`'s CMOS page-table diagnostic still reads identity VAs; it runs under
   `0x1000` only.
4. **Selftest-only side effects.** `XHCI_SHADOW_SELFTEST` may take one of the two CMOS AS1/AS2 stamp slots, and
   `HID_RECLAIM_SELFTEST` compiles out of a `BOOTCR3_KEEP_GNOBOOT_CR3` build. Both happen in flag builds only.

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/DMA1-report.json`, `XHCI-report.json`, their `*-endreview.json`, `MERGE-report.json`; logs under `logs/DMA1/`, `logs/XHCI/`.
