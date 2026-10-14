# AGNOS — Claude Code Instructions

> **Core rule**: this file is **preferences, process, and procedures** — durable rules that change rarely. Volatile state (current version, binary sizes, subsystem rollup, sibling pins, in-flight slots) lives in [`docs/development/state.md`](docs/development/state.md), refreshed every release. Inlined state rots within a minor.
>
> Structure per [first-party-documentation § CLAUDE.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md#claudemd). Reference implementation: [cyrius/CLAUDE.md](https://github.com/MacCracken/cyrius/blob/main/CLAUDE.md).

---

## Project Identity

**AGNOS** (from Greek *agnosis* — unknowing, the blank slate) — sovereign operating system kernel.

- **Type**: Bare-metal kernel binary (Cyrius language, freestanding)
- **License**: GPL-3.0-only
- **Language**: Cyrius — toolchain pinned in [`cyrius.cyml`](cyrius.cyml) `[package].cyrius`; switch with `cyriusly use <pin>`
- **Version**: [`VERSION`](VERSION) at the project root is the single source of truth — never inlined here
- **Target**: x86_64 + aarch64 (cross-compile via `cycc_aarch64`)
- **Genesis repo**: [agnosticos](https://github.com/MacCracken/agnosticos)
- **Standards**: [First-Party Standards](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-standards.md) · [First-Party Documentation](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md)

## Goal

Own the kernel. Cyrius writes every instruction from power-on to userland. No C, no Rust, no LLVM, no libc, no linker scripts. Boots on QEMU via multiboot1 and proves the language handles bare-metal correctly.

## Current State

> Volatile state lives in [`docs/development/state.md`](docs/development/state.md) — current version, binary sizes (x86_64 + aarch64), source rollup, subsystem table, syscall surface, sibling pins (kybernet/agnosys/agnostik/argonaut/daimon/libro), in-flight slots, verification hosts. Refreshed every release.
>
> Historical release narrative lives in [`CHANGELOG.md`](CHANGELOG.md). Design ledger + active roadmap items live in [`docs/development/roadmap.md`](docs/development/roadmap.md). Doc-currency ledger lives in [`docs/doc-health.md`](docs/doc-health.md).

Do not inline state in this file — see Core rule above.

## Quick Start

```sh
# Build (toolchain pin auto-resolves from cyrius.cyml)
sh scripts/build.sh                     # x86_64
sh scripts/build.sh --aarch64           # aarch64 cross-compile

# Boot on QEMU — via gnoboot + OVMF. `-cpu max` is mandatory (boot shim sets SMEP+SMAP in CR4).
# ⛔ `qemu-system-x86_64 -kernel build/agnos` DOES NOT WORK and this file documented it until
# 1.56.51. The kernel has been ELF64/multiboot2 since Path C; an ELF64 image carries no PVH note,
# so QEMU's Linux-protocol loader rejects it outright:
#     qemu-system-x86_64: Error loading uncompressed kernel without PVH ELF Note
# Booting needs a GPT image with gnoboot's BOOTX64.EFI on the ESP, which the smokes construct.
# Use one of those rather than hand-rolling it:
sh scripts/smoke/agnsh-smoke.sh         # boot to the agnsh prompt (needs ../gnoboot, ../agnoshi, OVMF)
sh scripts/ktest.sh                     # in-kernel test suite under the same gnoboot path

# Verify
sh scripts/test.sh                      # x86_64 (default)
sh scripts/test.sh --aarch64            # aarch64 (compile + link test; never booted) — see below
sh scripts/test.sh --all                # both
sh scripts/check.sh                     # 40-gate project validation
sh scripts/sweep.sh                     # full smoke sweep, parallel (SWEEP_JOBS=4 default; SWEEP_JOBS=1 = serial; SWEEP_ONLY='<ERE>')
```

⚠ **aarch64 COMPILES AND LINKS (since 1.57.13) — and has never booted; the port is the 1.6x arc.** Its counts and
history live in [`state.md`](docs/development/state.md) and the CHANGELOG, not here. The durable rules:
- **The compiler's "OK" is not "every call resolved."** cycc through 6.6.8 (both backends; measured on 6.6.6) drops an
  undefined function from its refusal when the name's FIRST reference sits in a dead function, even when a later call
  site is live — the aarch64 backend without so much as a warning — and emits every call to it as a placeholder
  (`udf #0`; x86 `ud2; ud2; nop`). cyrius 6.6.9+ refuses that shape itself (the pin is 6.6.20 since 1.57.14); the gate
  stays as the belt — it reads the IMAGE, and it is the only check on an off-pin build. `scripts/check/placeholder-check.sh` counts them: `build.sh` runs it after EVERY build and
  refuses a holed image (moved to `build/agnos{,-aarch64}.placeholder-refused`), and check.sh's aarch64 row runs
  `build.sh --aarch64`. After a shared file gains a name, run `sh scripts/build.sh --aarch64`; a red means it reached
  a name that lives in `agnos.cyr`'s x86_64 block — stub it in `arch/aarch64/stubs.cyr` (the configured-out shape its
  § 1.57.13 documents) or guard the x86-only caller.
- **"Compiles" is not "boots."** The image still carries x86 machine code and x86 physical-layout addresses from
  shared files (roadmap.md's aarch64 row lists them), so `release.yml` records `aarch64=compiled` and publishes no
  aarch64 kernel until a boot gate exists. A FAILED aarch64 compile does not block a release (operator ruling
  2026-10-13): `release.yml` records `aarch64=absent` and the x86_64 release continues, until the port is ready and
  proven — then CI gates it (the 1.6x port). Fix the regression; do not make the gate hard in 1.57.x.

## Scaffolding

AGNOS was not generated by `cyrius init` — it predates the scaffolding tool. New first-party Cyrius repos use `cyrius init <name>`; existing repos like this one stay on their hand-rolled structure until/unless the tools earn a re-scaffold. **Do not manually invent new project structure** in this repo — match what's here, and if a convention conflicts with first-party standards, fix the standard or earn an explicit deviation.

## Tools

- **`owl`** — watchful viewer that understands Cyrius syntax. Use for **reading** `.cyr` files. Never `cat` a `.cyr` directly when reading — owl handles the syntax-aware view.
- **`cyim`** — atomic, batch-mode editor with expect-assertions. Use for **writing/editing** `.cyr` files. Never `sed` a `.cyr` in place when editing.
- **`cyrius`** — the build/test/format wrapper. Always go through `cyrius build` — never invoke `cycc` / `cycc_aarch64` directly. The wrapper resolves includes, manages dep resolution from `cyrius.cyml`, and dispatches to the right backend. Direct `cycc` is reserved for the Cyrius repo's own bootstrap/self-host work. (Binary was `cc5` pre-v6.0.0; back-compat symlink lives through the v6.0.x window then drops at v6.1.0 — don't rely on it.)

## Key Principles

- **Assembly is the cornerstone** — every instruction maps to hardware reality. If you can't explain what the CPU is doing, the abstraction is wrong.
- **Own every byte** — no libc, no external runtime, no linker scripts. The kernel `cyrius.cyml` declares an empty `[deps]` block; `kernel/klib/` is the vendored kernel-safe stdlib (`kstring`, `kfmt`, `ktagged`).
- **Multiboot1 boot** — 32-bit ELF for GRUB/QEMU compatibility. The boot shim transitions to long mode.
- **Serial console** — all kernel output via COM1 (`0x3F8` x86_64) / PL011 UART (aarch64).
- **ISR correctness** — save ALL caller-saved registers (9: rax, rcx, rdx, rsi, rdi, r8–r11).
- **Bounds check everything** — PMM, process table, syscall args.
- **Identity map first** — 2 MB huge pages, add finer granularity when needed.
- **`-cpu max` is required for QEMU x86_64** — the boot shim's CR4 OR-mask sets SMEP+SMAP, which the default `qemu64` model lacks (triple-faults on the CR4 store). Real silicon since Haswell/Ryzen supports both.
- **Read every bit of CR0/CR3/CR4 the next time a page-walk faults inexplicably** — the v1.27.1 memory-isolation closeout cost 14 days because SMAP=1 was visible in the original fault dump but went unread. Hardware access-control bits matter as much as page-table state.

## Rules (Hard Constraints)

- **Do not commit or push** — the user handles all git operations.
- **NEVER use `gh` CLI** — use `curl` to the GitHub API only.
- **Do not modify the Cyrius compiler from this repo** — compiler changes belong in `../cyrius/`. Cross-repo work means switching repos, not blurring boundaries.
- **No C or assembly files** — everything is Cyrius. Inline asm in `.cyr` files is fine; standalone `.c` / `.s` files are not.
- **Do not skip QEMU verification after kernel changes** — type-check and tests verify *code* correctness; only boot verifies *kernel* correctness.
- **Do not use inline asm without documenting the register contract** — every `asm { ... }` block gets a comment naming inputs, outputs, and clobbers. The `serial_putc` v1.21.0 → v1.26.0 disassembly investigation was readable only because the asm contracts were documented.
- **Do not invoke `cycc` / `cycc_aarch64` directly** — go through `cyrius build` (see Tools).
- **Do not hand-edit version strings** — `scripts/version-bump.sh` is the only correct way to bump the version. The `serial_println` calls have hardcoded byte lengths that must match the string; the script computes them.
- **Do not invent new project structure** — see Scaffolding.

## Process

### Work Loop

1. **Research** — check vidya for kernel patterns; read related architecture docs.
2. **Build** — ONE subsystem at a time. Never bundle.
3. **Test** — boot on QEMU after EACH change; check serial output. Bench harness runs to `=== done ===`.
4. **If broken** — revert to last-known-good, apply ONE change at a time.
5. **Audit** — verify multiboot header, ELF structure, memory map. Confirm the `Userland exec complete` marker fires (a KTEST boot; `ktest-smoke.sh` requires it). (`Memory isolation: PASS` was named here until 1.57.12 — its test left `main.cyr` on 2026-05-15, so no kernel prints it.)
6. **Document** — update [`CHANGELOG.md`](CHANGELOG.md), [`docs/development/roadmap.md`](docs/development/roadmap.md), [`docs/development/state.md`](docs/development/state.md) if release-worthy.

### Task Sizing

- **Small** — add a syscall, fix a bounds check: batch freely.
- **Medium** — new subsystem (e.g., scheduler): small bites, boot after each.
- **Large** — architecture port: plan first, prototype, then implement.

### When Stuck

Never decide to defer, slip, re-slot, or split work mid-execution unprompted. Splits are planned decisions made *before* starting; reactive scope changes when stuck are deferment. Report findings and wait for direction.

### Versioning

[`VERSION`](VERSION) is the single source of truth. Use `scripts/version-bump.sh`:

```sh
sh scripts/version-bump.sh 1.28.0
```

Updates `VERSION`, `kernel/agnos.cyr`, the three `serial_println` boot banners (auto-computes byte length), `CHANGELOG.md`, `docs/development/roadmap.md` (including the "Built with cyrius X.Y.Z" trailer, re-synced from `cyrius.cyml`), and `docs/development/state.md`. `cyrius.cyml` pulls the version via `${file:VERSION}` templating — no in-place edit needed.

Release flow: `version-bump.sh` → fill CHANGELOG entries → commit → `git tag` → push triggers `.github/workflows/release.yml`.

### Closeout (before any minor/major bump)

Ship as the last patch of the current minor (e.g., `1.27.2` before `1.28.0`).

1. **Full test sweep** — `scripts/check.sh` **39/40** at 1.57.14 (40 gates; the one red is the `syscall ABI` gate, red BY DESIGN until cyrius's peer carries `#109`–`#111` — filed there 2026-10-13; 38/39 at 1.57.13, 38/38 at 1.57.12), `scripts/test.sh` (x86) **4/4** (`--all` **8/8**), `scripts/sweep.sh` **73/74** on the 1.57.14 full sweep (the first on cyrius 6.6.20: 5,453 s; the one red is row 1 `baseline check.sh`, KNOWN RED by design on the ABI gate alone; 0 serial retries and no row re-run, with 19 firmware VOIDs (`gnoboot: fail @ EBS`) inside 12 rows, each relaunched within its row — two of them inside exec-redirect's nested agnsh-smoke, whose output that smoke discards, so they show only in its `agnsh.log.attempt*` files; the ZFS write row 5,324 s) (**72/73** on 1.57.13's: 5,110 s, 23 VOIDs inside 16 rows, the ZFS write row 4,957 s) (**71/71** on 1.57.12's: 5,485 s; 69 in the run — `doom` / `naad-ring3` need `DOOM_ROOT` / `NAAD_ROOT` when the tree is a worktree, whose `$ROOT/..` holds neither sibling, and passed on their re-run; `hid-mouse-deferred` / `pipeline` VOID in a worker copy whose QEMU monitor socket path exceeds the 108-byte `sun_path` and pass on the serial retry; the ZFS write row runs ≈ 83 min under the `# sweep-row-timeout:` its smoke declares, k.134) (**66/66** on 1.57.11's; run in PARALLEL since 1.57.9: 4 workers; a row whose red is by design or on a filed bug can be marked KNOWN RED — shown red, never retried — via `SWEEP_KNOWN_RED` / the 5th `run_gate` argument; none is marked at 1.57.12 (nor at 1.57.11, when the ABI gate's mark went stale as cyrius 6.7.6 carried `#106`–`#108`); 1.57.13 marks row 1 `baseline check.sh` again, on exactly that gate's FAIL lines, for `#109`–`#111`) — the row count is `grep -c '^run_gate "' scripts/sweep.sh` (**74** at 1.57.14, **73** at 1.57.13, **71** at 1.57.12, **66** at 1.57.11, **64** at 1.57.10, **59** at 1.57.9, 57 at 1.57.8, 51 at 1.57.7; `grep -c '^run_gate'` reads one more); 1.57.14 added 1 row (`sandhi-async-smoke`, group `hostport`) and widened two (kstack's `fault orphan` phase; klug-spill's owed-spill `fs_lock` check); 1.57.13 added 2 rows (`sock-send-dl-smoke` for `#109`, `tty-smoke` for `#110` / `#111` / SIGWINCH) and widened two (vtd boots the queued AND register interfaces, four boots; kstack's `tick orphan` phase); 1.57.12 added 5 rows (ktest — `ktest-smoke.sh`, `KTEST=1 ktest.sh` at `-smp 1` and `-smp 4`, which no row ran —, gpt-geometry, zfs write, klug-spill linear + wrapped — the spill had no row since 1.56.10) and widened one (zfs read became the ZFS read + write-gate row, `ZFS_SELFTEST=1 ZFS_WRITE_SELFTEST=1`); 1.57.11 added 2 rows (zfs read, zfs ring 3); 1.57.10 added 5 rows (vtd, ext2, blk-write, and fg split into default / recovery -smp 1 / recovery -smp 4); 1.57.9 added 2 rows (ahci-late, pipeline — green since agnoshi 2.0.3); 1.57.8 added 6 rows (ipc-wait, nvme-late, dma-shadow, xhci-shadow, hid-mouse-deferred, kvm-net-boot), 1.57.7 added 16 (msc-cdb, wait-ring3, wait-kbd, fg, lifecycle, tcp-inbound, sock-owner, sock-wait, tcp, loopback, tcp-listen, icmp, fault-kill, nbread, thread, doom). ⛔ `doom-smoke` had no row, so S6 shipped with `/bin/doom` hung in `#47` and every gate green. The `syscall ABI` gate was red by design at 1.57.10 until cyrius carried the `#106`/`#107`/`#108` peers (green from cyrius 6.7.6), and is red by design again from 1.57.13 until cyrius carries `#109`/`#110`/`#111` (`cyrius/docs/development/issues/2026-10-13-agnos-sys-*-peer.md`). The weighed-size row is a TRIPWIRE since 1.57.9 (grant `0x290000` since 1.57.12, `0x260000` at 1.57.11, derived from the layout wall) — gate 34 is the hard limit — any OTHER red is a real red. (1.57.6 added rows 32–35: `tsc-smoke` under `TSC_SELFTEST=1`, `spawn-smoke`, `exec-redirect-smoke` — which existed and nothing ran — and `kstack-smoke`, whose one row gates `-smp 1` AND `-smp 4`). ⭐ The 40th (1.57.14) is `smoke/harness hygiene` — `scripts/check/smoke-hygiene-check.sh`, a text + Python-ast walk over every `scripts/smoke`, `scripts/harness`, `scripts/tool` and `scripts/probe` file, because 1.57.13 fixed the sweep rows only and ~90 other smokes, ~40 harnesses and six QEMU drivers still defaulted siblings to `$ROOT/..` (empty from a worktree), bound QEMU sockets at fixed `/tmp/agnos-*.sock` names two trees share, logged to fixed `/tmp` paths, or built inside a sibling repo: it refuses a sibling default other than `${<NAME>_ROOT:-${SIBLINGS_ROOT:-$ROOT/..}/<repo>}` / `_siblings.sibling()`, a socket not from a TREE-ROOTED `smoke_qsock` / `qsock` (`qsock("x.sock")` hashes the same in every tree), a fixed `/tmp/<name>`, and any build in the scope of `cd "$<sibling>"`; its header lists the forms it does NOT follow — a green is not a proof. ⭐ The 39th (1.57.13) is `aarch64 compiles with no unresolved calls` — `build.sh --aarch64`, whose `scripts/check/placeholder-check.sh` scan refuses an image carrying cycc's unresolved-call placeholders, because the compiler said OK over 103 of them in the aarch64 build (see Quick Start; `build.sh` refuses the same in every x86_64 build) and nothing that runs automatically saw them. ⭐ The 38th (1.57.12) is `braces balanced (kernel/)` — `scripts/check/brace-balance-check.sh`, a pure text walk like the 35th, because cycc 6.6.6 accepts a stray top-level `}` without a diagnostic and silently drops every declaration after it (filed: `cyrius/docs/development/issues/2026-10-11-stray-top-level-brace-silently-ends-the-unit.md`); in the kernel the dropped definitions surfaced as 62 "undefined variable" errors in other files. ⭐ The 37th (1.57.11) is `host ZFS codec oracles` — `scripts/check/host-zfs-oracles.sh`: `kernel/core/zfs_codec.cyr` (SHA-256 / SHA-512/256 / fletcher / lz4 / lzjb / zle / gzip / ZAP hash) run on the host against Python/zlib vectors, mutation-proven — since 1.57.12 also `zfs_wenc.cyr`'s writer encoders (block pointers, the ZLE decision, space-map entries, the fat ZAP replayed byte for byte against OpenZFS's own blocks, UTF-8 validation): 2,332 cases at 1.57.12 (249 at 1.57.11). ⭐ The 36th (1.57.10) is `issue pointers resolve` — `scripts/check/issue-pointer-check.sh`: every `docs/development/issues/…` pointer in scripts/, tests/, kernel/ and docs/ must name a file that exists, because archiving an issue left 42 pointers dangling (it prints the MOVED path to write). ⭐ The 35th (1.57.5) is `preprocessor directives balanced (kernel/)` — `scripts/check/pp-balance-check.sh`, a pure text walk, because `main.cyr` carried a depth-0 `#endif` for months that cycc drops without a diagnostic (an upstream "unbalanced #endif" refusal would stop the whole kernel build there). The 34th (1.57.2, simplified 1.57.3; bound `0x390000` 1.57.7, `0x3D0000` 1.57.11, `0x400000` since 1.57.12) is `kernel image vs region-1 top (LOAD end <= 0x400000)` — `scripts/check/image-layout-check.sh`, because the embedded face put the LOAD end over the then-fixed AP stack window and no gate had ever measured that address; the AP stacks live in region 7 since 1.57.3. The 33rd is the `kernel source formatting` gate, wired at 1.56.60: `scripts/check/fmt-check.sh` had existed all along and check.sh never ran it, so a local full-green was reachable over an unformatted tree while CI (`ci.yml` Format check) would reject the push. Fix drift with `sh scripts/check/fmt-fix.sh`. ⛔ The sweep's 31st row (1.57.5) is `FS_SYSCALL_SELFTEST` → `fssys-smoke.sh`: `build.md` had called that flag "gated by sweep.sh" since 1.41.3 while nothing ran it, and the flag build had been un-buildable since cyrius 6.5.1. **A documented gate that nothing runs reads as coverage** — when a doc names a runner, grep for the row.
   ⚠ These counts were "11/11" and "`--all` 7/7" until 1.56.51 and neither was reachable: check.sh
   had grown to 30 gates (35 at 1.57.5), and `--all` topped out at 5 checks of which the aarch64 one was a
   FAIL until 1.57.13 (`--all` **8/8** since: x86 4 + aarch64 4). Re-read the tallies from a real run when you touch this list; do not copy them forward.
2. **Boot sweep** — boot via gnoboot + OVMF (`scripts/smoke/agnsh-smoke.sh`, or `scripts/ktest.sh`
   for the in-kernel suite) and confirm every named checkpoint: the banner (`AGNOS kernel v<VERSION>`) and the two
   `boot: … OK` layout lines (BSP boot stack, region 7 — agnsh-smoke requires both), `Userland exec complete` (a KTEST
   boot — `ktest-smoke.sh`, a sweep row, requires it), and `=== done ===` from the bench harness (`scripts/bench.sh`,
   which rewrites the tracked `BENCHMARKS.md` / `bench-history.csv`; last run at 1.56.60). ⛔ `Memory isolation: PASS`
   was named here until 1.57.12: the memory-isolation test left `main.cyr` on 2026-05-15 (Attempt 27), so no kernel
   has printed it since — a checkpoint nothing can meet reads as one nobody checked. ⛔ NOT `qemu -kernel`, which this
   step named until 1.56.51 — QEMU rejects the ELF64 image for want of a PVH note, so that command booted nothing.
3. **Dead-code audit** — review the `dead: <fn>` list from `cyrius build`; remove anything no longer earned. ⛔ **Waived** while the operator's standing rule *grow before refactor* (2026-10-11) stands — until the planned rewrite: nothing is trimmed, `#ifdef`-ed out or dead-code-audited for room (see the image-bound note under Architecture Notes). Record the waiver in the release's CHANGELOG Closeout.
4. **Code review pass** — walk the minor's diffs end-to-end for missed `#ifdef` guards (cross-arch leak class), unguarded asm, off-by-ones in fixup arithmetic, silently-ignored errors.
5. **Cleanup sweep** — stale comments referencing old version pins, dead `#ifdef` branches, unused includes, orphaned files in `build/`.
6. **Security re-scan** — quick grep for new raw `syscall(`, unchecked stores near MMIO addresses, unsanitized input paths.
7. **Doc sync** — `CHANGELOG.md` reflects the minor's arc; `roadmap.md` Active table moves resolved items to `## Completed (vX.Y.Z)`; `state.md` bumped at the release; `doc-health.md` refreshed for any docs touched.
8. **Version-verify gate** — `VERSION` == `git tag` == CHANGELOG header.

## Architecture Notes (load-bearing constraints)

These are *how the world is*, not *what we chose*. Reading the code alone won't tell you why these are this way.

- **`cyrius build -D NAME` does not propagate into nested `#ifdef` blocks reached via `include`.** Workaround: `scripts/build.sh` prepends `#define ARCH_X86_64` / `#define ARCH_AARCH64` to a temp source before invoking `cyrius build`. Don't try to `-D` the arch; it won't take.
- **`kernel/klib/` is the freestanding kernel stdlib** — `kstring`, `kfmt`, `ktagged`. Named `klib/` (not `lib/`) because cyrius wrapper reserves `./lib/` at compile cwd for its own stdlib-snapshot resolution; the distinct name eliminates shadow warnings and stomp risk if `cyrius deps` is ever run with non-empty `[deps] stdlib`. Don't move these files into `lib/`.
- **`proc.cyr`'s `proc_create_address_space` / `proc_get_user_cr3` / `proc_map_page` / `proc_unmap_page` are x86-specific** (PML4 → PDPT → PD walk, hardcoded `0x3000` kernel-PD address, KPTI entry-511 stash). They're guarded by `#ifdef ARCH_X86_64`; the aarch64 build uses no-op stubs from `arch/aarch64/stubs.cyr`. Pre-1.27.0 they were unguarded and "won" over the stubs under last-definition-wins. Don't drop the guard.
- **Memory-isolation test uses `stac`/`clac` brackets** around its user-page accesses. `proc_map_page` writes US=1 (`0x87`) per-process PD entries because the pages must be reachable from CPL=3; SMAP traps CPL=0 access to US=1 pages. If you write more kernel-mode code that touches per-process user pages, you need the same bracket discipline (or factor it into a `with_user_access(closure)` helper once there are 3+ sites).
- **`kernel/user/shell.cyr` is on the format-skip list** (CI `Format check` step). It carries `#ifdef` *inside function bodies*, which can't satisfy both the formatter (wants indentation) and the preprocessor (needs column 0). If you write more code with that shape, add it to the SKIP list; don't try to make the formatter happy.
- **`pmm_kva_for_access` (the direct-map alias) works only after `cr3_load(0x1000)`, not merely after `pmm_setup_directmap`.** Under gnoboot's boot CR3, `8 GB + phys` maps an unrelated identity GB, so a store through the alias lands nowhere at `-m 512M` and in someone else's RAM on a big box — `kfont_init` (1.57.2) measured exactly that (literals hashed clean in place, buffer read back all zeros) when slotted beside `fb_shadow_init`, which gets away with the early slot only because it uses the identity VA. Callers go after `pmm_bitmap_use_directmap()` — `chan_region_reserve` broke this until 1.57.8 (its band zeroing never landed; ~2 s of KVM MMIO exits). Driver DMA CPU pointers use the same alias through `dma_kva` since 1.57.8 ([`docs/architecture/dma-cpu-pointers.md`](docs/architecture/dma-cpu-pointers.md)); the phys lives only in descriptors and registers.
- **The kernel image must end at or below `0x400000` — the top of region 1 (PD[1]); since 1.57.12 region 1 holds ONLY the image.** VA `0x400000` (PD[2]) is ring-3 code in every process (every agnos ELF links there; the ELF loaders refuse anything lower), `pmm_init` reserves exactly `[0, 4 MB)` for the kernel and `sel_rip_is_kernel` treats `[0, 0x400000)` as kernel RIPs — so this is the LAST bound this layout allows: never a bigger number. **When a build nears it, MOVE bulk out of the image into the ROOM** (operator standing rule, grow before refactor, 2026-10-11: never trim, `#ifdef`-out or dead-code-audit code for room) — since 1.57.12 large module arrays first touched after the direct map is live sit in ONE 2 MB pmm carve-out (which arrays, their bytes and the headroom they bought: [`docs/architecture/kernel-image-room.md`](docs/architecture/kernel-image-room.md) and `state.md` — not here), `core/room.cyr` `room_init()` (main.cyr, after `fb_shadow_init` — whose contiguous run it must not split — and before `pci_scan`), reached only through the direct map like the region-7 stacks; each is a POINTER whose initial value is a POISON in PML4[0x140] (upper half, unmapped under every CR3), so a use before `room_init` is a CPL0 #PF that `exc_pf_report` / `room_pf_say` name (`PANIC: room: <array> used before the carve-out`). The klug ring takes the boot log in an 8 KB early ring until the move (Linux `setup_log_buf`). The room is CPU-only (never a DMA address) and holds no stacks; a poison faults by name only on a CPU dereference, so a bound test that can hand a kernel pointer to a device must also require `p > 0` (ext2's direct-DMA gates do). To move one more array: a `room_take` slot, `var NAME = <its poison>;`, every `&NAME` → `NAME`, its name in `room_say` — `image-layout-check.sh` (10) refuses a `&NAME` left behind, a wrong poison, and the array declared back into the image — and `build.sh` refuses such an image outright, plain builds included (moved to `build/agnos.layout-refused`; only an over-bound plain image is kept, for gate 34, and `smoke_require_image` will not boot it) ([`docs/architecture/kernel-image-room.md`](docs/architecture/kernel-image-room.md): the prior art, the CR3 audit, what stayed and why). Only past that does growth need an architectural change (a higher-half kernel, or a higher user link base). 1.57.12 (operator ruling: make room for the ZFS write path; compiler DCE was blocked on a cyrius bug) moved the BSP's two fixed region-1 stacks OUT: the **BSP boot stack is a 64 KB array in the image's own `.bss`** (`boot_shim.cyr` `var bsp_boot_stack[8192]`; the shim loads its address through the one statement `bsp_boot_stack_lo = &bsp_boot_stack;` — raw bytes cannot name a symbol — and the asm block after it turns that into the 16-byte-aligned top), and the **BSP `TSS.RSP0` is region-7 slot 0 `[0xFC0000, 0xFD0000)` via the direct map** (`gdt.cyr` `tss_get_cpu_stack` is one formula for every CPU; `proc_rsp0_top`'s fallback is `tss_get_cpu_stack(0)` — cpu 0's slot, never the calling CPU's, whose slot is an AP's live idle stack). Prior art: Linux (`init_stack` in `.data`), FreeBSD (`bootstack` in `.bss`), seL4 — the first stack is an image symbol. The boot stack has NO guard page (an overflow would write the `.bss` global below it — at 1.57.12 the raw-disk-write gate `blk_rw_armed`, and the neighbour changes with unrelated edits), so its lowest 8 KB is a RED ZONE: a canary (`proc.cyr` `bsp_stack_redzone_arm`, first thing in `main.cyr`) re-read on every exit from the stack (`sched_leave_old`, `sched_assert_oob`) — `PANIC: BSP boot stack red zone overwritten` + halt on one changed qword, denied by the smokes; gate 34 (7) keeps every kernel frame smaller than the zone, so a descent cannot step over it. A `KSTACK_HW=1` build paints the 56 KB above it and prints `kstack-hw: bsp boot stack max=… of 0xe000 usable`. Before 1.57.12 the bound was the boot stack's 64 KB budget under a fixed top: `0x3D0000` / top `0x3E0000` / RSP0 `0x400000` at 1.57.11 (the ZFS reader), `0x390000` / `0x3A0000` / `0x3C0000` from 1.57.7 (the IMG step), `0x370000` / `0x380000` before — "a number above the image end of the day", re-picked every time the image grew. At boot `kmain` prints `boot: BSP boot stack [0x…, 0x…) inside the loader-pinned image (EfiLoaderCode) OK` and `boot: region 7 [0xE00000, 0x1000000) is free RAM in the UEFI map OK` (`mbi.cyr` `uefi_span_check`; the violation lines are in `SMOKE_INVARIANT_DENY`, agnsh-smoke requires both OK lines). `build.sh` runs `image-layout-check.sh` after EVERY x86_64 build (a failing flag build is refused to `build/agnos.layout-refused`; CI runs it too), and the gate also decodes the shim's stack load from the image (`48 B8 &bsp_boot_stack … 48 05 00 00 01 00 … 48 89 C4`, the array inside `.bss`) and refuses any fixed region-1 `mov rsp`. "Under the 4 MB identity map" was the WRONG fit check while stacks lived in region 1: 1.57.2's embedded face carried the LOAD end to `0x35E770` and put the then-fixed AP1-3 stack windows `[0x310000, 0x340000)` inside `.rodata` — silently, through the RW 2 MB identity pages. 1.57.3 moved those windows into the region-7 kstack pool (`0xFC0000 + cpu·64 KB`, addressed through the DIRECT-MAP alias like every other region-7 stack, never PD[7]'s identity VA, which a large ELF overrides under its own CR3); since 1.57.6 region 7 is `[0xE00000,0xF00000)` 16 per-PROCESS kernel stacks (slot = pid) · `[0xF00000,0xF40000)` 4 kthread stacks · `[0xF40000,0xF80000)` IST1 `#DF` · `[0xF80000,0xFC0000)` FREE, reserved for an NMI/#MC IST · `[0xFC0000,0x1000000)` per-CPU `TSS.RSP0` slots (slot 0 the BSP's since 1.57.12, slots 1-3 the AP boot stacks), and the lowest 4 KB of every 64 KB slot is a not-present guard page (`gdt.cyr` + [`docs/architecture/kernel-stacks-and-preemption.md`](docs/architecture/kernel-stacks-and-preemption.md) carry the map; this note said "region 7 is now FULL" until 1.57.6 retired the per-CPU syscall stacks and `#37`'s second stacks). The BSP boot stack must stay mapped under every CR3 kmain runs under (live under gnoboot's CR3 from the shim's first instruction; kmain is switched out on it under per-proc CR3s), which the image's PD[0..1] is and a region-7 identity VA is not. `scripts/check/image-layout-check.sh` (check.sh gate 34) enforces the image bound; `ap-stack-smoke.sh` (-smp 4, re-hashes the face literals in place after the wake, and reads every `TSS.RSP0` back including the BSP's) enforces where the AP stacks are.
- **Every process runs its syscalls on its OWN kernel stack (1.57.6, Path 2 bites S3.1–S3.3).** Any path that makes a process current before ring 3 runs must call `kstack_install(pid)` (TSS.RSP0 + the per-CPU syscall top); `on_cpu(old) = -1` is written ONLY by `sched_frame_iretq`, after the CPU has left old's stack and CR3; every plain spinlock disables preemption and `sched_lock` is the innermost leaf. A switch path that forgets `kstack_install` leaves the PREVIOUS process's (valid) stack installed — `kstack_check_entry` latches `syscall: kernel stack is not the caller's`, and the production-path smokes deny it (`SMOKE_INVARIANT_DENY`). ⚠ The waits still hold their CPU until the rest of Path 2 lands (roadmap § 1.57.x). See [`docs/architecture/kernel-stacks-and-preemption.md`](docs/architecture/kernel-stacks-and-preemption.md).
- **The kernel-embedded face is folded in by `build.sh`/`test.sh`/`bench.sh` (`REKHA_DIR`/`REKHA_REF`), exactly like kashi, and `/fonts` is a prefix intercept in `open`/`stat`/`lstat`, NOT a mount** — `mlist.cyr:33` refuses backend ids > 3 and crab's volumes sidebar reads `mountlist`#104. See [`docs/architecture/kernel-font-namespace.md`](docs/architecture/kernel-font-namespace.md).
- **The boot shim must be the first top-level statement emitted under x86_64, and nothing ahead of it may touch the stack or RDI** — gnoboot jumps in with an undefined stack and RDI = `&boot_info`. cyrius v5.7.19+ emits kmode's PARSE_PROG before EMIT_GVAR_INITS (regression locked by cyrius's `check.sh` gate 4ab), but the shim is NOT the first code: cycc emits the top-level enum initialisations before PARSE_PROG in every mode — ~200 stack-free constant stores into `.bss` that run on gnoboot's stack (this note claimed the shim ran first until 1.57.12's review). `scripts/check/image-layout-check.sh` (8) walks the image from the entry `jmp` to the shim's first byte and refuses anything but those store shapes. See the `include` ordering in `kernel/agnos.cyr` and the comment above the `arch/x86_64/boot_shim.cyr` include.

