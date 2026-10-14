# The kernel image's ROOM — large module arrays live in a boot carve-out (1.57.12)

**Invariant.** The module arrays listed in `kernel/core/room.cyr` (`room_init`'s `room_take` lines) are NOT in the kernel
image. Each is a POINTER into one 2 MB pmm region carved at boot and reached only through the direct map; until the
carve-out the pointer holds a POISON value that faults, and the fault names the array. Nothing that runs before
`room_init()` may touch them, nothing may take their address (`&NAME`), and nothing may hand the region to a device.

## Why

The kernel image must end at or below `0x400000`, the top of region 1 — the LAST bound this layout allows (VA `0x400000`
is ring-3 code in every process, `pmm_init` reserves `[0, 4 MB)`, `sel_rip_is_kernel` treats `[0, 0x400000)` as kernel
RIPs; CLAUDE.md, `scripts/check/image-layout-check.sh`). The LOAD image's `memsz` counts `.bss`, and a module-scope
`var X[N]` is N u64 = 8N bytes of it whether or not it is ever written. After the ZFS writer's B7 review the binding
flag build (`ZFS_SELFTEST ZFS_WRITE_SELFTEST ZFS_WRITE_OPS`) had **60,216 B** left and `RING3_SELFTEST` 63,664 B, while
B8–B11 were estimated at ≈ 44 KB (up to 2× at the bites' measured overrun) with zstd to follow — and ~300 KB of `.bss`
was arrays nothing touches until long after the physical allocator is up. `CYRIUS_DCE` is not available (cycc bug,
filed: cyrius `issues/2026-10-10-agnos-kernel-dce-compaction-moves-data.md`, OPEN; from cyrius 6.6.20 — agnos's pin since
1.57.14 — REVBE-01 declines compaction on a `kernel;` image, so `CYRIUS_DCE=1` NOP-fills and shrinks nothing). Operator standing rule (2026-10-11), **grow before refactor**: never trim, `#ifdef`-out or dead-code-audit code
to make room; MOVE things.

## Prior art

- **Linux printk** (`kernel/printk/printk.c`): a static `__log_buf[__LOG_BUF_LEN]` takes the log from the first
  `printk`; `setup_log_buf()` later allocates the real buffer from memblock, copies what the static one holds under the
  log lock with IRQs off, switches the pointer and reports `log_buf_len: … bytes` / `early log buf free: …`. The klug
  ring below is that, step for step.
- **Linux boot-time tables**: large hashes and the per-CPU first chunk come from memblock at boot
  (`alloc_large_system_hash`, `pcpu_embed_first_chunk`), not from the image; `memblock_alloc` returns zeroed memory.
- **FreeBSD amd64**: the message buffer is carved off the top of physical memory in `getmemsize()` (`phys_avail` minus
  `round_page(msgbufsize)`) and reached through `PHYS_TO_DMAP` — the direct map, never a fixed or identity VA; early page
  tables come from `allocpages()` in `pmap_bootstrap`. `room_init` takes its region top-down from the pmm and reaches
  it through agnos's direct map for the same reason.
- **Linux `LIST_POISON1/2`** (`include/linux/poison.h`): "non-NULL pointers that will result in page faults under
  normal circumstances, used to verify that nobody uses non-initialized list entries". The room's pointers start as
  such poison — in the upper canonical half, so the fault is a #PF with the address in CR2 (Linux's
  `POISON_POINTER_DELTA` values are non-canonical on x86-64: a #GP, no address; agnos wants the name).
- **seL4** is the counter-example: a static kernel with no boot allocator at all. agnos already has the allocator
  (`pmm_alloc_2mb_run`) and the direct map, so the Linux/FreeBSD shape costs nothing new.
- **vidya** `allocators`: bump-allocate inside one region ("mmap(2MB) once, sub-allocate with bump") and round every
  allocation up to its alignment — `room_take` page-aligns each slot. `kernel_topics`: do not trust a global's initial
  value at boot — `room_take` refuses a pointer that is not its poison. `boot_and_startup`: `.bss` must be zero before
  use — the room is zeroed before any pointer into it is used.

## The mechanism (`kernel/core/room.cyr`)

1. **When.** `room_init()` is one top-level call in `main.cyr`, right AFTER `fb_shadow_init()`: past the first point
   where the direct map is live in kmain's context (after `cr3_load(0x1000)` and `pmm_bitmap_use_directmap()` —
   CLAUDE.md's `pmm_kva_for_access` note), long before `pci_scan`, the filesystems, the network or the first syscall,
   and on one CPU (the APs start at kmain's end). **After the console shadow, not before it** (the ROOM review,
   2026-10-12): `pmm_alloc_2mb_run` hands out the top-most free run below 256 MB; the shadow needs n CONTIGUOUS regions
   (8 on QEMU's 2048×2048 frame) and the room needs one, so a room taken first could split the only free run of n on
   fragmented iron and send the console to direct paint (the WC read-back on every scroll) behind one `fb: shadow alloc
   failed` line. Taken second it costs the room nothing. Nothing between the two calls touches a moved array; gate 34
   (10) holds the order (`pmm_bitmap_use_directmap();` < `fb_shadow_init();` < `room_init();` < the first `pci_scan();`).
   Until the review the call sat before `fb_shadow_init()`, and the QEMU boot showed it: the room at `0xFA00000`, the
   shadow pushed down one region to `0xEA00000`; now the shadow is `[0xEC00000, 0xFC00000)` and the room `0xEA00000`.
2. **Where.** `pmm_alloc_2mb_run(1)` — one 2 MB region, top-down below 256 MB (QEMU `-m 512M`: phys `0xEA00000`, under
   the console shadow's run). **When no 2 MB region below 256 MB is fully free** (fragmented low memory on iron, or a
   low pool the earlier carve-outs filled) the room searches **the whole live bitmap**, top-down
   (`pmm_alloc_2mb_run_under(1, pmm_2mb_top_region)`, pmm.cyr) and says so — `boot: room: no free 2 MB region below 256
   MB -- the carve-out came from the whole pmm bitmap (top-down)` (the second ROOM review, 2026-10-12). Until then it
   halted the boot there, while every other boot carve-out degrades instead (`fb_shadow` → direct paint, `kfont` → no
   `/fonts`, the chan band → `CH_E_NOREGION`); the room cannot degrade — its arrays have no other home — but it needs no
   identity VA, so the 256 MB ceiling (pmm.cyr calls it historical) bought it nothing. Top-down keeps it away from the
   low regions `sys_mmap`'s `pmm_alloc_2mb` scans first. A box whose bitmap never migrated (≤ 256 MB of RAM) searches
   the same 128 regions twice and halts by name (mechanism 7). The CPU pointer is `dma_kva(room_phys)` = `DIRECTMAP_BASE
   + phys`, asserted with `dma_kva_ok` (FreeBSD's `PHYS_TO_DMAP` KASSERT, as every stored-pointer site does since
   1.57.8) — that assert is what bounds a widened room to the installed direct map. A `BOOTCR3_KEEP_GNOBOOT_CR3` build is
   different, and weaker than the image was: § The KEEP_GNOBOOT build below.
3. **Layout.** Page 0 is a header (`ROOM_MAGIC` "GNOSROOM", phys, bytes used, slot count, a scratch word the dma-shadow
   selftest uses); each moved array gets a page-aligned slot after it, in `room_take` order. 1.57.12 uses `0x4B000` =
   307,200 B of the 2 MB (303,104 B of slots); the rest is free for the next array.
4. **Zero.** `memset(room_base, 0, room_used)` before any pointer is used — `.bss` was zero, so is the room.
5. **Pointers and poison.** A moved array is declared `var NAME = 0xFFFFA0SS00000000;` (slot `SS`): `ROOM_POISON` =
   `0xFFFFA00000000000` (PML4 entry `0x140`, upper canonical half) + `SS << 32`. No CR3 this kernel runs on maps the
   upper half — the firmware's and gnoboot's identity maps, agnos's 0x1000 tables, every per-process CR3 and the
   selftests' shadow CR3s use the lower half only (an identity map of physical addresses cannot reach it). Code writes
   `NAME + off` where it wrote `&NAME + off`. `room_take(&NAME, SS, size)` refuses a cell that does not hold its poison
   (written early, or a wrong initializer). Measured: cycc emits these constant initializers as file-resident data — all
   eleven poisons are in the plain image's `.bss` bytes.
6. **Use before the carve-out fails by name.** A moved array touched before `room_init` dereferences
   `ROOM_POISON + (SS << 32) + off`: a CPL0 #PF. The vector-14 stub now calls `exc_pf_report` (idt.cyr) for every
   CPL0 #PF — `PANIC: kernel page fault (#PF at CPL0) rip=… cr2=… err=…` on COM1, lock-free — and its `room_pf_say`
   decodes the slot from CR2: `PANIC: room: lo_ring used before the carve-out -- its pointer is still the poison
   (room_init, main.cyr) -- halting`. Until 1.57.12 a CPL0 #PF stamped CMOS and the framebuffer bar and halted with
   nothing on serial (the class 1.57.6's `exc_df_report` ended for #DF). Before `exc_handlers_init` no handler exists and
   a fault resets the box — nothing in the room can be used that early (the allocator is not up).
   ⚠ **By name on a CPU dereference only.** A poison handed to a DEVICE as an address is not a CPU access and faults
   nothing. The room is never a DMA address by rule; the one place a kernel pointer becomes a DMA address under a bound
   test is ext2's direct-DMA pair (`ext2.cyr`, `ext2_dma_direct_ok`), and every poison is a NEGATIVE i64 that its
   signed `(p & 0xFFF) == 0 && p + bs <= 0x10000000` would have admitted (page-aligned, far below the bound) and passed
   to the NVMe as a PRP — a silent bad DMA. Since the ROOM review both gates also require `p > 0`, so a poison (or any
   negative pointer) takes the CPU bounce path and faults by name there. Not reachable today — ext2 mounts long after
   `room_init` — but the invariant above is now the mechanism's, not an accident of ordering.
7. **Failure.** No free 2 MB region in the whole bitmap (`PANIC: room: no free 2 MB region in the whole pmm bitmap for
   the image carve-out -- halting`), a pointer outside the direct map, more than 2 MB of slots, a pointer that is not
   its poison: each prints its own `PANIC: room: …` line and halts. The moved arrays have no other home.
8. **Evidence on every boot.** `boot: room carve-out [0xea00000, 0xea4b000) at 0x20ea00000 -- 11 arrays, 300064 B moved
   out of the image (303104 B of page-rounded slots) OK` and `klug: log ring moved to the room carve-out (65536 B); the
   early ring held 1572 of 8192 B` (QEMU, plain, `-m 512M`). "Moved" is the arrays' DECLARED bytes (`room_moved`, the
   sum of the `room_take` sizes — the figure this doc and the CHANGELOG quote); the slots they occupy are page-rounded
   (`sec_wfile_buf`'s 17,440 B takes 20,480). Until the second ROOM review the line printed the slot figure as the moved
   one (`303104 B moved out of the image`); agnsh-smoke now checks all three numbers against `room.cyr`'s `room_take`
   lines.

### The klug ring — the one array split in two

The log ring is fed by `kprint` from the first line of kmain, long before the pmm, so it is split the Linux way:
`klug_early` (8 KB, image `.bss`) takes the boot log LINEARLY while `klug_early_mode` is 1 (a byte that does not fit is
counted in `klug_early_lost` and reported, never silently dropped); `room_init` points `klug_buf` at its 64 KB slot and
`klug_move_to_room` copies the early bytes to the head of the room ring under `klug_lock` (IRQ-saved), carries head and
count over and clears the mode. Every reader (dump, replay, spill, the `klug` syscall, `lifecycle_trace`) runs after it
and keeps the 64 KB geometry it always had. Measured: QEMU reaches the move with **1,573 B** written (plain, every
logged boot 1,560–1,575 B). An **iron** boot's pre-move log is **unmeasured** — the move's line reports the count and
any `B LOST`, and the first iron burn reads it (ZFS write spec § k.74 (g)); a flag build that runs selftests before
`room_init` was not measured either. agnsh-smoke requires the move's line, nothing lost. `klug-spill-smoke` (two sweep
rows since the review) is the byte-for-byte proof: the spill of the room ring, read back off the ext2 partition by the
host, matches the serial capture line for line — the copied early ring's lines named and counted (≥ 10 before the
move's own line; 31 on QEMU) — and its `KLUG_SPILL_WRAPTEST` row forces the room ring to wrap and requires a
chronological spill.

## Every CR3 sees the room (the audit)

The direct map is kernel PDPT[8 .. `directmap_pdpt_top`] (vmm.cyr `pmm_setup_directmap`); the room is in GB 0, i.e.
PDPT[8] → `dm_pd`, one page directory shared BY POINTER.

| CR3 | The direct map |
|---|---|
| gnoboot's boot CR3 (before `cr3_load(0x1000)`) | ABSENT — PDPT[8] maps an unrelated identity GB. Hence `room_init` after the switch; a use there hits the poison (named) |
| kernel `0x1000` (kmain after the switch, kthreads, idle) | present — `pmm_setup_directmap` writes PDPT[8+] at `0x2000` |
| every per-process CR3 | present — `proc_create_address_space` copies kernel PDPT[1..511] |
| the KPTI user CR3 | KPTI is collapsed: user == the per-process CR3 (syscall_hw.cyr `pcpu_kpti_*`) |
| the APs | `0x1000` from the trampoline (smp.cyr), then per-process CR3s |
| selftest CR3s (`dsh_build`, `xhci_shadow_selftest`, `userwin`, `dm_roundtrip_kernel_cr3`) | present — copies of the kernel's PML4/PDPT, or 0x1000 itself |

Ring 3 cannot name the room: `is_user_range` refuses direct-map VAs (the `userwin` selftest's `r_dmap` arm), ring-3
PT_LOADs stop below `0x10000000`, and the high mmap arena starts above `directmap_pdpt_top`. The identity VA of
`room_phys` is NOT the room under a per-process CR3 (PD[2..127] belong to the ring-3 image there), which is what the
dma-shadow selftest's `room` arm proves: under a CR3 whose whole pmm identity window is one 0xA5 region, the header and
`klug_buf` must read back and a word written there must land in the room (`dmash: room PASS`).

## The KEEP_GNOBOOT build (`BOOTCR3_KEEP_GNOBOOT_CR3=1`) — weaker than the image, and stated

The audit above is the default build's. In the legacy opt-out build that keeps kmain on gnoboot's boot CR3, kmain's
context has no direct map, so `dma_kva` returns phys and `room_init` (outside the `#ifndef`, because that build needs
the moved arrays too) places the room at its **identity VA** (QEMU: `0xec00000`). That is NOT the parity the image gave
these arrays: the image (PD[0..1]) is mapped the same way under every CR3, while the room's identity VA is
`proc_create_address_space`'s supervisor identity entry (`(hi * 0x200000) | 0x83`, PD[8..127]) only until the process's
own PT_LOADs override that slot (`elf.cyr` `proc_map_page`; the ELF loaders admit PT_LOADs up to `0x10000000`). The
moved arrays include syscall-path buffers — spawn's ELF staging, `gpu_op`'s staging, the FAT write-fd pool, and
`klug_buf`, which every `kprint` from a syscall and `fault_kill_current` write under the CALLER's CR3 — so a ring-3 image
with a PT_LOAD at the room's 2 MB slot would turn those accesses into accesses to the process's own page. `fb_shadow` has
the same shape there; the room raises the stakes because its arrays are on the syscall path. This is the hazard
`agnsh-smoke`'s VA check (≥ `0x200000000`) refuses in the default build, and why that check fails a KEEP boot by
construction (`agnsh-smoke` refuses a KEEP image outright unless `AGNSH_SMOKE_FLAGS=BOOTCR3_KEEP_GNOBOOT_CR3`).

**Booted once, the ROOM review (2026-10-12)** — `BOOTCR3_KEEP_GNOBOOT_CR3=1` (414,864 B of headroom) through
`AGNSH_SMOKE_FLAGS=BOOTCR3_KEEP_GNOBOOT_CR3 agnsh-smoke.sh`: the carve-out `[0xec00000, 0xec4b000) at 0xec00000`, the
klug move (1,406 of 8,192 B, nothing lost), every invariant line clean, the room VA check FAIL (by construction), and
**no ext2 mount — `kybernet: exec /bin/agnsh` → `emergency shell (exec rc=-1)`**. That last part is NOT the room's: the
pre-ROOM tree (the frozen merge base, built and booted the same way from a scratch copy) does exactly the same — no
`ext2: probe matched` line, exec rc=-1, the emergency shell. The KEEP build has not reached a mounted root since before
this step; when it broke is unmeasured. Whether to repair or retire the opt-out is an operator call (ZFS write spec
§ k.74 (k)); until then, treat its room as above. The widened search (mechanism 2) makes it weaker still there: a room
from above 256 MB is not the kernel's at its identity VA under a process's CR3 (below 1 GB that VA is PD[128..510], the
process's mmap arena), and `dma_kva_ok` is 1 in that build, so nothing refuses it.

## What moved, what stayed

Moved — 11 arrays, 300,064 B; every one first touched after `room_init`, CPU-only, needing no alignment beyond a page:

| slot | array | bytes | owner | first use |
|---|---|---|---|---|
| 1 | `pcpu_spawn_elf_buf` | 65,536 | syscall.cyr | spawn#3 (a syscall) |
| 2 | `klug_buf` | 65,536 | klug.cyr | the move (the 8 KB early ring before it) |
| 3 | `pci_bar_phys` | 49,152 | pci.cyr | `pci_scan` |
| 4 | `pci_devs` | 32,768 | pci.cyr | `pci_scan` |
| 5 | `pci_class` | 8,192 | pci.cyr | `pci_scan` |
| 6 | `pci_busfunc` | 8,192 | pci.cyr | `pci_scan` |
| 7 | `sec_wfile_buf` | 17,440 | vfs.cyr | a FAT/exFAT write fd |
| 8 | `pcpu_elf_hdr_buf` | 16,384 | elf.cyr | the first ELF load |
| 9 | `pcpu_sc_gpuop` | 16,384 | syscall.cyr | gpu_op#92 |
| 10 | `lo_ring` | 12,288 | net.cyr | the first loopback frame |
| 11 | `exfat_upcase_buf` | 8,192 | exfat.cyr | an exFAT mount |

The four PCI tables kept their declared sizes, each 8× its use (128 × 32 B = 4 KB of PciDevs in a `[4096]` u64, and so
on — the module-scope u64 unit read as bytes). That cost 84 KB of image until the move and costs RAM in the room now;
right-sizing them is a separate decision (open question in the ZFS write spec § k).

Stayed, with the reason:

| array | bytes | why it stays in the image |
|---|---|---|
| `bsp_boot_stack` | 65,536 | the shim's first instruction; a stack (red zone, the CR3 rule — kernel-stacks-and-preemption.md) |
| kashi `kashi_font9_16` / `kashi_font16` / `kashi_font8` | 12,656 | the console draws from line 1; declared in the sibling kashi repo. 101,248 B through kashi 1.1.0 (u64 slots holding bytes — 7/8 unused); kashi 1.1.1 declares them in slots (`[904]`/`[452]`/`[226]`, the issue agnos filed), taken at agnos 1.57.14: −88,584 B of image (cyrius 6.6.20) |
| `gpu_psp_ring` | 36,864 | DMA (the AMD PSP ring). The room is CPU-only; moving it means the driver's own pmm pages, `dma_kva` and an IOMMU grant (dma-cpu-pointers.md) on an iron-only path no QEMU smoke reaches |
| `idt` | 32,768 | `idt_init` runs long before the pmm |
| `vnet_rx_buf`, `vblk_dma_buf` | 24,576 + 4,096 | DMA, inside the default VT-d grant of the first 16 MB; the same driver conversion, later |
| `proc_table` | 22,528 | 94 sites on the scheduler / ISR hot paths for 22 KB; a candidate, not needed now |
| `pmm_bitmap` | 8,192 | the allocator itself |
| `fpu_state` | 8,208 | `fpu_area_init` runs before the pmm; XSAVE alignment |
| `kthread_stacks`, `sss_stacks` | 16,384, 49,152 | stacks (and flag builds only) |
| `spawn_parent_payload`, `spawn_path_parent_payload` | 32,768 each | `RING3_SELFTEST` test payloads (133 sites); that build is not the binding one |

## Headroom (gate 34: bytes from the LOAD end to `0x400000`; the same tree before and after, 2026-10-12)

| build | before | after the step | after its review | after its second review | gained |
|---|---|---|---|---|---|
| plain | 145,520 | 431,192 | 431,064 | **430,560** | +285,040 |
| `TEST KTEST` | 84,872 | 370,560 | 370,432 | **369,928** | +285,056 |
| `RING3_SELFTEST` | 63,664 | 349,336 | 349,208 | **348,704** | +285,040 |
| `KTEST THREAD_SELFTEST KSTACK_SELFTEST KSTACK_HW` | 84,272 | 369,944 | 369,816 | **369,312** | +285,040 |
| `ZFS_SELFTEST ZFS_WRITE_SELFTEST` | 101,216 | 386,896 | 386,752 | **386,264** | +285,048 |
| `ZFS_SELFTEST ZFS_WRITE_SELFTEST ZFS_WRITE_OPS` (binding) | 60,216 | 345,904 | 345,760 | **345,256** | +285,040 |
| `EDGE_ABI_SELFTEST` | 81,576 | 367,264 | 367,120 | **366,616** | +285,040 |
| `BOOTCR3_KEEP_GNOBOOT_CR3` | — | 414,992 | 414,864 | **414,360** | — |
| `KLUG_SPILL_SELFTEST` (+ `KLUG_SPILL_WRAPTEST`) | — | — | 430,944 (430,392) | **430,440 (429,888)** | — |

The review's fixes cost 128–144 B per build (the two ext2 `p > 0` tests; the call move and the klug change are free);
the second review's 488–504 B (the whole-bitmap fallback — `pmm_alloc_2mb_run_under` and its call — the `room_moved` /
`room_wide` cells and the boot line's two new literals).
Plain image after the step: `.bss` −291,728 B (300,064 moved; the 8 KB early klug ring and the new pointer / state
cells back in), `.text` +5,168 B (each `&NAME` became a pointer load; `room.cyr`; the klug early path; the #PF report),
`.rodata` +894 B. The live numbers are `docs/development/state.md`'s.

## How to move one more array

Only an array first touched after `room_init`, CPU-only (never a DMA address), and not a stack:
1. add `room_take(&NAME, <next slot>, <its bytes>);` to `room_init`, and `if (slot == N) { serial_print("NAME", len);
   return 1; }` to `room_say`;
2. replace `var NAME[N];` with `var NAME = 0x<ROOM_POISON + (slot << 32)>;` and every `&NAME` with `NAME`;
3. build — `image-layout-check.sh` (10) checks the slot, the poison, the name, that no `&NAME` is left in `kernel/`
   (outside `arch/aarch64/`) and that the array is not declared back, and `build.sh` REFUSES an image that fails it,
   plain builds included (moved to `build/agnos.layout-refused`; the second ROOM review) — then boot `agnsh-smoke` (the
   carve-out line, whose counts it checks against `room_take`) and the smoke that owns the array. The region has
   ~1.7 MB free; `room_init` halts by name past 2 MB.

`aarch64`: `room.cyr` is in `agnos.cyr`'s x86_64 block only; the shared files' pointers (`klug_buf`, `sec_wfile_buf`)
stay their poison there and klug stays in its early ring. The aarch64 build did not link when the room landed (32
undefined functions, 17 undefined variables — unchanged by the room); it compiles and links since 1.57.13
(`arch/aarch64/stubs.cyr`), still with no `room_init` — nothing boots it — so the poison note stands. An aarch64
`room_init` belongs to the 1.6x port.

## What the room changed elsewhere: ext2's direct DMA

`ext2_write_at_dma` (and with it the 1.47.7 coalesced direct-DMA write, `blk_write_sectors_direct`) has **no caller**
since the room. klug's spill was the only one; `klug_buf` is now a direct-map VA (~8 GB + phys) that the gate's
identity bound (`p + bs <= 0x10000000`) never admits, so the spill and its 64 KB prealloc took the single-block bounce
path (16 block writes each) from the room's first boot — and since the room is CPU-only by rule, klug now calls plain
`ext2_write_at` and does not opt in at all (klug.cyr). Before the room the path was luck, not design: cycc's `.bss`
has alignment 1, so a page-aligned `&klug_buf` was the layout of the day. The read side lost its main caller earlier,
at 1.56.39, when `pmm_kva_for_access` became the direct map for every phys: ELF segment loads have not been coalesced
since; what still passes is a page-aligned identity buffer below 256 MB (the GPU firmware loads, iron only; main.cyr's
`vfs_scratch_buf` selftests). The code is kept, not deleted (no dead-code removal before the rewrite); coalescing
exec loads again means a direct-map VA → phys step inside that security gate while refusing the room — ZFS write spec
§ k.74 (i).

## Gates

- `scripts/check/image-layout-check.sh` (10) — check.sh gate 34, `build.sh` after every x86_64 build, CI: the source
  contract above, including the call order `pmm_bitmap_use_directmap();` < `fb_shadow_init();` < `room_init();` <
  the first `pci_scan();`; (1)'s failure text now says grow the room, not shrink the image. ⭐ Since the second ROOM
  review `build.sh` refuses a PLAIN image that fails (10) — or any check but the bound itself — exactly like a flag
  build (moved to `build/agnos.layout-refused`, exit 1); until then a plain build only warned, left the image in
  `build/agnos`, and every plain smoke booted it (mutation M6 built "plain: warns"). check.sh gate 34 scores the refused
  image (`REFUSED:` + the FAIL block). A plain image that is only over the bound stays for gate 34, recorded
  `layout=over-bound` in `build/agnos.flags`, and `smoke_require_image` refuses any `layout=` but `pass`.
- `scripts/smoke/agnsh-smoke.sh` — requires the carve-out line with its VA in the direct map (≥ `0x200000000`; mutation
  M3 below is why), its array count, moved bytes and slot bytes equal to `room.cyr`'s `room_take` lines (the second
  ROOM review; N6), and the klug move with nothing lost and something moved (`held [1-9]…`, MR3) — a count, not the
  bytes: those are klug-spill-smoke's.
- `scripts/smoke/klug-spill-smoke.sh` — two sweep rows since the ROOM review (it had none since 1.56.10): the room ring
  spilled to ext2 and compared with serial line for line, the moved early ring named and counted; and the wrapped
  ring spilled chronologically (`KLUG_SPILL_WRAPTEST`). It retries a firmware VOID now (`qemu_dwell_kernel`).
- `SMOKE_INVARIANT_DENY` (`scripts/smoke/lib/qemu-dwell.sh`) — `PANIC: kernel page fault`, `PANIC: room`. ⚠ Applied by
  31 of the 67 smoke scripts the sweep's rows name, not all of them (the second ROOM review counted): among the 36
  that do not are rows that own a moved array — exFAT read / write, FAT write, klug spill, the #92 ABI battery,
  ktest-smoke, FS syscalls, the ext2 probe — and fault-kill, the one row that drives the #PF stub's CPL3 arm. A moved
  array used before the carve-out still fails those rows by their own markers: `room_init` runs on the BSP at kmain's
  start and the APs wake at its end, so the poison halts the BSP and the boot. What they would not see is a CPL0 #PF
  on an AP (`cli; hlt` halts that AP only) — its line would sit in their log unread.
- `scripts/smoke/dma-shadow-smoke.sh` — `dmash: room PASS` (the per-process-CR3 property), and `room.cyr` in its static
  `*_phys` grep.

## Mutation record (2026-10-12)

(Addresses in this record are from the tree before the review moved `room_init` after `fb_shadow_init`: the room was
at phys `0xFA00000` then, `0xEA00000` now. The mechanisms each row exercises did not change.)

Run on a scratch copy of the tree (an rsync of the worktree, `kernel/` identical): each mutation applied with
`cyim --replace-files --expect-1`, built, booted where the mechanism is a runtime one, then reverted the same way — the
file's md5 after equals its md5 before and the worktree's (all ten). Every row RED:

| # | mutation | mechanism | caught by | evidence |
|---|---|---|---|---|
| M1a | `store8(lo_ring, 1);` right before `room_init();` (kernel CR3) | poison → named #PF | agnsh-smoke FAIL (deny + both room lines missing) | `PANIC: kernel page fault (#PF at CPL0) rip=0x…2894a6 cr2=0xffffa00a00000000 err=0x…2` · `PANIC: room: lo_ring used before the carve-out -- its pointer is still the poison (room_init, main.cyr) -- halting` |
| M1b | `pci_count = load64(pci_devs + 8);` before `cr3_load(0x1000)` (gnoboot's CR3) | poison → named #PF, before the switch | agnsh-smoke FAIL | `cr2=0xffffa00400000008` · `PANIC: room: pci_devs used before the carve-out …`; no `kernel CR3: own PML4` line before it |
| M2 | `var ri_kva = room_phys;` (the identity VA, `dma_kva` dropped) | the direct-map assert | agnsh-smoke FAIL | `PANIC: room: the carve-out pointer 0x000000000fa00000 is not in the direct map -- a per-process CR3 would not see it -- halting` |
| M3 | `room_base = room_phys;` AFTER the assert (identity VA) | the per-process-CR3 property | dma-shadow-smoke FAIL; agnsh-smoke FAIL — but only since its direct-map VA check | `dmash: room FAIL bad=15001` (header 1000 + phys 2000 + `klug_buf` 8000 + scratch 4000 + 1 dirty word) · `dmash: window FAIL dirty=1 (… room 1)`. ⚠ agnsh-smoke first PASSED this mutant (`… at 0xfa00000 …`): under the processes it runs, PD[125] is still identity — the latent hazard dma-cpu-pointers.md describes. It now requires the line's VA ≥ `0x200000000`: `FAIL: the room carve-out is reached at 0xfa00000 — not the direct map` |
| M4 | `room_phys = 0;` | allocation failure | agnsh-smoke FAIL (before the second review; the same mutant is N2a since — the fallback) | `PANIC: room: no free 2 MB region for the image carve-out (pmm_alloc_2mb_run) -- halting` |
| M5 | `var pci_class[1024];` back in pci.cyr | gate 34 (10) | plain build: the FAIL block + `WARNING: this PLAIN image fails the image-layout gate` (LOAD end `0x398ba8`, +8 KB); `RING3_SELFTEST=1` build REFUSED (rc 1, `build/agnos.layout-refused`) | `FAIL: (10) pci_class is back: kernel/core/pci.cyr:33 \`var pci_class[1024];\` — it is ROOM slot 5 …` |
| M6 | `&lo_ring + lo_tail * 1536` in net.cyr | gate 34 (10) | build warns, gate rc 1 | `FAIL: (10) \`&lo_ring\` at core/net.cyr:333 — lo_ring is a POINTER since it moved to the room …` |
| M7 | exfat_upcase_buf's poison `0xFFFFA00C00000000` (slot 12's) | gate 34 (10) + `room_take` | gate rc 1; booted: agnsh-smoke FAIL | `FAIL: (10) kernel/core/exfat.cyr:513 declares exfat_upcase_buf = 0xFFFFA00C00000000 — ROOM slot 11's poison is 0xFFFFA00B00000000 …` · `PANIC: room: exfat_upcase_buf pointer is 0xffffa00c00000000, not its poison, before the carve-out …` |
| M8 | the #PF stub takes `&exc_df_report` | gate 34 (10) | gate rc 1 | `FAIL: (10) idt.cyr: the #PF stub must call exc_pf_report …` |
| M9 | the early klug ring cut to 1 KB (`klug_head < 1024`) | the early ring's loss accounting | agnsh-smoke FAIL | `klug: log ring moved to the room carve-out (65536 B); the early ring held 1024 of 8192 B -- 549 B LOST (the early ring was full)` |
| MR1 | (review) `room_init();` moved back before `fb_shadow_init();` | gate 34 (10) order | gate rc 1 | `FAIL: (10) main.cyr: room_init(); must come after pmm_bitmap_use_directmap(); … and after fb_shadow_init(); (the console shadow takes its contiguous run first; the room must not split it), and before the first top-level pci_scan(); …` (backticks dropped here) |
| MR2 | (review) `room_init();` moved after `pci_scan();` | gate 34 (10) order | gate rc 1 | the same FAIL line |
| MR3 | (review) `klug_move_to_room` moves 0 B (`var km_n = 0;`) | the moved ring, byte for byte | klug-spill-smoke (linear row) 6 / 2 | `FAIL: the early ring is not in the spill as moved (move line seen=1, 0 matched line(s) before it, need >= 10)` + the banner FAIL; the line-agreement check alone PASSED (62 compared), and agnsh-smoke's `held [0-9]+` would have — it requires `held [1-9]…` since |
| N1a | (second review) M6 again — `&lo_ring + lo_tail * 1536` — on a PLAIN build | build.sh's refusal | `build.sh` rc 1, image moved to `build/agnos.layout-refused` (was: warns, image left in `build/agnos`) | `ERROR: this PLAIN image fails a source/image CONTRACT of the image-layout gate …` after the (10) FAIL; the gate's "no \`&NAME\` left" summary is no longer printed above it (it was — fixed on the way) |
| N1b | (second review) N1a's tree through `check.sh` | gate 34 scores the refused image | 33 / 5: x86_64 build, arity (VACUOUS), test suite, binary size (VACUOUS) and gate 34 | `REFUSED: build.sh refused this run's plain image (a layout contract FAIL) — the gate's verdict on build/agnos.layout-refused:` + the (10) FAIL line |
| N1c | (second review) `var mut_big[56000];` (448,000 B of `.bss`) in net.cyr, plain — over the bound, nothing else | the warn-only bound path, then the provenance refusal | `build.sh` rc 0 with `WARNING: … over the region-1 bound … recorded layout=over-bound`; agnsh, console-line, ext2, hda and shutdown smokes all REFUSED it | `REFUSED: …/build/agnos's image-layout verdict is 'over-bound', not 'pass'` (LOAD end `0x404420`) |
| N2a | (second review) `room_phys = 0;` in place of the first search (= M4) | the whole-bitmap fallback | GREEN as intended: agnsh-smoke PASS — the boot runs to agnsh on a room above 256 MB | `boot: room: no free 2 MB region below 256 MB -- the carve-out came from the whole pmm bitmap (top-down)` · `boot: room carve-out [0x1dc00000, 0x1dc4b000) at 0x21dc00000 -- 11 arrays, 300064 B …` |
| N2a-dsh | (second review) N2a as a `DMA_SHADOW_SELFTEST RAMDISK_ENABLE` build | the widened room under a shadowed-identity CR3 | GREEN as intended: dma-shadow-smoke PASS, -smp 1 and 4 | room at `0x1da00000`; `dmash: room PASS bad=0`, `dmash: window PASS dirty=0 (… room 0)` both boots |
| N2b | (second review) both searches return 0 | the halt, by name | agnsh-smoke FAIL | `PANIC: room: no free 2 MB region in the whole pmm bitmap for the image carve-out -- halting` |
| N6 | (second review) `room_moved` not accumulated | the boot line's moved figure vs the source | agnsh-smoke FAIL | `… -- 11 arrays, 0 B moved out of the image (303104 B of page-rounded slots) OK` → `FAIL: the carve-out line says arrays / moved / slot bytes '11 0 303104', room.cyr's room_take lines say '11 300064 303104'` |

GREEN on the tree as shipped: check.sh 38/38, test.sh 4/4, agnsh-smoke (both room lines, the VA check), `ktest.sh` (plain
367/370 — the documented three initrd checks; `KTEST=1` 372/372 and 13/13 boot self-tests), and 30 sweep rows run with
`SWEEP_JOBS=1 SWEEP_ONLY=…` — every row that owns a moved array or a binding build: ktest-smoke (-smp 1 + 4), FAT write,
exFAT read / write, FAT/exFAT chain-cycle, ZFS read + write gate, **ZFS write (the binding `ZFS_WRITE_OPS` build: 16
lanes, 7 rw pools accepted by OpenZFS)**, ZFS ring 3, AP stacks, spawn, lifecycle, virtio-net under KVM, TCP hermetic,
loopback, tcp_listen, inbound TCP, socket ownership, sock / icmp waits, ICMP echo, exec_redirect, FS syscalls,
exec-from-disk, ring-3 procs (`RING3_SELFTEST`), kstack (-smp 1 + 4), fg default, DMA shadow (`dmash: room PASS`,
`window … room 0`, -smp 1 + 4), VT-d, kernel threads, #92 ABI battery (`EDGE_ABI_SELFTEST`), HDA — 30 passed, 0 failed.

GREEN after the review's fixes (2026-10-12; `room_init` after `fb_shadow_init`, klug off the DMA opt-in, ext2's
`p > 0`, the klug-spill rows): check.sh 38/38, test.sh 4/4, `ktest.sh` plain 367/370 (the same three initrd checks),
agnsh-smoke (carve-out `[0xea00000, 0xea4b000) at 0x20ea00000`, the move 1,573 / 1,572 B over two boots), and 21 sweep rows serially
(`SWEEP_JOBS=1 SWEEP_ONLY`, 921 s): ktest-smoke, FAT write, exFAT read / write, chain-cycle, AP stacks, spawn, virtio-net
under KVM, loopback, exec_redirect, ext2 WRITE, **klug spill (8/8: 93 lines compared, 31 of them the moved early ring)
and klug spill wrapped (7/7)**, the ext2 multi-backend probe, FS syscalls, exec-from-disk, kstack, fg default, DMA shadow
(`dmash: room PASS`, -smp 1 + 4), VT-d, HDA — 21 passed. MR1–MR3 RED and restored md5-identical. The KEEP build: §
The KEEP_GNOBOOT build. (That run left out the ZFS rows, lifecycle, the TCP / socket / ICMP rows, ring-3, threads, the
#92 ABI battery and fault-kill; the second review ran the ABI battery, TCP hermetic, fault-kill and fg recovery on that
source — all PASS.)

GREEN after the second review's fixes (2026-10-12; the whole-bitmap fallback, the boot line's two figures, build.sh's
plain refusal, `smoke_require_image`'s `layout=`): N1a–N6 above as recorded; check.sh 38/38, test.sh 4/4, agnsh-smoke
(`… -- 11 arrays, 300064 B moved out of the image (303104 B of page-rounded slots) OK`, counts equal to `room_take`'s),
`ktest.sh` plain 367/370 (the same three initrd checks), `KTEST=1 ktest.sh` 372/372, and 33 sweep rows serially
(`SWEEP_JOBS=1 SWEEP_ONLY`, 6,103 s of rows) — the 21 and the first 30 except tcp_listen and inbound TCP (host-port rows,
not run beside the parallel tracks), socket ownership, sock / icmp waits and ICMP echo, plus fault-kill, the
kernel-embedded face, console live line and shutdown: ktest-smoke, FAT write, exFAT read / write, chain-cycle, the ZFS
read + write gate (8/8), **ZFS write on the binding build (16/16 lanes, 7/7 rw pools accepted by OpenZFS)**, ZFS ring 3, AP stacks, spawn,
lifecycle, virtio-net under KVM, TCP hermetic (62/62), loopback, exec_redirect, ext2 WRITE, klug spill (8/8, 93
compared) and wrapped (7/7), the ext2 probe, FS syscalls, exec-from-disk, fault-kill, ring-3 procs, kstack, fg default,
DMA shadow (`dmash: room PASS` -smp 1 + 4), VT-d, kernel threads, the #92 ABI battery, HDA — 33 passed, 0 failed.
