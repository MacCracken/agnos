# Proposal: Restore boot-shim ordering for `kernel;` shape under cc5

**Status**: **resolved** — cyrius shipped Path A1 at v5.7.19 (2026-04-27); see [Resolution](#resolution-2026-04-27).
**Date**: 2026-04-27
**Target**: agnos 1.24.0 (gated on cyrius v5.7.19)
**Affects**: `kernel/arch/x86_64/boot_shim.cyr` reachability,
            `kernel/agnos.cyr` boot path,
            agnos `cyrius.cyml` toolchain pin.
**Author**: Robert MacCracken

## Summary

agnos 1.23.0 shipped on cyrius 5.7.12 (the toolchain bump from 3.9.8).
The kernel **compiles cleanly, passes `scripts/test.sh --all` (7/7),
and produces a multiboot1-valid 32-bit ELF** — but it **does not boot**.
QEMU sits at the BIOS reset vector; the CPU triple-faults on the very
first instruction the multiboot loader hands us.

Root cause: cc5's `kernel;` shape (`kmode == 1`) emits global-variable
initializer code **before** top-level `asm { ... }` blocks. AGNOS's
32→64 long-mode shim lives in a top-level asm block in
`kernel/arch/x86_64/boot_shim.cyr`. So the kernel jumps from the
multiboot entry into 64-bit gvar-init code while the CPU is still in
32-bit protected mode — instant `#GP` cascade → triple fault → reset.

cc3 (3.9.8 era) emitted top-level asm at the entry point ahead of any
gvar inits, so the shim ran first, transitioned to long mode, and only
*then* did 64-bit code execute. That ordering invariant is what
v1.21.0–v1.22.0 of agnos depended on, and what cc5 silently dropped.

The "QEMU Boot Test" CI job is marked `continue-on-error: true`, which
is why this slipped past the 1.23.0 release gate. That flag is itself a
finding (see *Out of scope* below).

## Resolution (2026-04-27)

**cyrius v5.7.19 ships Path A1.** The slot reclaimed v5.7.20 → v5.7.19
because cyrius's v5.7.18 (full regex engine) closed ahead of schedule
and the v5.7.20 placeholder was dropped once this proposal confirmed
kmode IS the entire agnos request.

**Implementation** (cyrius `src/main.cyr` ~line 982): `EMIT_GVAR_INITS`
and `PARSE_PROG` wrapped in a kmode-conditional. Under `kmode == 1`,
the order becomes `STI → PARSE_PROG → warnings → EMIT_GVAR_INITS`
(top-level asm runs first, transitions to long mode, then 64-bit
gvar inits work as designed). Non-kmode (executable / object /
shared) modes keep the original `EMIT_GVAR_INITS → STI → warnings →
PARSE_PROG` order so cc5 self-host stays byte-identical for the
common path.

**cyrius metrics**:

- cc5 self-host two-step byte-identical at **716,080 B** (was
  715,920 B; +160 B for the kmode branch). Non-kmode path
  byte-identical.
- New regression gate `tests/regression-kmode-emit-order.sh`
  (gate 4ab in `scripts/check.sh`): compiles a minimal `kernel;`
  source with a 4-byte top-level asm marker (4× HLT, `f4 f4 f4 f4`)
  + a single gvar init (`var marker_var = 0xDEADBEEF;`); asserts
  the asm-marker file offset is **less than** the first `48 b9`
  (REX.W mov rcx, imm64) gvar-init signature.
- `check.sh` 39/39 PASS (was 38/38; +gate 4ab). The kmode emit-order
  invariant is now locked in and any future regression caught at
  cyrius CI time, not at downstream agnos boot time.

**Action items for agnos 1.24.0**:

1. Bump `cyrius.cyml [package].cyrius` to `5.7.19`.
2. Remove `continue-on-error: true` from the **QEMU Boot Test** job
   in `.github/workflows/ci.yml`. Replace with an output assertion:
   ```yaml
   - name: Boot test
     run: |
       timeout 10 qemu-system-x86_64 -kernel build/agnos -nographic \
         -serial file:build/boot.log -no-reboot -d cpu_reset 2>&1 || true
       grep -q "AGNOS kernel v" build/boot.log
   ```
3. Cross-check the kernel boots on real hardware (or `qemu-system-i386`
   with `-cpu max`) — gate 4ab verifies emit ORDER, but agnos's actual
   shim transition is what reaches long mode. Smoke test required.

**cyrius-side follow-ups (out of scope here, tracked on cyrius
roadmap)**:

- **Path A2** (skip `EMIT_GVAR_INITS` entirely under kmode and emit
  constants into `.data` directly) is cleaner long-term — matches
  the conventional kernel "data preloaded by loader" model — but a
  bigger change. Pinned in cyrius CHANGELOG v5.7.19 entry as a
  future patch if a kmode consumer earns it.
- The cc4→cc5 IR overhaul at cyrius v5.0.0 silently dropped this
  ordering invariant. The lesson — kmode (and other specialized
  emit modes: `_TARGET_MACHO`, `_TARGET_PE`, future
  `_TARGET_RISCV`) need explicit `check.sh` gates that lock their
  contracts. Gate 4ab is the first; cyrius will mirror it for
  Mach-O / PE / future targets per the precedent.

## Background

### What `kernel;` shape promises

A Cyrius source declared with `kernel;` (token 56 in the parser) sets
`kernel_mode = 1` at `cyrius/src/main.cyr:736` and routes through three
kmode-specific code paths in cc5:

- `cyrius/src/backend/x86/fixup.cyr:95` — entry VA forced to `0x100060`
- `cyrius/src/backend/x86/fixup.cyr:600`–`665` — `EMITELF_KERNEL` writes
  a 32-bit ELF (`e_machine = 3`, `EI_CLASS = 1`) with a multiboot1 header
  at offset 84, base VA `0x100000`, single RWX `LOAD` segment
- Skipped CRT-style prologue that user/shared/object modes get

Multiboot1 (per the GRUB spec, section 3.2) hands the kernel control
**in 32-bit protected mode** with paging disabled, A20 enabled, and a
flat 0–4GB code/data segment. To run the rest of the kernel (which is
64-bit code under cc5), the kernel must transition CPU mode itself: set
up PML4/PDPT/PD identity-mapping the first 16MB, enable PAE in CR4, set
LME in IA32_EFER (MSR 0xC0000080), enable PG in CR0, far-jump through a
GDT with a 64-bit code segment, then run 64-bit code.

That entire transition is hand-encoded in `boot_shim.cyr` as raw
opcodes inside an `asm { … }` block, ending with `48 89 e5`
(`mov rbp, rsp` in long mode) so 64-bit code can fall through.

### What cc5 actually does

cc5's emit pipeline for kmode==1, traced through `cyrius/src/main.cyr`:

| Step | Site | What's emitted |
|------|------|----------------|
| 1 | `main.cyr:657` | `0xE9 ?? ?? ?? ??` — entry-point JMP placeholder |
| 2 | Pass 2 | All defined fn bodies (64-bit code) |
| 3 | `main.cyr:955` | `EPATCH(jmp_patch)` — JMP target patched to "here" |
| 4 | `main.cyr:963`–`992` | `EMIT_GVAR_INITS` — every `var x = expr;` becomes `mov rcx, addr_imm64; mov [rcx], val` |
| 5 | `main.cyr:992` | `PARSE_PROG` — top-level statements (incl. `boot_shim.cyr`'s `asm { }` block) |
| 6 | `main.cyr:1003` | `EEXIT` — `syscall(60, exit_code)` |

So the post-jump layout is `[gvar inits][top-level asm][exit]`. The
boot shim is in step 5 but unreachable because the CPU triple-faults
in step 4.

### Verified in the agnos 1.23.0 binary

`scripts/build.sh` produces `build/agnos` (248,720 B). With the binary
in hand:

```
Entry VA: 0x100060
Bytes at entry: e9 05 97 01 00         ; jmp +0x19705
JMP target VA: 0x11976A
Bytes at target: 48 b9 30 3b 12 00 00 00 00 00 48 89 01
                 ;          ^^^ REX.W mov rcx, imm64; mov [rcx], rax
                 ; pure 64-bit gvar-init code

Boot shim signature (BC 00 00 20 00 BA F9 03 …) found at file offset
0x19c2e → VA 0x119c2e. Reachable from entry via fall-through? No —
gvar inits #GP first.
```

QEMU `-d int,cpu_reset` confirms the failure mode: `CPU Reset` event
on first instruction, no serial output ever produced.

### How v1.21.0 worked under cc3 / 3.9.8

cc3 (per `cyrius/CHANGELOG.md` entry for v1.0.0, "AGNOS kernel
(58KB, …): multiboot1 boot, **32-to-64 shim**, …") emitted the
top-level asm block contiguous with the entry point — either by
ordering top-level statements before gvar inits, or by not emitting
runtime gvar inits at all in kmode==1 (relying on the .data section
being preloaded by the multiboot loader, which is the conventional
kernel pattern). Either ordering would have placed the boot shim's
`bc 00 00 20 00` (mov esp, 0x200000) right at or near 0x100060.

That ordering invariant is undocumented in the cyrius source comments
and was effectively load-bearing for every agnos release since the
kernel was first written.

## Decision

Three paths considered. Recommendation in **bold**.

### Path A — **Fix cyrius compiler (recommended)**

Restore the kmode==1 ordering invariant in cc5. Two viable variants:

- **A1: Swap emit order under `kmode == 1`** — at `main.cyr:963`–`992`,
  call `PARSE_PROG` before `EMIT_GVAR_INITS`. Top-level asm runs first,
  enters long mode, then 64-bit gvar inits work as designed.
  ~5-line diff guarded by `if (kmode == 1)`.
- **A2: Skip `EMIT_GVAR_INITS` under `kmode == 1` entirely** — kernel
  global initializers are stored in the .data section directly (already
  initialized when the multiboot loader copies the LOAD segment into
  RAM). This is the conventional kernel build model and matches what
  cc3 appears to have done. Slightly bigger change because the
  emission site needs to constant-fold each initializer at compile
  time and write into the data section instead of running runtime
  init code.

Either way, the agnos kernel side stays untouched: `boot_shim.cyr`
keeps its current shape, the include order in `agnos.cyr` doesn't
move, no other kernel source file changes.

**Pro:** Correct fix at the layer where the regression was
introduced. All future kernel projects (not just agnos) benefit.
Restores the invariant cc3 had so the cyrius "kernel shape"
contract is stable across major versions.

**Con:** Requires a cyrius patch release (shipped at **v5.7.19**;
slot reclaimed v5.7.20 → v5.7.19 since cyrius's v5.7.18 closed
ahead of schedule) and a corresponding pin bump in agnos `cyrius.cyml`.
Cross-cutting: any other consumer of `kernel;` shape needs to be
re-tested against the new emit order.

**Acceptance gate:** A boot test with serial-output assertion (no
more `continue-on-error`) against agnos `kernel/agnos.cyr` —
`grep -q "AGNOS kernel v" build/boot.log` after a 10-second QEMU
run.

### Path B — Pin agnos to a known-working cyrius

Bisect 4.x → 5.7.x for the last cyrius release where `kernel;` shape
boots an unmodified agnos. Pin `cyrius.cyml` there, ship 1.24.0 as a
"works again" release, file the cc5 regression as a separate cyrius
issue.

**Pro:** Unblocks agnos immediately without waiting on a cyrius
release.

**Con:** Forces agnos onto a cyrius version drift from kybernet,
breaking the "whole base-OS stack on one cyrius" alignment that
1.23.0 was built around. The whole reason for the 1.23.0 toolchain
bump in the first place.

**Sub-question if pursued:** Was kmode==1 ever correct in 5.x? The
v5.0.0 changelog notes the cc4→cc5 IR overhaul; if the gvar-init
pass was added or moved at v5.0.0, every 5.x release has been
broken for kernels and Path B reduces to "stay on 4.x." 4.x's last
release per cyrius CHANGELOG is 4.10.3 (2026-04-15). Bisect needed.

### Path C — Refactor agnos to remove gvar initializers

Rewrite every `var foo = INIT;` in kernel code as `var foo = 0;` plus
an explicit `init_globals()` call from `kmain` *after* the shim has
transitioned to long mode. Audit needed across:

- `kernel/arch/x86_64/*.cyr` (14 files; e.g. `apic_base = 0xFEE00000`,
  `apic_enabled = 0`, `timer_ticks = 0`, etc.)
- `kernel/core/*.cyr` (17 files)
- `kernel/lib/*.cyr` (2 files, kernel-safe stdlib)
- `kernel/user/*.cyr` (3 files)

Roughly 40–80 initializers to relocate, plus an `init_globals()`
function plus a wire-up in `kmain` ahead of any subsystem init.

**Pro:** Works against any cc5. agnos becomes more portable across
future compiler ordering changes.

**Con:** Multi-day refactor. Burns the kernel-conventional "data
section preloaded" model in favor of explicit init-from-zero, which
also means we need to be careful about init order between
subsystems (e.g. PMM must be initialized before any subsystem that
allocates). Path A makes this tradeoff irrelevant.

## Recommendation

**Path A1** (swap emit order under kmode==1 in cyrius). It's a
one-place fix in the layer where the regression actually lives, it
preserves the agnos-side kernel architecture as written, and it
restores the cc3-era invariant so the `kernel;` shape contract is
the same across cyrius major versions. A2 is cleaner long-term but
requires more compiler work; A1 ships in a single cyrius patch slot.

Implementation sketch for A1:

```cyrius
# cyrius/src/main.cyr around line 963
var _km = L64(S + 0x18FCA0);
if (_km == 1) {
    # Kernel mode: top-level asm (boot shim) must execute before
    # 64-bit gvar initializer code. Multiboot hands control in
    # 32-bit protected mode; gvar inits are 64-bit and would #GP.
    PARSE_PROG(S);
    EMIT_GVAR_INITS(S);
} else {
    EMIT_GVAR_INITS(S);
    PARSE_PROG(S);
}
```

Plus a regression test: a minimal `kernel;` source with one
top-level `asm { … }` block and one `var x = 100;`. Build it,
disassemble entry+5: the asm bytes from the source must appear
*before* any `48 b9` / `48 89 01` (REX.W mov rcx, imm64; mov [rcx],
rax) sequences.

## Out of scope (filed separately)

1. **`continue-on-error: true` on the QEMU Boot Test job in
   `.github/workflows/ci.yml`** — this is what let 1.23.0 ship
   broken. Once Path A lands and the kernel actually boots, that
   flag should be removed and the boot output asserted against
   `grep -q "AGNOS kernel v"`. Tracked for 1.24.0 alongside the
   toolchain re-pin.

2. **Boot-shim asm bytes are unaudited.** The current `boot_shim.cyr`
   is a hand-encoded byte sequence with no inline comments mapping
   bytes back to instructions. While debugging this regression would
   have been easier with disassembled comments, that's a hygiene
   item, not a correctness fix. Pin for a later cleanup.

## References

- `kernel/arch/x86_64/boot_shim.cyr` — the 32→64 long-mode shim
- `kernel/agnos.cyr:65` — include site (currently inside the
  `#ifdef ARCH_X86_64` extension block, which works once Path A
  ships but is documentation-worthy)
- `cyrius/src/main.cyr:657, 736, 955-1003` — kmode==1 emit pipeline
- `cyrius/src/backend/x86/fixup.cyr:93–95` — kmode==1 entry VA
- `cyrius/src/backend/x86/fixup.cyr:600–665` — `EMITELF_KERNEL`
- `cyrius/CHANGELOG.md` v5.0.0 (2026-04-15) — cc4→cc5 IR overhaul,
  likely regression introduction point (bisect needed to confirm)
- `docs/development/security-hardening.md` — current kernel boot
  description, will need a one-line note that "shim runs at entry
  via the cc5 kmode==1 emit ordering invariant" once A1 ships
- Multiboot1 specification §3.2 — entry-state contract (32-bit PM,
  paging off, GDT undefined, ESI = info, EAX = magic)