## Docs Pointers

- [`docs/architecture/`](docs/architecture/) — system overview, non-obvious invariants.
- [`docs/audit/`](docs/audit/) — security audit reports (`YYYY-MM-DD-*.md`).
- [`docs/development/roadmap.md`](docs/development/roadmap.md) — completed, active, planned.
- [`docs/development/state.md`](docs/development/state.md) — live state snapshot, refreshed every release.
- [`docs/development/issues/`](docs/development/issues/) — open bug-investigation docs (one file per issue). **`archived/`** (not `archive/` — this line said the wrong name until 1.56.54) holds resolved ones with resolution notes. ⚠ **A resolved issue gets its Status header REWRITTEN before it is moved**, because the sweep of 2026-08-30 found that stale headers are the failure mode here, not missing files: `#98 ptrscan` still read "DESIGNED, UNBUILT" eleven cuts after it shipped, and `#97` read "bites 0-7 done" four cuts after bite 11. ⛔ **And check what the shipped change BROKE before archiving** — the pipes record looked like a clean ship and was hiding three unswept callers, one of them a boot hang.
- [`docs/development/proposals/`](docs/development/proposals/) — pre-decision design drafts.
- [`docs/development/kybernet-bridge.md`](docs/development/kybernet-bridge.md), [`security-hardening.md`](docs/development/security-hardening.md), [`syscall-additions.md`](docs/development/syscall-additions.md) — long-form design notes.
- [`docs/doc-health.md`](docs/doc-health.md) — fresh / stale / archive / open-question ledger across this whole repo's docs. Refreshed in place when docs are touched.

New non-obvious invariants land in `docs/architecture/`. New deferred bugs land in `docs/development/issues/` with the date-stamped naming convention. **Never renumber numbered series.**

Full doc-tree convention: [first-party-documentation.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md).
