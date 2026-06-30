# Large-binary exec → kernel stack overflow → triple fault

**Status**: ✅ **RESOLVED 2026-06-30.** Root cause was NOT binary size — it was a **VA-space collision**: the per-process kernel stacks lived in the low identity window where large user segments map. Fixed by relocating them onto the direct-map (8 GB+). The 15.9 MB ark binary now loads + runs in ring 3 (`scripts/ark-run-smoke.sh` PASS), with ring3-smoke / exec-smoke / check.sh 11/11 / agnsh-smoke all green (no regression). NOTE: ark was NOT shrunk — with the >256 MB RAM work a 16 MB binary is fine; the bug was the kernel parking its stacks in the user-segment range. See the **Fix** section.
**Severity (was)**: High for the server stage (no binary whose segment reached 14 MB could run); zero for base/MVP (binaries were ≤ ~1.2 MB, below the kstack pool).
**Found by**: the ark v2 M3 attempt — running the real **ark binary (15.9 MB, segment to ~20 MB)** on agnos.

## Fix (2026-06-30)

The per-process kernel stacks were in **region 7 (phys 0xE00000–0x1000000, 14–16 MB)**, identity-mapped (VA==phys) in every per-proc CR3 — chosen so a low identity VA resolves under every CR3. But `elf_load` maps user PT_LOADs up to 256 MB, and `proc_map_page` **overrides** the per-proc PD entries a segment covers. ark's segment (0x400000 → ~0x1400000, 14 MB `.bss`-inflated) overrode `PD[7]`, clobbering the kstack mapping in ark's own CR3 → the exec path's next stack push (`SP=0xF10000`, the CPU-0 syscall kstack) #PF'd at ring 0 → #DF → triple fault.

**Two kstack kinds lived in region 7 and both had to move:** the per-proc RSP0 interrupt stacks (`proc_rsp0`, `0xE00000–0xF00000`) and the per-CPU syscall kstacks (`pcpu_syscall_kstack_top` `0xF10000+`, `pcpu_syscall_kstack_top2` `0xF90000+`, the nested-`execwait#37` set).

The fix points both at the **direct-map alias** of the same region-7 phys (`DIRECTMAP_BASE + phys`, 8 GB+) instead of the low identity VA. The direct-map (`vmm.cyr pmm_setup_directmap`, PDPT[8..71]) is mirrored into every per-proc CR3 (`proc.cyr` copies PDPT[1..511]) and sits far above any user VA (segments ≤256 MB, mmap/stack ≤~1 GB), so it is **never** segment-overridden. Data-only change — the syscall stub already loads RSP from the table via `mov rsp,[r8*8+&table]` (a 64-bit load), so 8 GB+ VAs need no stub edit; phys stays region-7-reserved (no PMM change). Files: `kernel/core/proc.cyr` (RSP0), `kernel/arch/x86_64/syscall_hw.cyr` (both syscall kstacks). This is the >256 MB / direct-map infrastructure (1.49.x) reused exactly as intended — the kstacks no longer fight the user address space.

— historical analysis below (the original "stack overflow" framing; superseded by the VA-collision root cause above) —

## Symptom

`run /bin/ark` (exec-from-disk of the 15.9 MB ark ELF) never reaches ark's ring-3 code: no output, no `run: exit`, and the rest of boot (kybernet/agnsh) never runs — the box wedges right after `exec: running /bin/ark`. Under `-no-shutdown` QEMU stays up, so a serial-only smoke reads it as a silent hang.

## Hard evidence (QEMU `-d int,cpu_reset`, TCG)

```
check_exception old: 0xffffffff new 0xe
  v=0e e=0003 i=0 cpl=0 IP=0008:00000000001ca63f  CR2=0000000000f0fff8  SP=0010:0000000000f10000  CR3=000000000fff1000
check_exception old: 0xe new 0xe
  v=08 e=0000 i=0 cpl=0 IP=0008:00000000001ca63f  env->regs[R_EAX]=000000000000001b
check_exception old: 0x8 new 0xe
Triple fault
```

