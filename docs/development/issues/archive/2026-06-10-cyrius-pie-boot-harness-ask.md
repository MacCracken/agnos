# Cyrius PIE codegen has shipped — AGNOS `--pie` boot harness is the remaining gate for full KASLR (Option A)

> **Status**: ✅ **RESOLVED — the harness was built + the kernel-PIE path boot-validated (closed 2026-06-30, archived).** The agnos-side boot harness this ask requested is **`scripts/kaslr-smoke.sh`**, and **full-binary KASLR (Option A) shipped + boot-tested at 1.47.3/1.47.4**: `CYRIUS_PIE=1` builds a relocation-free ET_DYN / RIP-relative kernel, gnoboot 0.6.0 picks an RDRAND-slid 2 MB-aligned base, and `kaslr-smoke.sh` proves a two-boot base-diff PASS with `exec-smoke` full-pass under PIE (boot-to-shell + exec-from-disk, e2fsck-clean, on a slid kernel). So the kernel-PIE wrapper is no longer "structurally validated but never booted" — it boots. (Original status below: *OPEN — kernel-side harness ask; the cyrius PIE dependency is MET, what remains is an agnos-side boot harness.*)
> **Filed**: 2026-06-10 (cyrius deep-dive review, v6.1.31)
> **Severity**: MEDIUM — unblocks full-binary KASLR (audit S7 / kaslr-scope
> Option A); not MVP-gating (data-only KASLR shipped v1.28.0).
> **Cross-ref**: `proposals/2026-05-11-kaslr-scope.md` (Option A), this repo's
> `docs/audit/2026-04-13-security-audit.md` S7; cyrius
> `docs/development/issues/2026-06-10-roadmap-drift-and-stale-docs.md` (RM-03,
> the AGNOS-kernel goal's tracking home) + `proposals/2026-05-11-pie-support.md`.

## Summary

`kaslr-scope.md` Option A (full binary relocation / classic KASLR) was deferred
with one explicit blocker: *"Full KASLR becomes a candidate **once cyrius ships
PIE codegen**."* That blocker is now cleared:

- **Userland PIE** shipped cyrius **v6.1.6** (x86_64) + **v6.1.8** (aarch64) —
  `--pie` / `CYRIUS_PIE=1` emits ET_DYN, RIP-relative, validated by running the
  full tcyr corpus as ASLR'd PIE.
- **Kernel-PIE ELF wrapper** shipped cyrius **v6.1.7** — `EMITELF64_KERNEL` under
  `--pie` emits **ET_DYN + `p_vaddr=0` + `e_entry=0xA8`** with a RIP-relative
  `.text` (the kernel path is `ET_EXEC` at fixed `0x100000` today). This is
  structurally validated cyrius-side but has **never been boot-tested** — there
  is no agnos harness to boot an ET_DYN kernel.

So the compiler half of Option A exists. The remaining work is entirely
agnos-side: a boot shim that can load a position-independent kernel, and a CI
harness that proves it.

## The ask (kernel-side)

1. **Boot shim ET_DYN support** (`kernel/arch/x86_64/boot_shim.cyr`) — when
   booting a `--pie` kernel: pick a random slide (the RDRAND/`kaslr_seed`
   plumbing from kaslr-scope step 1 already exists), slide the single `PT_LOAD`
   segment, and jump to `base + e_entry` (`0xA8` for the cyrius kernel-PIE
   wrapper). Per kaslr-scope Option A: a 2 MB-granular slide window above
   `0x100000` preserves huge-page alignment.
2. **`--pie` build path** — a build variant that compiles the kernel with
   `CYRIUS_PIE=1` (produces the ET_DYN image) alongside the existing fixed-address
   build, so both can be exercised.
3. **Two-boot base-diff CI assertion** — mirror Option B's step-6 check
   (`boot-test` asserts two consecutive boots produce *different* base addresses,
   read from a serial-print probe) but for the **kernel image base**, not just
   the heap base. This is the "validate on hardware, not a checkmark" gate cyrius
   requires before promoting the kernel-PIE wrapper out of structural-only status.
   A `KASLR_SEED` fixed-seed hatch (kaslr-scope step 5) keeps debugging
   deterministic.

## What cyrius provides

The kernel-PIE ELF already emits correctly:
`cat <kernel.cyr with 'kernel;'> | CYRIUS_PIE=1 build/cycc > k.elf` →
ET_DYN, `p_vaddr=0`, `e_entry=0xA8`, RIP-relative `.text`. If the boot shim needs
a different entry convention, a multiboot2-variant `_start` or a relocation-table
emit, file the specific shape back as a cyrius issue and the cyrius agent will
extend `EMITELF64_KERNEL` — the codegen is proven, only the wrapper shape is
negotiable.

## Validation

OVMF + QEMU two-boot: build the `--pie` kernel, boot twice, assert the
serial-printed kernel base differs between boots and the kernel reaches its
normal boot milestone both times. Once green, cyrius promotes the kernel-PIE
wrapper from structural-only to boot-validated and aarch64 kernel-PIE follows.

## Note for the cyrius roadmap

This closes the "kernel-PIE gnoboot-boot validation" follow-on that cyrius has
been carrying as consumer-gated (cyrius `state.md` Kernel-PIE readiness note +
roadmap bug-bandwidth). When/if the kernel agent picks this up, ping the cyrius
side so the dependency is marked live rather than indefinitely deferred.
