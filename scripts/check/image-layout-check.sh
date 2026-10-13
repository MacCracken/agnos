#!/bin/sh
# image-layout-check.sh — the kernel image vs the top of region 1: LOAD end <= 0x400000 (1.57.12; the BSP boot
# stack's budget before that — 0x3D0000 at 1.57.11, 0x390000 at 1.57.7-1.57.10, 0x370000 before).
#
# Usage: sh scripts/check/image-layout-check.sh [IMAGE]          the gate (default build/agnos)
#        sh scripts/check/image-layout-check.sh --bsp-stack-span IMAGE
#                                                               prints "0xLO 0xHI", the BSP boot stack's span in
#                                                               IMAGE, decoded from the shim's bytes (rbp-repro.sh)
#
# ⭐⭐⭐ 1.57.12 — THE BSP STACKS LEFT REGION 1, AND THE BOUND IS THE TOP OF REGION 1. Operator ruling (2026-10-10):
# the ZFS write path needs ~170 KB more than the binding flag build had left, compiler DCE is blocked on a cyrius
# bug, so make room by moving the BSP stacks out of region 1. Until 1.57.12 three fixed windows sat above the
# image — the BSP boot stack [0x3D0000, 0x3E0000), a 64 KB guard gap, the BSP TSS.RSP0 window [0x3F0000,
# 0x400000) — and this gate held the image under the boot stack's 64 KB budget. Now:
#   · the BSP BOOT STACK is a 64 KB array in the image's own .bss (boot_shim.cyr `var bsp_boot_stack[8192]`). The
#     shim loads its address through one top-level statement (raw bytes cannot name a symbol) and turns it into
#     the 16-byte-aligned top in the asm block after it. It moves with the image; there is no number to re-pick.
#     gnoboot pins the whole image (AllocateAddress, EfiLoaderCode) and zeroes .bss, so the stack is
#     loader-owned memory from instruction one — the old window was free only because the FIRMWARE left it so.
#   · the BSP TSS.RSP0 is region-7 slot 0 [0xFC0000, 0xFD0000) through the direct map (gdt.cyr
#     tss_get_cpu_stack, now one formula for every CPU; proc.cyr proc_rsp0_top falls back to
#     tss_get_cpu_stack(0)). The slot had been reserved and unused since 1.57.3 and already had its guard page.
#   · so region 1 [0x200000, 0x400000) holds only the image, and LOAD end <= 0x400000 = REGION1_TOP. That is the
#     LAST bound this layout allows, not a number to raise: in every per-process CR3 VA 0x400000 (PD[2]) is
#     ring-3 code (ring3.cyr code_va; every agnos ELF links there and the ELF loaders refuse anything below it —
#     "PD[1] is not userspace"), pmm_init reserves exactly [0, 4 MB) for the kernel, and sel_rip_is_kernel
#     (sched.cyr) treats [0, 0x400000) as kernel RIPs. Growing past it needs an architectural change (a
#     higher-half kernel, or a higher user link base), not an edit here.
#   Gain: the old bound was 0x3D0000; the new one is 0x30000 (192 KB) higher, minus the 64 KB stack that now counts
#   inside the image (and ~3 KB of boot-evidence and red-zone code): +127,992 B on the plain build. Measured headroom:
#   CHANGELOG 1.57.12.
#   PRIOR ART: Linux x86_64 (head_64.S startup_64 `leaq __top_init_kernel_stack(%rip), %rsp` — init_stack is
#   INIT_TASK_DATA inside .data, vmlinux.lds.S), FreeBSD amd64 (locore.S `movq $bootstack,%rsp`, bootstack in
#   .bss, then thread0's stack), seL4 x86_64 (head.S boot_stack_top in .phys.bss, then kernel_stack_alloc in .bss)
#   and vidya boot_and_startup ("Allocate a static boot stack in the kernel's .bss section (e.g., 64KB)") all make
#   the first stack an IMAGE SYMBOL. agnos re-picked a fixed number above the image end five times instead.
#   The alternatives weighed (a fixed window elsewhere, cycc's 64 KB zero-fill tail as the stack, FreeBSD's second
#   switch onto a guarded region-7 stack once the direct map exists) are in docs/architecture/
#   kernel-stacks-and-preemption.md § "Region 1"; the last is a possible later step on top of this one.
#
# WHAT IT ASSERTS (1.57.12):
#   (1) the image (`build/agnos`, the ELF64 gnoboot loads) is ONE flat PT_LOAD, file offset 0 -> VA 0x100000, and
#       its LOAD end (p_vaddr + p_memsz; memsz = filesz + cycc's 64 KB zero-fill, and it counts) <= REGION1_TOP.
#   (2) the ELF64 shim's stack load, decoded from the IMAGE: right after the CMOS checkpoint-1 stamp
#       (B0 50 E6 70 B0 01 E6 71) .text carries exactly one
#           48 B8 imm64     movabs rax, &bsp_boot_stack       (the statement `bsp_boot_stack_lo = &bsp_boot_stack;`)
#           48 B9 imm64     movabs rcx, &bsp_boot_stack_lo
#           48 89 01        mov [rcx], rax
#           48 05 imm32     add rax, BSP_BOOT_STACK_SIZE      (the asm block, boot_shim.cyr)
#           48 83 E0 F0     and rax, -16
#           48 89 C4        mov rsp, rax
#           48 89 E5        mov rbp, rsp
#       with imm32 == BSP_BOOT_STACK_SIZE, [imm64, imm64 + size) inside .bss, the stored-to cell (48 B9) exactly
#       imm64 + size — bsp_boot_stack_lo is declared right after the array, so this ties imm64 to bsp_boot_stack
#       itself rather than to any .bss symbol with 64 KB of .bss above it (review fix) — the stack-switch tail
#       occurring nowhere else in .text, and the aligned top losing < 16 B. Anything cycc emits between the
#       statement and the asm block (RAX would no longer be the address) breaks the match and fails the build.
#   (3) the same thing in the SOURCE: exactly one `var bsp_boot_stack[N];` in boot_shim.cyr with 8 x N ==
#       BSP_BOOT_STACK_SIZE (a module-scope `var x[N]` is N u64), exactly one `bsp_boot_stack_lo =
#       &bsp_boot_stack;`, each of the four raw-byte lines present once with a comment that says what its bytes
#       do (the add's decoded immediate == the size); and NOWHERE in kernel/ (review fix: this was boot_shim.cyr
#       only) a byte line that starts `mov esp/rsp, imm` (BC, REX-with-B-clear + BC, 48 C7 C4) or an asm mnemonic
#       `mov rsp|esp, <number>` — no fixed stack immediate may come back, in any file.
#   (4) no `mov rsp, imm64` (48 BC), `mov esp, imm32` (BC) or `mov rsp, simm32` (48 C7 C4) in .text loads a value
#       in [0x100000, 0x400000] — the image and region 1 (review fix: this matched only 64 KB-ALIGNED 48 BC
#       values in [0x200000, 0x400000], so `mov rsp, 0x3DFFF0` passed). A byte scan: zero hits in all 38 builds.
#   (5) the BSP TSS.RSP0 sites: gdt.cyr tss_get_cpu_stack is the one region-7 formula `return DIRECTMAP_BASE +
#       0xFD0000 + cpu_id * 0x10000;` with no BSP special case, no `var tss_kernel_stack` remains in gdt.cyr, and
#       proc.cyr proc_rsp0_top's unassigned-slot fallback is `tss_get_cpu_stack(0)` (cpu 0's slot — never the
#       calling CPU's, whose slot may be an AP's live boot/idle stack). 0xFD0000 is the top of BSP_RSP0_SLOT.
#   (6) the boot evidence names the spans this map uses: main.cyr checks the image span from 0x100000 (= p_vaddr)
#       in mode 1 (loader-pinned) and prints the `boot: BSP boot stack [...) inside the loader-pinned image
#       (EfiLoaderCode) OK` line once; it checks REGION7 [0xE00000, 0x1000000) in mode 0 (free RAM) and its OK
#       line names the same span; mbi.cyr defines uefi_span_check.
#   (7) the BSP boot stack's RED ZONE (review fix; proc.cyr has the why): proc.cyr declares `var BSP_REDZONE =
#       0x2000;` (a multiple of 8, at most a quarter of the stack), EVERY frame in .text (`48 81 EC imm32`, cycc's
#       `sub rsp` — the only frame allocation it emits) is smaller than it, so no frame can straddle the zone
#       without writing a return address into it; main.cyr arms it once (`bsp_stack_redzone_arm();`), sched.cyr's
#       sched_leave_old and sched_assert_oob each call bsp_stack_redzone_check once, and the arm and the check use
#       the same canary.
#   (8) NOTHING AHEAD OF THE SHIM USES THE STACK (review fix): the ELF entry is `jmp rel32`, and from its target to
#       the shim's first byte (the CMOS 0x51 = 0xAB stamp, which the CP1 stamp heading (2)'s stack load follows
#       directly) the image holds only cycc's top-level enum initialisations — `xor eax, eax` / `mov eax, imm32` /
#       `movabs rax, imm64` / `mov rax, simm32` / `movabs rcx, imm64` / `mov [rcx], rax`, 304 stores in the plain
#       build at the ROOM step (228 earlier in 1.57.12, 201 at the BSP step; the count grows with every top-level enum —
#       the gate prints it). They run on gnoboot's undefined stack with RDI = &boot_info; a call, a push or an RDI write there
#       would break the boot or the handoff, silently. (CLAUDE.md and agnos.cyr said the shim was the first code
#       emitted; the image said otherwise.)
#   (9) EVERY FRAME FITS UNDER A REGION-7 GUARD PAGE, WITH A MARGIN (1.57.12): vmm.cyr kstack_guard_init still leaves
#       exactly ONE not-present 4 KB page at the bottom of each 64 KB region-7 slot (`(k & 15) == 0` over its 4 KB
#       PTEs — per-process kernel stacks, kthreads, IST1, AP boot/TSS stacks, the BSP's RSP0 slot), and every `sub rsp,
#       imm32` in .text is <= FRAME_MAX = GUARD_PAGE - FRAME_MARGIN = 0x1000 - 0x400 = 0xC00. Why: a guard page catches
#       an overflow only if the descent TOUCHES it. cycc's prologue is `push rbp; mov rbp, rsp; sub rsp, N` and nothing
#       writes the frame until the body does, anywhere in [rsp, rbp) — a local buffer fills UP from its base at the
#       frame's bottom. The caller's pushes (return address, saved rbp) landed at or above the guard's top (they did
#       not fault), so the callee's lowest byte is N + 16 below them and the next push (a call's return address, or an
#       interrupt frame's first slot after the 16-byte alignment) up to 16 more: N + 32 > 4 KB lets a frame step OVER
#       the guard into the TOP of the next slot down — another live stack — and write it with no fault at all. The
#       strict bound is 4 KB - 32; the 1 KB margin absorbs codegen drift a byte scan would not see as one frame (an
#       outgoing-argument area, an alignment pad, a second `sub rsp`). sh_exec's 5,152 B frame (a 4 KB `blkread`
#       buffer, every build) broke this until 1.57.12; the largest frame is now ksyscall's 2,176 B. A failure lists
#       every offending frame by address: build with CYRIUS_SYMS=/path/syms (cyrius crash-localization) to name them.
#       Do not enlarge the guard to fit a frame — region 7 is laid out slot for slot (gdt.cyr); move the big local off
#       the stack (a per-call kmalloc, or a module buffer where the code is provably single-walker).
#   (10) THE ROOM (1.57.12, 2026-10-12; core/room.cyr, docs/architecture/kernel-image-room.md). Operator standing rule
#       (2026-10-11), grow before refactor: a build near the bound MOVES bulk out of the image — it never trims code.
#       The large module arrays first touched after the direct map is live are POINTERS into one 2 MB pmm carve-out
#       (room_init, main.cyr), each initialised to its POISON ROOM_POISON + (slot << 32), ROOM_POISON =
#       0xFFFFA00000000000 (PML4[0x140], mapped under no CR3), so a use before the carve-out is a CPL0 #PF that the
#       #PF report names. This gate holds the contract a build cannot see: every `room_take(&NAME, SLOT, SIZE);` is in
#       fn room_init, one per line, slots unique in [1, 127]; NAME is declared exactly once in kernel/ (arch/aarch64
#       aside) as `var NAME = <its poison>;` and NEVER as an array (`var NAME[N]` — module or local — puts its bytes
#       back into the image, or shadows the pointer); no `&NAME` is left outside room_init (`&NAME` is now the address
#       of the 8-byte POINTER cell: `&NAME + off` would read or write whatever .bss follows it — it compiles, silently);
#       room_say names every slot and room_pf_say decodes exactly that window; main.cyr calls `room_init();` once,
#       after `pmm_bitmap_use_directmap();` AND `fb_shadow_init();` (the console shadow takes its contiguous 2 MB run
#       first — the room needs one region and must not split the shadow's on fragmented iron; the ROOM review,
#       2026-10-12) and before the first `pci_scan();` (the first moved-array user); idt.cyr's #PF stub calls
#       exc_pf_report, which calls room_pf_say. The runtime halves are agnsh-smoke (the carve-out and klug-move lines REQUIRED; `PANIC:
#       room` / `PANIC: kernel page fault` in SMOKE_INVARIANT_DENY) and dma-shadow-smoke's `room` arm (the carve-out
#       read and written under a CR3 whose whole pmm identity window is shadowed — the per-process-CR3 property).
#       (1) names the room when the bound is crossed. Mutation record: docs/architecture/kernel-image-room.md.
#   (1.57.7-1.57.11 asserted instead that the three fixed boot-stack immediates, the image's `mov rsp` and every
#   RSP0/span site equalled BSP_BOOT_TOP / BSP_RSP0_TOP — see the history below and git.)
#   ⚠ WHERE AN AP STACK ACTUALLY IS, and what the BSP's TSS.RSP0 holds at run time, are not this gate's business:
#   the runtime guard is SMP_STACK_SELFTEST — scripts/smoke/ap-stack-smoke.sh (-smp 4) samples each AP's live RSP
#   against the region-7 window, reads every TSS.RSP0 back (the BSP's as tss_init stored it, `smpstk: bsp rsp0=`,
#   since 1.57.12) against its exact slot top, and re-hashes the chunk literals in place after the wake. How DEEP
#   the BSP boot stack goes is a KSTACK_HW=1 build's `kstack-hw: bsp boot stack max=...` line (proc.cyr).
#
# WHO RUNS IT: check.sh gate 34 on the plain build; scripts/build.sh after EVERY x86_64 build — a build that set
# any flag FAILS (image moved to build/agnos.layout-refused; also when python3 is missing, since an unmeasured
# flag image must not be booted), a plain build WARNS on stderr and keeps the image so gate 34 can score it;
# bench.sh on its rewritten-source bench kernel; CI — ci.yml and release.yml run it right after their plain
# build, because CI never runs check.sh and the release artifact is plain. weighed-size-check.sh parses
# REGION1_TOP / CEIL from this file (the one source of the hard limit) to derive its wall; rbp-repro.sh calls
# --bsp-stack-span for its kmain smash window.
#
# ⚠ VACUITY: the caller must hand this the binary THIS run built (check.sh gates it behind the arity
# build's rc exactly as the size gate is). A fossil build/agnos measures a different tree.
#
# ═══════════════ HISTORY (1.57.3 - 1.57.11: the fixed region-1 BSP stack windows; numbers are history) ═══════════════
# ⭐⭐ 1.57.11 — THE STACK MOVED UP AGAIN, 0x3A0000 -> 0x3E0000, THE BOUND 0x390000 -> 0x3D0000, the RSP0 window
# [0x3B0000, 0x3C0000) -> [0x3F0000, 0x400000) (the top of region 1). The read-only ZFS module (core/zfs.cyr +
# zfs_codec.cyr) added ~100 KB and put the plain image 2,504 B past 0x390000 (LOAD end 0x3909c8); operator ruling
# 2026-10-09: allow the growth (a heavy refactor/rewrite is planned), move the stack. [0x3C0000, 0x400000) was
# audited first: every reference in the tree was a stale comment — the 0x3D0000/0x3F0000 syscall kstacks left
# region 1 for region 7 at 1.46.x/1.51.x. The region-1 map is now:
#     [0x3D0000, 0x3E0000)  BSP boot stack — 64 KB budget, grows down from 0x3E0000
#     [0x3E0000, 0x3F0000)  UNUSED 64 KB guard gap
#     [0x3F0000, 0x400000)  BSP TSS.RSP0 window (gdt.cyr tss_kernel_stack = 0x400000)
# The 1.57.7 notes below describe the move before this one; their numbers are history.
#
# ⛔⛔ WHY THIS EXISTS (2026-09-13, 1.57.2 -> 1.57.3). Every fixed kernel stack in PMM region 1 was placed
# by reading the image end off a build and choosing a number above it, and nothing re-checked those
# placements when the image grew. The 1.57.2 kernel-embedded face added ~410 KB of .rodata and moved the
# LOAD end from ~0x2FA2xx to 0x35E770 — straight across the AP1-3 boot/TSS stack window [0x310000,
# 0x340000), so CPUs 1-3 pushed every boot and CPL0 timer frame INTO kernel .rodata through the 2 MB RW
# identity pages (no fault, no signal, every -smp 1 gate green). This tree had already paid for the
# identical class twice on iron (gdt.cyr: RSP0 0x200000 inside live .bss -> triple fault; boot_shim.cyr:
# the 0x200000 boot stack overwrote "exfatu: upcase-checksum OK", found by gdb watchpoint) and both fixes
# were "pick a higher number" with a comment quoting an image end that has been stale ever since.
# History: docs/development/issues/archived/2026-09-13-ap-stacks-inside-kernel-rodata.md.
#
# 1.57.3 RELOCATED the AP stacks into region 7 (phys [0xFD0000, 0x1000000) through the direct map —
# gdt.cyr tss_get_cpu_stack carries the map; smp.cyr's trampoline computes the same VA), a pmm-reserved
# region the image can never reach. ⭐ So the 1.57.2 tolerated-overlap branch this script carried (decode
# the rekha chunk literals, prove every byte under the AP window was a dead chunk byte, lock the literals'
# single reader chain) is GONE — it described a layout that no longer exists, and keeping a PASS path
# that reasons about dead bytes under a stack would invite the next arc to lean on it. The image's ONLY
# remaining region-1 neighbour is the BSP boot stack, so this gate is about exactly one number.
#
# ⭐⭐ 1.57.7 (IMG step) — THE BSP BOOT STACK MOVED UP, 0x380000 -> 0x3A0000, AND THE BOUND WITH IT,
# 0x370000 -> 0x390000. Measured, not guessed: the 1.57.7 plan's ten steps estimated ~+59.2 KB of image
# against 59,240 B of headroom (4 B of margin; two steps' STOP rules tripped on paper), and the P0 flag
# table (handoff baseline/flag-load-ends.txt) found THREE flag builds the smokes boot ALREADY past
# 0x370000 on the 1.57.6 tree — RING3_SELFTEST=1 (sweep's ring3-smoke row) 0x375850, EDGE_ABI_SELFTEST=1
# (sweep's edge-abi-smoke row) 0x371260, EXEC+EXT2_WRITE+RING3 (exec-smoke's ring-3 variant) 0x37B288 —
# because this gate only ever measured the PLAIN image. This is NOT "raising the ceiling": the ceiling is
# re-derived from a MOVED stack, which stays in region 1 (the reasons below still hold). The new region-1
# map above the image:
#     [0x390000, 0x3A0000)  BSP boot stack — 64 KB budget, grows down from 0x3A0000
#     [0x3A0000, 0x3B0000)  UNUSED 64 KB guard gap (nothing in the tree references it — verified by grep
#                           of every spelling at 1.57.7: 0x38xxxx/0x39xxxx/0x3Axxxx, decimal, shifted,
#                           the asm byte forms; handoff logs/IMG-fix/preverify.log)
#     [0x3B0000, 0x3C0000)  BSP TSS.RSP0 window (gdt.cyr tss_kernel_stack)
# ⛔ WHAT KEEPS THE WINDOW FREE IS THE FIRMWARE, NOT gnoboot OR pmm (corrected by the IMG-fix pass — IMG wrote
# "gnoboot allocates only the image's own pages", which is false). pmm_init's 0-4 MB reservation is the kernel's
# own bookkeeping, made long after the shim's first push. gnoboot pins only the kernel image (ET_EXEC
# AllocateAddress); it ALSO allocates the /initramfs and /cmdline blobs with AllocateAnyPages (EfiLoaderData),
# and boot_info + the memory-map buffer are globals inside gnoboot's own image (EfiLoaderCode), wherever the
# firmware loaded BOOTX64.EFI. Nothing reserves [0x390000, 0x3A0000) before the first push — exactly as nothing
# reserved the old [0x370000, 0x380000). On OVMF the whole span is free RAM (a gdbstub paint of phys
# [0x370000, 0x3C0000) before OVMF's first instruction survives the firmware untouched outside the stack's own
# writes). On IRON it is now OBSERVABLE: kmain checks the UEFI map it was handed (mbi.cyr
# bootstack_window_check) and prints either "boot: BSP stack span 0x3D0000-0x400000 (1.57.11; 0x390000-0x3C0000 before) is free RAM in the UEFI map
# OK" or the denied "boot: BSP stack window not free RAM in the UEFI map - type 0x.. at 0x.." (SMOKE_INVARIANT_DENY;
# agnsh-smoke requires the OK line). Built, gated, NOT burned.
# ⚠ A LOAD end below the bound is necessary, not sufficient: the boot stack's DEPTH is not measured by any
# build (no flag paints it; KSTACK_HW paints only the region-7 per-process stacks). Measured from outside at
# 1.57.7, IMG-fix (handoff logs/IMG-fix/m4-paint-probe.py): phys [0x370000, 0x3C0000) PAINTED with a 64-bit
# pattern over the gdbstub while QEMU is held at reset, then booted and pmemsave'd — the lowest qword that is no
# longer paint is a TRUE high-water mark (IMG's first number read the lowest NON-ZERO byte of a zero-filled
# window, a lower bound: at -smp 4 the deepest qword written was a zero, 16 B below what that method sees).
# To the agnsh prompt: 2,088 B and 2,312 B (-smp 1, two boots), 2,328 B (-smp 4, KVM); through doom-smoke's
# pre-scheduler IF=0 run 5,288 B — one boot each, well inside the 64 KB budget every other kernel stack gets.
# The control windows (image headroom, guard gap, RSP0 window) stayed paint in every run.
#
# Mutation record (history, 1.57.3 - 1.57.11):
#   1.57.3 (on a scratch copy of the plain build): p_memsz bumped so the LOAD end lands at 0x370001 ->
#   "FAIL: LOAD end 0x370001 exceeds 0x370000 ..."; the shipped tree PASSED with LOAD end 0x35E8B0.
#   1.57.7 (IMG, 2026-09-24; each RED, then restored GREEN on the md5-identical file):
#   M1 plain image forced past the bound (a temporary `var pad[30000]`, +240,000 B) -> check.sh gate 34
#      "FAIL: LOAD end 0x39c220 exceeds 0x390000 ..." (the size gate and test.sh trip too);
#   M2 the same pad under `#ifdef FORK_SELFTEST` -> `FORK_SELFTEST=1 sh scripts/build.sh` exits 1 with
#      "FAIL: LOAD end 0x39c598 exceeds 0x390000". ⚠ That first RED ran an EARLIER build.sh (it moved the image
#      to build/agnos.over-bound); the guard was renamed afterwards. RE-RUN on the build.sh that ships (IMG-fix,
#      handoff logs/IMG-fix/M2-red-build-final.log): rc=1, "FAIL: LOAD end 0x39ccc8 exceeds 0x390000", `ls`
#      shows build/agnos ABSENT and build/agnos.layout-refused PRESENT; GREEN restored (M2-green-build-final.log);
#   M3a the legacy `mov esp` reverted to 0x380000 (bytes + comment) -> "FAIL: boot_shim.cyr:58 `mov esp,
#      0x380000` disagrees with BSP_BOOT_TOP" while the ELF64 image stays byte-identical — only (2) sees it;
#   M3b the ELF64 `mov rsp` reverted -> (2) plus both (3) lines (the image is then byte-identical to the
#      1.57.6-layout build: rsp = 0x380000 @0x22230f), and a TCP_SELFTEST flag build is refused;
#   M3d a comment-only drift (`# mov rsp, 0x380000` over 0x3A bytes) -> the comment-vs-bytes FAIL.
#   The 1.57.6-layout plain binary run through this gate FAILs (3) twice. Shipped by IMG: LOAD end 0x361898,
#   headroom 0x2E768 = 190,312 B.
#   1.57.7 IMG-fix: A4 proc.cyr's proc_rsp0_top fallback set to 0x3A0000 -> "(4) FAIL: proc.cyr proc_rsp0_top
#      fallback is 0x3a0000 ..." (the IMG-era gate PASSED it); A3 mbi.cyr bsw_lo/bsw_hi pointed at the kernel
#      image -> (4) FAILs both, and at boot the kernel prints the denied "not free RAM ... type 0x1 at 0x100000";
#      A5 the M1 pad on a PLAIN build -> build.sh prints the FAIL block + "WARNING: this PLAIN image fails ..." and
#      leaves the image; B4 a flag build with no python3 on PATH -> refused (the IMG-era guard exited 0 unmeasured).
#   Shipped by IMG-fix (the runtime span check adds 1,856 B): LOAD end 0x361fd8, headroom 0x2E028 = 188,456 B.
#
# Mutation record (1.57.12; each RED on a scratch edit, then restored GREEN on the md5-identical file):
#   Run on a scratch copy of the tree (rsync of this worktree; its plain build is md5-identical to the worktree's,
#   197306c6…), each mutation applied with cyim, then reverted and the copy re-diffed identical to the tree.
#   M1  plain image padded past the bound (`var mut_pad[60000];`, +480,000 B, boot_data.cyr) -> build.sh rc 0 with
#       the FAIL block + "WARNING: this PLAIN image fails ..." (image kept), and this gate rc 1:
#       "FAIL: LOAD end 0x416f70 exceeds 0x400000 — the top of region 1 ...".
#   M2  the same pad under `#ifdef FORK_SELFTEST` -> `FORK_SELFTEST=1 sh scripts/build.sh` rc 1, "FAIL: LOAD end
#       0x417398 exceeds 0x400000", build/agnos ABSENT and build/agnos.layout-refused PRESENT; reverted -> the same
#       flag build PASSes (LOAD end 0x3a2098, 384,872 B).
#   M3  `0x48; 0xBC; ...  # mov rsp, 0x3E0000` re-added after the shim's `mov rbp, rsp` -> (3) "boot_shim.cyr:146 is
#       a 0xBC (mov esp/rsp, imm) byte line" AND (4) "the image loads rsp = 0x3e0000 at 0x250e61"; a TCP_SELFTEST=1
#       build of that tree is refused.
#   M4  `add rax, 0x8000` (bytes and comment) -> (2) "the shim adds 0x8000 ...", (2) the stack-switch tail occurs 0
#       times, (3) "`add rax, 0x8000` is not BSP_BOOT_STACK_SIZE 0x10000". M4b comment-only drift (`# add rax,
#       0x8000` over the 0x10000 bytes) -> (3) "`add rax` bytes add 0x10000 but the comment says 0x8000" alone.
#   M5  `var bsp_boot_stack[4096]` -> (2) "the BSP boot stack [0x30d300, 0x31d300) is not inside .bss [0x2586c8,
#       0x315400)", (2) the lo cell 0x315300 lies inside the would-be stack, (3) "is 32768 B, BSP_BOOT_STACK_SIZE is
#       0x10000". (The shim would have grown the stack 32 KB past its array, over bsp_boot_stack_lo and .rodata.)
#   M6  `if (cpu_id == 0) { return 0x400000; }` back in tss_get_cpu_stack -> (5) "must be the one region-7 formula";
#       M6b `var tss_kernel_stack = 0x400000;` re-declared -> (5) "declares `var tss_kernel_stack` again".
#   M7  proc_rsp0_top's fallback back to `return 0x400000;` -> (5) "the unassigned-slot fallback must be exactly
#       `if (r == 0) { return tss_get_cpu_stack(0); }`"; M7b `tss_get_cpu_stack(pcpu_cpu())` (an AP's live idle
#       stack) -> the same (5) FAIL.
#   M8  main.cyr's region-7 check narrowed to `0xE00000, 0xFC0000` (OK line unchanged) -> (6) "expected exactly one
#       `uefi_span_check(load64(&boot_info_ptr), 0xE00000, 0x1000000, 0)`"; M8b the image-span check in mode 0 ->
#       (6) "... 0x100000, kimage_end, 1)".
#   M9  weighed-size-check.sh GRANT left at the 1.57.11 value 2,490,368 -> "FAIL: ORDERING — GRANT 2490368 <= WALL
#       2669724 (the weighed size at which LOAD end hits 0x400000 ...)".
#   (M1-M9 ran on the pre-review tree: LOAD end 0x3a1c70, headroom 385,936 B, stack [0x30d300, 0x31d300).)
#
# Review-fix mutations (1.57.12; scratch rsync of the worktree, plain build md5-identical to it before and after,
# each applied with cyim and restored; the worktree was never mutated):
#   R1  `0x48; 0xBC; 0xF0; 0xFF; 0x3D; 0x00; 0x00; 0x00; 0x00; 0x00;  # mov rsp, 0x3DFFF0` in a new fn in gdt.cyr (the
#       review's MC, which PASSED the pre-review gate) -> (3) "kernel/arch/x86_64/gdt.cyr:306 is a `mov esp/rsp, imm`
#       byte line" AND (4) "the image does `mov rsp, imm64` = 0x3dfff0 at 0x10ce17". R1m the mnemonic `asm { mov rsp,
#       0x3DFFF0; }` -> (3) "moves an immediate into the stack pointer" (cycc 6.6.6 also refuses that syntax).
#   R2  `bsp_boot_stack_lo = &boot_info_copy;` (the review's MA, caught only by (3) before) -> (2) "the shim stores
#       the stack address to 0x31d630, but the cell right after a 0x10000-byte array at 0x271dd0 is 0x281dd0" + (3).
#   R3  a top-level `serial_putc(65);` between boot_shim.cyr's declarations and its first asm block -> (8) "at
#       0x251136, after 201 constant stores, BEFORE the boot shim, the image carries 50 5f e8 ..." (push rax; pop
#       rdi; call — the stack AND RDI, ahead of the stack load).
#   R4  a fn with `var r4b[9000];` (a 9,040 B frame) -> (7) "the largest frame in .text (`sub rsp, 0x2350` at
#       0x12dfb5) is not smaller than the BSP boot stack's red zone 0x2000"; R4f the same under TCP_SELFTEST=1 ->
#       build.sh rc 1, image moved to build/agnos.layout-refused.
#   R5  sched_leave_old's `bsp_stack_redzone_check(isr_rsp, 1);` deleted -> (7) "sched.cyr sched_leave_old must call
#       ... exactly once".
#   R6  RUNTIME: `rz_dive(56)` (a recursion of 1 KB frames) right after main.cyr's boot-evidence block, agnsh-smoke
#       -> FAIL on the denied line "PANIC: BSP boot stack red zone overwritten at 0x30e498 (depth 0xf248 of
#       0x10000, check 0x1) -- halting" at kmain's first switch-out (after `kybernet: starting init`). R6b
#       `rz_dive(64)`, ~3 KB PAST the array's floor (over syscall.cyr's blk_* globals) -> the same PANIC, depth
#       0xff48: a descent through the zone always leaves a trace in it.
#   At the BSP step (plain, kashi 1.1.0 / rekha 0.9.0 siblings): LOAD end 0x3a2030, headroom 0x5dfd0 = 384,976 B, BSP
#   boot stack [0x30d630, 0x31d630) (red zone [0x30d630, 0x30f630)) — pre-fix figures, kept.
#   Shipped (plain; the final 1.57.12 tree — the ZFS write bites B0-B2, the review follow-ups and the second review's
#   M1-M5, measured 2026-10-10): 2,746,168 B, LOAD end 0x3ae5d8, headroom 0x51a28 = 334,376 B, BSP boot stack
#   [0x318c20, 0x328c20) (red zone [0x318c20, 0x31ac20)), 228 pre-shim constant stores (201 at the BSP step).
#
# (9) mutations (1.57.12, the region-7 guard bound; each applied to the worktree with cyim, built, gated, reverted
# with cyim and cmp'd back to the pristine file):
#   G0  the unfixed tree itself (sh_exec's `var rbuf[4096]`) -> (9) "1 frame(s) in .text exceed FRAME_MAX 0xc00 ...
#       `sub rsp, 0x1420` (5152 B) at 0x1397bb" (CYRIUS_SYMS: sh_exec+0x4).
#   G1  `fn d1_mut_big() { var m9[5120]; ... }` in user/test_procs.cyr -> (9) "`sub rsp, 0x1430` (5168 B)"; G1f the
#       same under TCP_SELFTEST=1 -> build.sh rc 1, image moved to build/agnos.layout-refused.
#   G2  `var m8[3200];` — a 3,248 B frame, UNDER the 4 KB guard but over FRAME_MAX -> (9) "`sub rsp, 0xcb0` (3248 B)":
#       the margin bites.
#   G3  vmm.cyr kstack_guard_init `(k & 15) == 0` -> `(k & 15) < 2` (two guard pages per slot) -> (9) "expected
#       exactly one `if ((k & 15) == 0) ...`": the bound cannot silently outlive a change to the guard.
#   Shipped (plain, the final 1.57.12 tree, re-measured): largest frame ksyscall's 0x880 = 2,176 B (sh_exec 0x400 =
#   1,024 B, sh_cmd_blkread 0x70), then ext2_write_selftest 1,552 B and dhcp_init 1,328 B — unchanged from the fix.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE=gate
if [ "${1:-}" = "--bsp-stack-span" ]; then MODE=span; shift; fi
AGNOS="${1:-$ROOT/build/agnos}"
KDIR="$ROOT/kernel"

