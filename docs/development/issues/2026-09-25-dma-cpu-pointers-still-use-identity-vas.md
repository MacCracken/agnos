# 2026-09-25 — block, USB and HDA drivers still reach their DMA structures through identity VAs of pmm pages

**Status:** 🟡 **OPEN** — planned for **1.57.8**. 1.57.7's bite S4.8b (operator OQ-6) AUDITED this class and STOPPED
by its own rule (more than ~60 CPU-pointer sites; xHCI alone ~150 references); nothing was converted. The two NICs
(virtio-net, r8169) WERE converted in S4 and are not part of this issue.
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

Convert every site that can run under a non-kernel CR3 to the direct-map alias (`net_dma_kva`, renamed `dma_kva`
tree-wide once more than the NICs use it), driver by driver, the physical value kept only in descriptors and device
registers — the shape S4 used for virtio-net and r8169. One driver per bite; finish HDA's detailed audit first.

## Gate

Per driver: a grep gate that no `load*/store*` takes a `*_phys` value as its address (S4's §2.5 grep shape), plus
the driver's smokes (`msc-short`, `msc-cdb`, `hda`, `hda-dual`, `shutdown` 3 arms, `ext2-write`, the blk smokes) and
a ring-3 shadow test: a process whose PT_LOAD covers a pool page's identity VA does block I/O, and the transfer is
byte-exact (RED on the unconverted driver).

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S4-report.json` (`s4_8b_dma_audit`), `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S4.md` (N-6, E4).