Reading it:
- **`CPL=0`, `CS=0x0008`** → the fault is in **ring-0 kernel code**, not ark's ring-3 code. ark's `main` never ran (it printed nothing).
- **`RIP = 0x1ca63f`** is inside the kernel LOAD segment (vaddr `0x100000`–`0x25bfc8`, `readelf -l build/agnos`).
- **`CR2 = 0xf0fff8` is exactly `SP (0xf10000) − 8`** → the faulting access is a `push`/`call` writing one slot below the current kernel stack pointer, into an **unmapped page** → **kernel stack overflow / underflow past the stack mapping**.
- The `#PF` immediately re-faults at the **same IP** → `#DF` (the fault handler can't push its own frame — the stack is gone) → **triple fault** → CPU reset.

The fault fires during the **exec / `elf_load_from_file` path** for the 16 MB image (it is the first thing `run /bin/ark` does), *before* any ring-3 instruction of ark. So this is purely a **kernel exec/load** limitation exposed by binary size, not an ark bug and not a userland fault.

## Scope / why now

ark is by far the largest binary attempted on agnos — the prior ceiling is kriya 934 KB / doom 589 KB / cyim 1.2 MB, all of which exec fine. Something in the exec/load path scales its **kernel-stack** usage (or recurses) with binary size or segment/`.bss` size; the 15.9 MB image with a ~14 MB zero-fill `.bss` (memsz ≫ filesz) crosses the kernel stack budget. Candidates to investigate (do NOT pre-commit — get the function at `0x1ca63f` first; the stripped cyrius ELF needs a symbolized build or a `-d in_asm` trace):
- a stack-proportional or recursive copy/zero of the segment / `.bss` in `elf_load_from_file` / the exec staging,
- a large on-stack scratch buffer in the exec path that a big header/segment count overflows,
- the kernel stack itself being smaller than a large exec transiently needs.

## Repro

```sh
# in agnos/
ARK_SELFTEST=1 ./scripts/build.sh                 # kernel runs `run /bin/ark` deterministically at boot
cp ../ark/build/ark_agnos build/ark-rootfs/bin/ark   # 15.9 MB agnos ark (cyrius build --agnos)
./scripts/ark-run-smoke.sh                         # FAILs: no command list, wedges at exec
# fault data:
qemu ... -d int,cpu_reset -D build/ark-int.log     # shows the #PF(SP-8) -> #DF -> Triple fault
```

`scripts/ark-run-smoke.sh` (deterministic `run /bin/ark` via the `ARK_SELFTEST` gate) is the standing regression: it will go green once the exec path stops overflowing the kernel stack on large binaries.

## NOT blocked by this

The **symlink syscall** the ark v2 item (a) needed is fully proven on agnos, independently: `scripts/symlink-smoke.sh` round-trips a `--agnos` `sys_symlink` create + `open()` traversal + `e2fsck -fn` clean (kernel `symlink`#63 1.51.0 + cyrius `sys_symlink` peer 6.3.6). ark's install path is wired to it (`ark/src/portable.cyr`, `ark_symlink` → the 4-arg agnos peer; `ark` agnos cross-build compiles at 15.9 MB). The *only* thing standing between here and the M3 on-agnos `.ark`-with-symlinks install is **this large-binary exec blocker** — fix it and the ark M3 round-trip should be reachable (a smaller focused install exerciser is the fallback if the full 16 MB CLI stays heavy).

## Related

- [[project_ark_v2_sovereignty_path]] · [[project_cyrius_pinlag_large_agnos_binary_miscompile]] (prior large-binary issue — that one was a cyrius miscompile, size-gated < 1 MB, fixed by pin ≥ 6.1.37; ark is built on 6.3.9, so this is a *different*, kernel-side, stack-exhaustion failure).
- `docs/development/issues/2026-06-29-cyrius-agnos-sys-symlink-peer.md` (the now-RESOLVED symlink peer).
- 1.51.x roadmap row (sovereign-package-manager kernel surface).