[ -f "$AGNOS" ] || { echo "FAIL: $AGNOS not found — no image to measure"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not available — the ELF cannot be parsed"; exit 1; }

python3 - "$MODE" "$AGNOS" "$KDIR" <<'EOF'
import os, re, struct, sys
mode, agnos, kdir = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(agnos, 'rb').read()
REGION1_TOP = 0x400000                  # PD[1]'s top: VA 0x400000 (PD[2]) is ring-3 code in every process
CEIL = REGION1_TOP                      # LOAD end bound (1.57.12; 0x3D0000 = the old BSP_BOOT_TOP - 64 KB until then)
BSP_BOOT_STACK_SIZE = 0x10000           # boot_shim.cyr `var bsp_boot_stack[8192]` — 8192 u64
REGION7 = (0xE00000, 0x1000000)         # pmm-reserved kernel-stack region (gdt.cyr's region-7 map)
BSP_RSP0_SLOT = (0xFC0000, 0xFD0000)    # region-7 slot 0: the BSP's TSS.RSP0 window, via the direct map
IMAGE_BASE = 0x100000
assert 0x200000 < CEIL <= REGION1_TOP <= REGION7[0] <= BSP_RSP0_SLOT[0] < BSP_RSP0_SLOT[1] <= REGION7[1], "image-layout-check: constants inconsistent"
assert BSP_RSP0_SLOT[1] - BSP_RSP0_SLOT[0] == 0x10000, "image-layout-check: the RSP0 slot is not one 64 KB region-7 slot"
fails = []

# (1) one flat PT_LOAD, and its end.
if d[:4] != b'\x7fELF' or d[4] != 2:
    print("FAIL: not an ELF64 image"); sys.exit(1)
phoff = struct.unpack_from('<Q', d, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', d, 54)
loads = []
for i in range(phnum):
    o = phoff + i * phentsize
    if struct.unpack_from('<I', d, o)[0] == 1:
        p_offset, p_vaddr, _pa, p_filesz, p_memsz = struct.unpack_from('<QQQQQ', d, o + 8)
        loads.append((p_offset, p_vaddr, p_filesz, p_memsz))
if len(loads) != 1:
    print("FAIL: expected exactly one PT_LOAD, found %d — this gate's VA<->file mapping assumes cycc's flat image" % len(loads)); sys.exit(1)
p_offset, p_vaddr, p_filesz, p_memsz = loads[0]
if p_offset != 0 or p_vaddr != IMAGE_BASE:
    print("FAIL: PT_LOAD is offset 0x%x vaddr 0x%x — expected the flat 0 -> 0x%x mapping (VA = 0x%x + file offset)" % (p_offset, p_vaddr, IMAGE_BASE, IMAGE_BASE)); sys.exit(1)
end = p_vaddr + p_memsz
shoff = struct.unpack_from('<Q', d, 40)[0]
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 58)
secs = {}
if shnum:
    so = shoff + shstrndx * shentsize
    stroff, strsz = struct.unpack_from('<QQ', d, so + 24)
    strtab = d[stroff:stroff + strsz]
    for i in range(shnum):
        o = shoff + i * shentsize
        name_off = struct.unpack_from('<I', d, o)[0]
        addr, off, size = struct.unpack_from('<QQQ', d, o + 16)
        secs[strtab[name_off:strtab.find(b'\0', name_off)].decode()] = (addr, size)
for n in ('.text', '.bss'):
    if n not in secs:
        print("FAIL: the image has no %s section header — the shim's stack load cannot be located" % n); sys.exit(1)
ta, ts = secs['.text']
ba, bs = secs['.bss']
tlo, thi = ta - p_vaddr, ta - p_vaddr + ts

# (2) the shim's stack load, from the image.
STAMP = bytes([0xB0, 0x50, 0xE6, 0x70, 0xB0, 0x01, 0xE6, 0x71])
TAIL = b'\x48\x83\xe0\xf0\x48\x89\xc4\x48\x89\xe5'          # and rax,-16 ; mov rsp,rax ; mov rbp,rsp
seq = re.compile(re.escape(STAMP) + b'\x48\xb8(.{8})\x48\xb9(.{8})\x48\x89\x01\x48\x05(.{4})' + re.escape(TAIL), re.S)
ms = list(seq.finditer(d[tlo:thi]))
stack = None
stamp_off = None                        # file offset of the CP1 stamp that heads the stack load ((8) uses it)
if len(ms) != 1:
    fails.append("FAIL: (2) expected exactly one shim stack load in .text (CP1 stamp, then 48 B8 imm64 / 48 B9 imm64 / 48 89 01 / 48 05 imm32 / 48 83 E0 F0 / 48 89 C4 / 48 89 E5), found %d — boot_shim.cyr's `bsp_boot_stack_lo = &bsp_boot_stack;` + asm block changed shape, or cycc emitted something between them" % len(ms))
else:
    m = ms[0]
    stamp_off = tlo + m.start()
    base = struct.unpack('<Q', m.group(1))[0]
    lo_cell = struct.unpack('<Q', m.group(2))[0]
    sz = struct.unpack('<I', m.group(3))[0]
    top = (base + sz) & ~0xF
    stack = (base, base + sz, top, m.start() + ta)
    if sz != BSP_BOOT_STACK_SIZE:
        fails.append("FAIL: (2) the shim adds 0x%x to &bsp_boot_stack, BSP_BOOT_STACK_SIZE is 0x%x" % (sz, BSP_BOOT_STACK_SIZE))
    if not (ba <= base and base + sz <= ba + bs):
        fails.append("FAIL: (2) the BSP boot stack [0x%x, 0x%x) is not inside .bss [0x%x, 0x%x)" % (base, base + sz, ba, ba + bs))
    if not (p_vaddr <= lo_cell < end) or (base <= lo_cell < base + sz):
        fails.append("FAIL: (2) the shim stores &bsp_boot_stack to 0x%x — not a cell of the image outside the stack" % lo_cell)
    # Ties imm64 to bsp_boot_stack itself (1.57.12 review fix): any .bss symbol with 64 KB of .bss above it passes the
    # checks above. boot_shim.cyr declares `var bsp_boot_stack_lo` immediately after the array and cycc lays module
    # globals out in declaration order (plain build: array [0x30d300, 0x31d300), lo cell 0x31d300), so the stored-to
    # cell is exactly the array's end.
    if lo_cell != base + sz:
        fails.append("FAIL: (2) the shim stores the stack address to 0x%x, but the cell right after a 0x%x-byte array at 0x%x is 0x%x — boot_shim.cyr declares `var bsp_boot_stack_lo` immediately after `var bsp_boot_stack[N]`, so the statement names another symbol (or the two declarations moved apart, or cycc stopped laying globals out in declaration order — re-derive this check then)" % (lo_cell, sz, base, base + sz))
    if top < base + sz - 15 or top <= base:
        fails.append("FAIL: (2) the aligned stack top 0x%x is not within 16 B of the array end 0x%x" % (top, base + sz))
ntail = d.count(b'\x48\x05' + struct.pack('<I', BSP_BOOT_STACK_SIZE) + TAIL, tlo, thi)
if ntail != 1:
    fails.append("FAIL: (2) the stack-switch tail (add rax, 0x%x / and rax, -16 / mov rsp, rax / mov rbp, rsp) occurs %d times in .text, expected once" % (BSP_BOOT_STACK_SIZE, ntail))

if mode == 'span':
    if stack is None:
        for f in fails: print(f)
        sys.exit(1)
    print("0x%x 0x%x" % (stack[0], stack[1]))
    sys.exit(0)

print("  LOAD 0x%x..0x%x (filesz 0x%x memsz 0x%x)" % (p_vaddr, end, p_filesz, p_memsz))
for n in ('.text', '.rodata', '.bss'):
    if n in secs:
        a, s = secs[n]; print("  %-8s 0x%x..0x%x" % (n, a, a + s))
if stack is not None:
    print("  BSP boot stack: [0x%x, 0x%x) in .bss, initial rsp 0x%x (shim stack load @0x%x)" % stack)
print("  region 1 [0x200000, 0x%x): the image only — bound LOAD end <= 0x%x; BSP TSS.RSP0: region-7 slot 0 [0x%x, 0x%x) via the direct map; AP1-3: region 7 (ap-stack-smoke.sh)" % (REGION1_TOP, CEIL, BSP_RSP0_SLOT[0], BSP_RSP0_SLOT[1]))

# (3) the source.
def src(rel):
    try:
        return open(kdir + '/' + rel, encoding='utf-8').read()
    except OSError:
        fails.append("FAIL: kernel/%s not readable" % rel)
        return ''
shim = src('arch/x86_64/boot_shim.cyr')
n = re.findall(r'(?m)^var bsp_boot_stack\[(\d+)\];', shim)
if len(n) != 1:
    fails.append("FAIL: (3) boot_shim.cyr: expected exactly one `var bsp_boot_stack[N];`, found %d" % len(n))
elif int(n[0]) * 8 != BSP_BOOT_STACK_SIZE:
    fails.append("FAIL: (3) boot_shim.cyr: `var bsp_boot_stack[%s]` is %d B, BSP_BOOT_STACK_SIZE is 0x%x — move the array, the shim's add immediate and this constant together" % (n[0], int(n[0]) * 8, BSP_BOOT_STACK_SIZE))
if len(re.findall(r'(?m)^bsp_boot_stack_lo = &bsp_boot_stack;', shim)) != 1:
    fails.append("FAIL: (3) boot_shim.cyr: expected exactly one top-level `bsp_boot_stack_lo = &bsp_boot_stack;` (the statement that puts the address in RAX)")
want = {   # bytes -> comment pattern (the add's immediate is decoded and compared to the size)
    'add':  (lambda b: len(b) == 6 and b[:2] == [0x48, 0x05], r'add\s+rax,\s*(0x[0-9A-Fa-f]+)\s*$'),
    'and':  (lambda b: b == [0x48, 0x83, 0xE0, 0xF0], r'and\s+rax,\s*-16\s*$'),
    'mrsp': (lambda b: b == [0x48, 0x89, 0xC4], r'mov\s+rsp,\s*rax\s*$'),
    'mrbp': (lambda b: b == [0x48, 0x89, 0xE5], r'mov\s+rbp,\s*rsp\s*$'),
}
seen = {k: [] for k in want}
for ln, raw in enumerate(shim.splitlines(), 1):
    code, _, comment = raw.partition('#')
    toks = [t.strip() for t in code.split(';') if t.strip()]
    if not toks or not all(re.fullmatch(r'0x[0-9A-Fa-f]{1,2}', t) for t in toks):
        continue
    b = [int(t, 16) for t in toks]
    for k, (match, cpat) in want.items():
        if match(b):
            seen[k].append(ln)
            cm = re.search(cpat, comment.strip())
            if not cm:
                fails.append("FAIL: (3) boot_shim.cyr:%d bytes %s but its comment says %r — fix the comment or the bytes" % (ln, code.strip(), comment.strip()))
            elif k == 'add':
                imm = b[2] | b[3] << 8 | b[4] << 16 | b[5] << 24
                if int(cm.group(1), 16) != imm:
                    fails.append("FAIL: (3) boot_shim.cyr:%d `add rax` bytes add 0x%x but the comment says %s" % (ln, imm, cm.group(1)))
                if imm != BSP_BOOT_STACK_SIZE:
                    fails.append("FAIL: (3) boot_shim.cyr:%d `add rax, 0x%x` is not BSP_BOOT_STACK_SIZE 0x%x" % (ln, imm, BSP_BOOT_STACK_SIZE))
for k, lines in seen.items():
    if len(lines) != 1:
        fails.append("FAIL: (3) boot_shim.cyr: expected the `%s` byte line of the stack load exactly once, found %d %s" % (k, len(lines), lines))
# No stack-pointer immediate ANYWHERE in kernel/ (1.57.12 review fix — this scanned boot_shim.cyr only, so a raw
# `0x48; 0xBC; ...` written in any other file passed): a byte line that starts `mov esp, imm32` (BC, optionally
# behind a REX prefix with B clear — 0x49 0xBC is `mov r12`), `mov rsp, imm64` (48 BC) or `mov rsp, simm32`
# (48 C7 C4), and an asm-block MNEMONIC `mov rsp|esp, <number>` (cycc assembles mnemonics too). Every stack in this
# kernel is an address computed at run time (a .bss symbol, a region-7 slot through the direct map), never a literal.
REX_B0 = (0x40, 0x42, 0x44, 0x46, 0x48, 0x4A, 0x4C, 0x4E)
for dirpath, _dirs, files in sorted(os.walk(kdir)):
    for fname in sorted(files):
        if not fname.endswith('.cyr'):
            continue
        rel = os.path.relpath(os.path.join(dirpath, fname), kdir)
        for ln, raw in enumerate(src(rel).splitlines(), 1):
            code = raw.split('#', 1)[0]
            if re.search(r'\bmov\s+[re]?sp\s*,\s*(0x[0-9A-Fa-f]+|\d+)\b', code, re.I):
                fails.append("FAIL: (3) kernel/%s:%d moves an immediate into the stack pointer: %s — no fixed stack address may come back (the BSP boot stack is the .bss array bsp_boot_stack since 1.57.12)" % (rel, ln, code.strip()))
            toks = [t.strip() for t in code.split(';') if t.strip()]
            if not toks or not all(re.fullmatch(r'0x[0-9A-Fa-f]{1,2}', t) for t in toks):
                continue
            b = [int(t, 16) for t in toks]
            if b[0] == 0xBC or (len(b) > 1 and b[0] in REX_B0 and b[1] == 0xBC) or (len(b) > 2 and b[0] in (0x48, 0x4A, 0x4C, 0x4E) and b[1:3] == [0xC7, 0xC4]):
                fails.append("FAIL: (3) kernel/%s:%d is a `mov esp/rsp, imm` byte line: %s — no fixed stack address may come back (the BSP boot stack is the .bss array bsp_boot_stack since 1.57.12). If these bytes continue an instruction from the line above, put the whole instruction on one line." % (rel, ln, code.strip()))

# (4) no fixed stack top inside the image or region 1 is loaded into the stack pointer anywhere in .text (1.57.12 review
# fix: this matched only a 64 KB-ALIGNED `48 BC imm64` in [0x200000, 0x400000], so `mov rsp, 0x3DFFF0` passed). Now
# every `mov rsp, imm64` (48 BC), `mov esp, imm32` (BC, with or without a B-clear REX) and `mov rsp, simm32`
# (48 C7 C4) whose value lies in [0x100000, 0x400000] — the image and region 1. A byte scan, not a disassembly, so a
# hit could in principle be the tail of another instruction's operand: there were none in any of the 38 builds
# measured at 1.57.12. The indirect form (`mov rax, imm; mov rsp, rax`) cannot be told from a legitimate computed
# stack switch in the image; the (3) source scan above is that layer.
hits = {}                               # address -> (form, value); a `48 BC imm64` also reads as `mov esp, imm32`
for pat, name, signed in ((rb'\x48\xbc(.{8})', 'mov rsp, imm64', False),
                          (rb'[\x40\x42\x44\x46\x48\x4a\x4c\x4e]?\xbc(.{4})', 'mov esp, imm32', False),
                          (rb'[\x48\x4a\x4c\x4e]\xc7\xc4(.{4})', 'mov rsp, simm32', True)):
    for m in re.finditer(pat, d[tlo:thi], re.S):
        v = int.from_bytes(m.group(1), 'little', signed=signed)
        if IMAGE_BASE <= v <= REGION1_TOP:
            hits.setdefault(tlo + m.start() + p_vaddr, (name, v))
for a, (name, v) in sorted(hits.items()):
    fails.append("FAIL: (4) the image does `%s` = 0x%x at 0x%x — a fixed stack top inside the image / region 1; the BSP boot stack is the .bss array bsp_boot_stack since 1.57.12" % (name, v, a))

# (5) the BSP TSS.RSP0 sites.
def body_of(text, fn):
    m = re.search(r'(?ms)^fn ' + re.escape(fn) + r'\(.*?^\}', text)
    return m.group(0) if m else None
gdt = src('arch/x86_64/gdt.cyr')
proc = src('core/proc.cyr')
gfn = body_of(gdt, 'tss_get_cpu_stack')
if gfn is None:
    fails.append("FAIL: (5) gdt.cyr: fn tss_get_cpu_stack not found")
else:
    stmts = [s.split('#', 1)[0].strip() for s in gfn.splitlines()[1:-1]]
    stmts = [s for s in stmts if s]
    if stmts != ['return DIRECTMAP_BASE + 0x%X + cpu_id * 0x10000;' % BSP_RSP0_SLOT[1]]:
        fails.append("FAIL: (5) gdt.cyr tss_get_cpu_stack must be the one region-7 formula `return DIRECTMAP_BASE + 0x%X + cpu_id * 0x10000;` for every CPU (no BSP case — slot 0 [0x%x, 0x%x) is the BSP's RSP0), found %r" % (BSP_RSP0_SLOT[1], BSP_RSP0_SLOT[0], BSP_RSP0_SLOT[1], stmts))
if re.search(r'(?m)^var tss_kernel_stack\b', gdt):
    fails.append("FAIL: (5) gdt.cyr declares `var tss_kernel_stack` again — the fixed BSP RSP0 window left region 1 at 1.57.12")
pfn = body_of(proc, 'proc_rsp0_top')
if pfn is None or len(re.findall(r'if \(r == 0\) \{ return tss_get_cpu_stack\(0\); \}', pfn)) != 1:
    fails.append("FAIL: (5) proc.cyr proc_rsp0_top: the unassigned-slot fallback must be exactly `if (r == 0) { return tss_get_cpu_stack(0); }` — the BSP's region-7 slot, never the calling CPU's (an AP's slot is its live idle stack)")

# (6) the boot evidence spans.
mbi = src('arch/x86_64/mbi.cyr')
kmain = src('core/main.cyr')
if not re.search(r'(?m)^fn uefi_span_check\(bi, lo, hi, mode\)', mbi):
    fails.append("FAIL: (6) mbi.cyr: fn uefi_span_check(bi, lo, hi, mode) not found")
img_calls = re.findall(r'uefi_span_check\(load64\(&boot_info_ptr\), (0x[0-9A-Fa-f]+), kimage_end, (\d)\)', kmain)
if len(img_calls) != 1 or int(img_calls[0][0], 16) != p_vaddr or img_calls[0][1] != '1':
    fails.append("FAIL: (6) main.cyr: expected exactly one `uefi_span_check(load64(&boot_info_ptr), 0x%x, kimage_end, 1)` (the image span, loader-pinned), found %r" % (p_vaddr, img_calls))
if len(re.findall(r'\) inside the loader-pinned image \(EfiLoaderCode\) OK"', kmain)) != 1:
    fails.append("FAIL: (6) main.cyr: expected exactly one `... inside the loader-pinned image (EfiLoaderCode) OK` line")
r7_calls = re.findall(r'uefi_span_check\(load64\(&boot_info_ptr\), (0x[0-9A-Fa-f]+), (0x[0-9A-Fa-f]+), (\d)\)', kmain)
r7_ok = re.findall(r'boot: region 7 \[(0x[0-9A-Fa-f]+), (0x[0-9A-Fa-f]+)\) is free RAM in the UEFI map OK', kmain)
if len(r7_calls) != 1 or (int(r7_calls[0][0], 16), int(r7_calls[0][1], 16)) != REGION7 or r7_calls[0][2] != '0':
    fails.append("FAIL: (6) main.cyr: expected exactly one `uefi_span_check(load64(&boot_info_ptr), 0x%X, 0x%X, 0)` (region 7, free RAM), found %r" % (REGION7[0], REGION7[1], r7_calls))
if len(r7_ok) != 1 or (int(r7_ok[0][0], 16), int(r7_ok[0][1], 16)) != REGION7:
    fails.append("FAIL: (6) main.cyr: the region-7 OK line must name [0x%X, 0x%X) exactly once, found %r" % (REGION7[0], REGION7[1], r7_ok))

# (7) the BSP boot stack's RED ZONE (1.57.12 review fix; proc.cyr has the why). The stack has no guard page, so its
# lowest BSP_REDZONE bytes hold a canary that every exit from the stack re-reads. That only works if no single frame
# can step OVER the zone (a local buffer fills upward from its base, so a frame bigger than the zone could write
# below the array without touching the zone): every frame in .text (cycc's prologue `push rbp; mov rbp, rsp;
# sub rsp, imm32` — `48 81 EC imm32`, the only frame allocation it emits) must be smaller than BSP_REDZONE. And the
# mechanism must be wired: main.cyr arms it once, sched_leave_old and sched_assert_oob check it.
# ⚠ (1.57.12 B6 review) The scan is ANCHORED on that prologue: a bare `48 81 EC` byte search also matched the rel32 of
# a `call` whose displacement happened to be 0xFFEC8148 (e8 48 81 ec ff …: "sub rsp, 0x5fb8ff" inside a call, once the
# B6 fixes moved the code), and failed (7) and (9) on a frame that does not exist. Every other `48 81 EC` in .text must
# be EXPLAINED as the displacement of a `call` / `jmp rel32` (E8 / E9 up to 4 bytes before it) that lands on a prologue
# — anything else (a `sub rsp` cycc emitted outside a prologue, which it never has: 2,374 of 2,374 at B6) FAILS (7).
rz = re.findall(r'(?m)^var BSP_REDZONE = (0x[0-9A-Fa-f]+);', proc)
PROLOGUE = b'\x55\x48\x89\xe5'           # push rbp; mov rbp, rsp — then `sub rsp, imm32`
frames, stray = [], []
for fm in re.finditer(rb'\x48\x81\xec(.{4})', d[tlo:thi], re.S):
    fo = tlo + fm.start()
    if d[fo - 4:fo] == PROLOGUE:
        frames.append((struct.unpack('<i', fm.group(1))[0], fo + p_vaddr))
        continue
    why = None
    for k in range(1, 5):
        if d[fo - k] in (0xE8, 0xE9):
            tgt = fo - k + 5 + struct.unpack_from('<i', d, fo - k + 1)[0]
            if tlo <= tgt < thi and d[tgt:tgt + 4] == PROLOGUE:
                why = k
                break
    if why is None:
        stray.append(fo + p_vaddr)
if stray:
    fails.append("FAIL: (7) `48 81 EC` (sub rsp, imm32) at %s outside cycc's prologue and not inside a call / jmp rel32 that lands on one — a frame this gate cannot size; re-derive the frame scan" % ', '.join('0x%x' % a for a in stray))
big = max(frames) if frames else None
RZ = None
if len(rz) != 1:
    fails.append("FAIL: (7) proc.cyr: expected exactly one `var BSP_REDZONE = 0x...;` (the BSP boot stack's red zone), found %d" % len(rz))
else:
    RZ = int(rz[0], 16)
    if RZ % 8 != 0 or not (0x1000 <= RZ <= BSP_BOOT_STACK_SIZE // 4):
        fails.append("FAIL: (7) proc.cyr BSP_REDZONE = 0x%x — must be a multiple of 8 in [0x1000, 0x%x] (a quarter of the 0x%x stack)" % (RZ, BSP_BOOT_STACK_SIZE // 4, BSP_BOOT_STACK_SIZE))
    if big is None:
        fails.append("FAIL: (7) no `sub rsp, imm32` (48 81 EC) frame found in .text — cycc's prologue changed shape; re-derive the frame-size check")
    elif big[0] >= RZ:
        fails.append("FAIL: (7) the largest frame in .text (`sub rsp, 0x%x` at 0x%x) is not smaller than the BSP boot stack's red zone 0x%x — such a frame could straddle the zone without writing to it and overwrite the .bss below bsp_boot_stack unseen. Move that function's big local off the stack (a module-scope buffer), or grow BSP_REDZONE (and the array) together" % (big[0], big[1], RZ))
if len(re.findall(r'(?m)^bsp_stack_redzone_arm\(\);', kmain)) != 1:
    fails.append("FAIL: (7) main.cyr: expected exactly one top-level `bsp_stack_redzone_arm();` (arms the BSP boot stack's red zone)")
sched = src('core/sched.cyr')
for fn, call in (('sched_leave_old', 'bsp_stack_redzone_check(isr_rsp, 1);'), ('sched_assert_oob', 'bsp_stack_redzone_check(&oob_sp, 1 + tag);')):
    fb = body_of(sched, fn)
    if fb is None or fb.count(call) != 1:
        fails.append("FAIL: (7) sched.cyr %s must call `%s` exactly once — the red zone is re-read whenever a context leaves the BSP boot stack" % (fn, call))
for fn in ('bsp_stack_redzone_arm', 'bsp_stack_redzone_check'):
    fb = body_of(proc, fn)
    if fb is None or '0x57AC6E9D57AC6E9D' not in fb:
        fails.append("FAIL: (7) proc.cyr %s must use the red-zone canary 0x57AC6E9D57AC6E9D (arm and check must agree)" % fn)

# (8) NOTHING AHEAD OF THE SHIM USES THE STACK (1.57.12 review fix). gnoboot jumps to the entry with an undefined
# stack (handoff protocol §1; `mov rdi, rax; jmp rax`), and the shim's stack load is the first instruction allowed
# to make one. But the shim is not the first code: cycc's top-level enum initialisers (_tl_enum_inits, emitted
# before PARSE_PROG in every mode) run ahead of it as constant stores into .bss, on gnoboot's stack. They are
# stack-free and leave RDI alone today; a cycc that emitted a call, a push or an RDI write there would break the
# boot (or the boot-info handoff) silently. So: the entry is `jmp rel32`, and from its target to the shim's first
# byte (the CMOS 0x51 = 0xAB magic stamp, followed by the CP1 stamp that heads (2)'s stack load) there is nothing
# but `xor eax, eax` / `mov eax, imm32` / `movabs rax, imm64` / `mov rax, simm32` / `movabs rcx, imm64` /
# `mov [rcx], rax`.
SHIM0 = bytes([0xB0, 0x51, 0xE6, 0x70, 0xB0, 0xAB, 0xE6, 0x71])
PRE = ((b'\x31\xc0', 2), (b'\xb8', 5), (b'\x48\xb8', 10), (b'\x48\xc7\xc0', 7), (b'\x48\xb9', 10), (b'\x48\x89\x01', 3))
e_entry = struct.unpack_from('<Q', d, 24)[0]
eo = e_entry - p_vaddr
npre = 0                                # constant stores (`mov [rcx], rax`) ahead of the shim
pre_from = None
if not (tlo <= eo < thi) or d[eo] != 0xE9:
    fails.append("FAIL: (8) the ELF entry 0x%x is not a `jmp rel32` (E9) in .text — the pre-shim walk cannot start" % e_entry)
else:
    p = eo + 5 + struct.unpack_from('<i', d, eo + 1)[0]
    pre_from = p + p_vaddr
    bad = None
    while not d.startswith(SHIM0, p):
        n = next((ln_ for pfx, ln_ in PRE if d.startswith(pfx, p)), None)
        if n is None or not (tlo <= p < thi):
            bad = p
            break
        if d.startswith(b'\x48\x89\x01', p):
            npre += 1
        p += n
    if bad is not None:
        fails.append("FAIL: (8) at 0x%x, after %d constant stores, BEFORE the boot shim, the image carries %s — not a stack-free constant store. gnoboot's stack is undefined until the shim's stack load: a call, a push or an RDI write ahead of it breaks the boot or the boot-info handoff. Find what cycc emitted there (objdump -D -b binary -mi386:x86-64 --adjust-vma=0x%x build/agnos --start-address=0x%x)" % (bad + p_vaddr, npre, d[bad:bad + 12].hex(' '), p_vaddr, bad + p_vaddr))
    elif stamp_off is not None and p + len(SHIM0) != stamp_off:
        fails.append("FAIL: (8) the shim's first byte is at 0x%x but the CP1 stamp heading its stack load is at 0x%x — something now runs between the shim's entry and its stack load" % (p + p_vaddr, stamp_off + p_vaddr))
if big is not None and RZ is not None:
    print("  red zone 0x%x B under the BSP boot stack; largest frame in .text 0x%x B (@0x%x)" % (RZ, big[0], big[1]))

# (9) EVERY FRAME FITS UNDER A REGION-7 GUARD PAGE, WITH A MARGIN (1.57.12; the header has the why). The guard shape is
# read from the source so the bound cannot silently outlive a change to it; the frames are (7)'s `sub rsp, imm32` list.
GUARD_PAGE = 0x1000                     # one not-present 4 KB PTE per 64 KB region-7 slot
FRAME_MARGIN = 0x400                    # over the strict GUARD_PAGE - 32: codegen drift a byte scan cannot see
FRAME_MAX = GUARD_PAGE - FRAME_MARGIN   # 0xC00
vmm = src('core/vmm.cyr')
gfn = body_of(vmm, 'kstack_guard_init')
if gfn is None or gfn.count('if ((k & 15) == 0) { store64(gi_ptk + k * 8, 0); }') != 1 or 'while (k < 512)' not in gfn:
    fails.append("FAIL: (9) vmm.cyr kstack_guard_init: expected exactly one `if ((k & 15) == 0) { store64(gi_ptk + k * 8, 0); }` inside `while (k < 512)` — ONE not-present 4 KB page at the bottom of each 64 KB region-7 slot. The guard's shape changed: re-derive GUARD_PAGE and FRAME_MAX here before trusting this gate")
over = sorted((f for f in frames if f[0] > FRAME_MAX), reverse=True)
if over:
    fails.append("FAIL: (9) %d frame(s) in .text exceed FRAME_MAX 0x%x (the 0x%x region-7 guard page minus a 0x%x margin): %s — such a frame can step over the not-present guard at the bottom of a region-7 stack slot into the top of the next slot down (another live stack) without faulting. Name them with `CYRIUS_SYMS=<file> sh scripts/build.sh` (cyrius crash-localization: each address is fn+4), then move the big local off the stack — a per-call kmalloc, or a module buffer where the code is provably single-walker. Do not enlarge the guard" % (len(over), FRAME_MAX, GUARD_PAGE, FRAME_MARGIN, ', '.join('`sub rsp, 0x%x` (%d B) at 0x%x' % (n, n, a) for n, a in over)))
elif big is not None:
    print("  region-7 guard 0x%x B per 64 KB slot; largest frame 0x%x B <= FRAME_MAX 0x%x (guard - 0x%x margin)" % (GUARD_PAGE, big[0], FRAME_MAX, FRAME_MARGIN))
if pre_from is not None:
    print("  pre-shim prefix (cycc's enum initialisers, on gnoboot's stack): %d constant stores from 0x%x, stack-free" % (npre, pre_from))

# (10) THE ROOM (1.57.12; core/room.cyr, docs/architecture/kernel-image-room.md; the header has the why). The arrays that
# left the image's .bss for the boot carve-out stay out, and each moved array's slot, pointer, poison and name agree.
# Source-level: a moved array coming back as `var NAME[N]` grows the image with no other signal, and a surviving `&NAME`
# compiles to the address of the 8-byte POINTER cell — `&NAME + off` would then write over whatever .bss follows it.
ROOM_POISON = 0xFFFFA00000000000        # PML4[0x140], the upper canonical half: mapped under no CR3 this kernel runs on
nfails_before_room = len(fails)         # the summary line below is printed only when (10) itself added no FAIL
room = src('core/room.cyr')
takes = []                              # (name, slot, size, line) from `room_take(&NAME, SLOT, SIZE);`
def nostr(raw):
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', raw).split('#', 1)[0]
for ln, raw in enumerate(room.splitlines(), 1):
    code = nostr(raw)
    m = re.match(r'^\s*room_take\(&(\w+),\s*(\d+),\s*(\d+)\);\s*$', code)
    if m:
        takes.append((m.group(1), int(m.group(2)), int(m.group(3)), ln))
    elif 'room_take(' in code and not re.match(r'^fn room_take\(', code):
        fails.append("FAIL: (10) room.cyr:%d calls room_take in a shape this gate cannot read: %s — write it `room_take(&NAME, SLOT, SIZE);`, one per line" % (ln, code.strip()))
rnames = [t[0] for t in takes]
rslots = [t[1] for t in takes]
if not takes:
    fails.append("FAIL: (10) room.cyr: no `room_take(&NAME, SLOT, SIZE);` line — the room moves nothing, or changed shape; re-derive this check")
if len(set(rnames)) != len(rnames) or len(set(rslots)) != len(rslots) or any(not (1 <= s <= 127) for s in rslots):
    fails.append("FAIL: (10) room.cyr: room_take names %r / slots %r — each array once, each slot once, slots in [1, 127] (slot << 32 must stay inside PML4[0x140])" % (rnames, rslots))
ri = body_of(room, 'room_init')
if ri is None or any(ri.count('room_take(&%s,' % n) != 1 for n in rnames):
    fails.append("FAIL: (10) room.cyr: every room_take must be inside fn room_init, once")
if len(re.findall(r'(?m)^var ROOM_POISON = 0xFFFFA00000000000;', room)) != 1:
    fails.append("FAIL: (10) room.cyr: expected exactly one `var ROOM_POISON = 0xFFFFA00000000000;` — the poison window this gate and room_pf_say decode")
rpf = body_of(room, 'room_pf_say')
if rpf is None or 'if ((cr2 >> 47) != 0x1FFFF) { return 0; }' not in rpf or 'if (((cr2 >> 39) & 0x1FF) != 0x140) { return 0; }' not in rpf or 'var rp_slot = (cr2 >> 32) & 0x7F;' not in rpf:
    fails.append("FAIL: (10) room.cyr room_pf_say: it must decode the poison window exactly — upper half, PML4[0x140], slot = (cr2 >> 32) & 0x7F")
rsay = body_of(room, 'room_say')
for n, s, _sz, ln in takes:
    if rsay is None or len(re.findall(r'if \(slot == %d\)\s*\{ serial_print\("%s", %d\); return 1; \}' % (s, re.escape(n), len(n)), rsay)) != 1:
        fails.append("FAIL: (10) room.cyr room_say: slot %d must print exactly `%s` (room.cyr:%d moves it) — a use-before-carve-out #PF names the array through this table" % (s, n, ln))
if len(re.findall(r'(?m)^room_init\(\);', kmain)) != 1:
    fails.append("FAIL: (10) main.cyr: expected exactly one top-level `room_init();` (the carve-out)")
else:
    p_dm = kmain.find('\npmm_bitmap_use_directmap();')
    p_fb = kmain.find('\nfb_shadow_init();')
    p_ri = kmain.find('\nroom_init();')
    p_pci = kmain.find('\npci_scan();')
    if not (0 <= p_dm < p_fb < p_ri < p_pci):
        fails.append("FAIL: (10) main.cyr: `room_init();` must come after `pmm_bitmap_use_directmap();` (the direct map is live in kmain's context only from there) and after `fb_shadow_init();` (the console shadow takes its contiguous run first; the room must not split it), and before the first top-level `pci_scan();` (the first user of a moved array)")
idt = src('arch/x86_64/idt.cyr')
epf = body_of(idt, 'exc_pf_report')
if epf is None or epf.count('room_pf_say(cr2);') != 1 or len(re.findall(r'(?m)^\s+var pfr = &exc_pf_report;', idt)) != 1:
    fails.append("FAIL: (10) idt.cyr: the #PF stub must call exc_pf_report (`var pfr = &exc_pf_report;` once) and exc_pf_report must call `room_pf_say(cr2);` — without them a moved array used before room_init halts with nothing on COM1")
rdecl = {n: [] for n in rnames}
rarr = {n: [] for n in rnames}
raddr = {n: [] for n in rnames}
for dirpath, _dirs, files in sorted(os.walk(kdir)):
    if os.path.relpath(dirpath, kdir).startswith('arch/aarch64'):
        continue                        # the aarch64 build has no room (core/room.cyr is x86_64-only)
    for fname in sorted(files):
        if not fname.endswith('.cyr'):
            continue
        rel = os.path.relpath(os.path.join(dirpath, fname), kdir)
        for ln, raw in enumerate(src(rel).splitlines(), 1):
            code = nostr(raw)
            if '&' not in code and 'var ' not in code:
                continue
            for n in rnames:
                if re.match(r'^\s*var %s\b' % n, code):
                    m = re.match(r'^var %s = (0x[0-9A-Fa-f]+);' % n, code)
                    if m:
                        rdecl[n].append((rel, ln, int(m.group(1), 16)))
                    else:
                        rarr[n].append((rel, ln, code.strip()))
                if re.search(r'&%s\b' % n, code) and not (rel == 'core/room.cyr' and re.match(r'^\s*room_take\(&%s,' % n, code)):
                    raddr[n].append('%s:%d' % (rel, ln))
for n, s, _sz, ln in takes:
    for rel, l2, c in rarr[n]:
        fails.append("FAIL: (10) %s is back: kernel/%s:%d `%s` — it is ROOM slot %d (room.cyr:%d), a POINTER `var %s = 0x%X;` into the boot carve-out; an array declaration puts its bytes back into the image (or shadows the pointer)" % (n, rel, l2, c, s, ln, n, ROOM_POISON + (s << 32)))
    if len(rdecl[n]) != 1:
        fails.append("FAIL: (10) %s (ROOM slot %d): expected exactly one module-scope `var %s = 0x%X;`, found %r" % (n, s, n, ROOM_POISON + (s << 32), rdecl[n]))
    elif rdecl[n][0][2] != ROOM_POISON + (s << 32):
        fails.append("FAIL: (10) kernel/%s:%d declares %s = 0x%X — ROOM slot %d's poison is 0x%X (ROOM_POISON + (slot << 32)); room_take refuses any other value at boot, and the #PF report would name the wrong array" % (rdecl[n][0][0], rdecl[n][0][1], n, rdecl[n][0][2], s, ROOM_POISON + (s << 32)))
    if raddr[n]:
        fails.append("FAIL: (10) `&%s` at %s — %s is a POINTER since it moved to the room (slot %d): `&%s` is the address of its 8-byte cell, so `&%s + off` reads or writes whatever .bss follows it. Write `%s + off`" % (n, ', '.join(raddr[n]), n, s, n, n, n))
# (the second ROOM review: this line printed "none declared back, no `&NAME` left" above the very FAIL that said one was
# left — it is a PASS summary, so it is printed only when (10) found nothing)
if takes and len(fails) == nfails_before_room:
    print("  room: %d arrays (%d B) live in the boot carve-out, not the image — slots %s, each a poison pointer; none declared back, no `&NAME` left" % (len(takes), sum(t[2] for t in takes), ','.join(str(s) for s in rslots)))

# (1) the bound.
if end > CEIL:
    fails.append("FAIL: LOAD end 0x%x exceeds 0x%x — the top of region 1. VA 0x400000 is ring-3 code in every process and pmm_init reserves only [0, 4 MB) for the kernel: do not raise this number. Grow the ROOM instead (operator rule, grow before refactor): move a large module array that is first touched after room_init into the boot carve-out — core/room.cyr's banner and docs/architecture/kernel-image-room.md say how, and (10) checks it. (Past that, the architecture changes: a higher-half kernel, a higher user link base.)" % (end, CEIL))
if fails:
    for f in fails:
        print(f)
    sys.exit(1)
print("  PASS: LOAD end 0x%x <= 0x%x — headroom to the top of region 1 0x%x = %d B; BSP boot stack [0x%x, 0x%x) in .bss, decoded from the shim; BSP TSS.RSP0 = region-7 slot 0 (direct map)" % (end, CEIL, CEIL - end, CEIL - end, stack[0], stack[1]))
sys.exit(0)
EOF
