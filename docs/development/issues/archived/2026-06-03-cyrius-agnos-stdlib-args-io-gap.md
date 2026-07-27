# cyrius `CYRIUS_TARGET_AGNOS` stdlib gap: `lib/args.cyr` + `lib/io.cyr` (blocks boot-to-agnsh / agnos 1.41.4)

> **Status**: RESOLVED 2026-06-03 (cyrius 6.0.55 — its CHANGELOG names this exact file).
> `lib/args_agnos.cyr` init-stack argc/argv reader + `sys_chmod` no-op + `io.cyr` O_*→AO_*
> bridge all shipped; consumer-validated — agnsh reaches the `[ASSIST] >` prompt and
> `agnsh-smoke.sh` PASS (agnos 1.41.12-1.41.13). The cyrius tracking copy is archived,
> marked RESOLVED v6.0.55. Audit-confirmed + archived 2026-06-18.
> **Filed**: 2026-06-03 (agnos 1.41.4 shell-separation work)
> **Severity**: Blocks the agnsh-on-agnos boot (the dispositive "first boot-to-agnsh-on-disk").
> **NOT a kernel bug** — the agnos exec path is correct (proven below). **NOT a syscall-ABI
> break** — `lib/syscalls_x86_64_agnos.cyr` is a complete, faithful mirror of
> `agnos-userland-abi.md` (verified 2026-06-03). The gap is in the **higher-level stdlib
> modules** that were never given a `CYRIUS_TARGET_AGNOS` branch.
> **Repro toolchain**: cyrius 6.0.50, agnoshi 1.3.4 (pin → 6.0.50), agnos 1.41.3, OVMF + NVMe ext2.

## Symptom

`agnsh` built for the agnos target (`cyrius build --agnos src/agnsh.cyr build/agnsh_agnos`,
285 872 B static ELF64, entry `0x400078`) **`#UD`s at startup** when launched in ring 3 by the
agnos kernel (`kybernet` → `/bin/agnsh`, 1.41.4). The boot reaches `kybernet: exec /bin/agnsh`,
agnsh enters ring 3 and initialises its heap, then dies — no agnsh prompt.

## Evidence (the kernel is exonerated)

QEMU `-d int` on the agnsh boot:

```
186: v=06 e=0000 i=0 cpl=3 IP=0023:0000000000435b98 pc=...435b98 SP=001b:...01002fb0
     env->regs[R_EAX]=0000000010000000
```

- `v=06` = **#UD (invalid opcode)**, **`cpl=3`** → the fault is in **agnsh's own ring-3 code**, not
  the kernel.
- `RAX=0x10000000` = the agnos kernel's mmap-arena base → agnsh's heap-init **`mmap(27)` already
  succeeded**. The kernel ran agnsh correctly up to this point.
- Disassembly at agnsh VA `0x435b98`: `0f 0b` = **`ud2`**, immediately after `call 0x4029b7` — the
  cyrius **unresolved-call sentinel**.
- Call site in agnsh source: `src/agnsh.cyr:372` calls **`args_init()`** at the top of `main`
  (then `:374 argc()`, `:379 argv(1)`).

So: agnsh loads, enters ring 3, mmap-inits its heap, calls `args_init()` → `ud2` → `#UD`.

## Root cause

`agnoshi/lib/args.cyr` (the vendored cyrius stdlib) has **only** `CYRIUS_TARGET_MACOS` and
`CYRIUS_TARGET_LINUX` branches — **no `CYRIUS_TARGET_AGNOS`**. So `args_init` / `argc` / `argv`
are *undefined* for the agnos target and cyrius emits `ud2` at each call site.

The Linux impl (`lib/args.cyr` under `#ifdef CYRIUS_TARGET_LINUX`) reads
**`/proc/self/cmdline`** — a procfs mechanism agnos has no equivalent of. So the agnos branch
cannot just reuse the Linux body; it needs a **different mechanism**.

Same shape in **`lib/io.cyr`**: `sys_chmod` is `CYRIUS_TARGET_LINUX`-only. agnsh calls it in
`src/history.cyr:118` and `src/checkpoint.cyr:32` — *runtime* features (not startup-blocking),
but they'll `#UD` the same way once reached, and agnos has no `chmod` syscall (not in the 0–33
surface).

## The agnos-side facts the fix can rely on

The agnos kernel's exec path (1.40.7, `elf_load_from_file`) builds a standard **SysV init stack**
for the new ring-3 process: `rsp → argc, argv[0..argc-1], NULL, envp..., NULL, auxv...`. So
argc/argv are available **on the entry stack** — the agnos `args` impl should read them there,
exactly like a normal SysV `_start`, **not** via `/proc`.

## Fix (cyrius-side)

1. **`lib/args.cyr`** — add a `#ifdef CYRIUS_TARGET_AGNOS` branch implementing `args_init`/`argc`/
   `argv` from the **init stack**. This requires the agnos `_start`/runtime to capture the initial
   `rsp` (or argc + argv pointer) into a global the module can read; `args_init` then reads
   `argc = [rsp]`, `argv[i] = [rsp + 8 + i*8]`. (If the agnos `_start` already stashes the init
   stack, this is just the accessor.)
2. **`lib/io.cyr`** — add a `CYRIUS_TARGET_AGNOS` `sys_chmod` (agnos has no `chmod` syscall, so a
   no-op returning 0 is acceptable — `ls -l`-style metadata isn't in the agnos FS surface) so the
   history/checkpoint paths don't `#UD`. Audit the rest of `lib/io.cyr` for other Linux-only
   wrappers agnsh's reachable code touches.

## Validation (once cyrius lands the agnos branches)

```
cd agnoshi && cyrius update && cyrius build --agnos src/agnsh.cyr build/agnsh_agnos
cd ../agnos && sh scripts/build.sh && bash scripts/agnsh-smoke.sh
```

Expected: the boot reaches an **agnsh prompt** instead of `#UD` / the emergency-shell fallback.
The kernel side (`kybernet` exec + fallback) is already done + validated at agnos 1.41.4.
