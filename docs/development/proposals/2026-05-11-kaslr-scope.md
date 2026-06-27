# KASLR Scope: Full Relocation vs Data-Only

**Status**: Option B (data-only) shipped **1.28.0**. Option A (full-binary) **SHIPPED 1.47.4** (+ gnoboot 0.6.0) — a relocation-free PIE (ET_DYN) kernel, RDRAND-slid 2 MB-aligned base in [32 MB, 254 MB), no boot-shim relocation walk needed. The "compiler work — cyrius doesn't have a PIE mode" cost below was overtaken by cyrius v6.1.6/6.1.8 PIE codegen (`CYRIUS_PIE=1` → ET_DYN, RIP-relative). See CHANGELOG [1.47.4] + `scripts/kaslr-smoke.sh`.
**Date**: 2026-05-11
**Affects**: `kernel/arch/x86_64/boot_shim.cyr`, `kernel/core/pmm.cyr`, `kernel/core/heap.cyr`, `kernel/core/proc.cyr`. Possibly `kernel/agnos.cyr` and `kernel/core/main.cyr` if full relocation is chosen.
**Related**: Security Hardening item S7 (last open from the 2026-04-13 audit); roadmap entry for v1.28.0.

## Problem

AGNOS loads at a fixed virtual address (`0x100000` per `kernel/arch/x86_64/boot_shim.cyr`). Every kernel symbol's address is therefore knowable to an attacker who reads the released ELF. ROP gadget addresses, kernel function entry points, and dynamic data layouts (heap base, `proc_table[]`, `vfs_table[]`) are all predictable.

S7 in the 2026-04-13 audit flagged this as **MEDIUM** severity — exploitable in combination with another bug, not directly. The mitigation is to randomize where kernel code or kernel data lives so attackers can't pre-compute gadget chains.

There are two scopes for AGNOS-side KASLR. The trade-offs are large enough to call out before implementing.

## Option A — Full Binary Relocation (classic KASLR)

Make the kernel binary itself relocatable. Boot shim picks a random slide; entry point and all internal references shift by the slide.

### What changes
- **Boot shim** reads entropy (RDRAND), computes a slide value within an allowed range (e.g., 64 MB window above `0x100000` in 2 MB increments to preserve huge-page alignment).
- **Kernel binary becomes PIE** or carries a relocation table. Either the cyrius compiler grows a `-fPIE` mode, or the build emits a `.rel.dyn` table that the boot shim walks before jumping.
- **Page tables** rebuilt to identity-map the slid physical region.
- **All hardcoded addresses** become slide-relative: `0x1000` page-table base, `0x100000` kernel base, `0x200000` available-memory floor, etc.
- **Symbol references** within the kernel (function pointers, ISR table entries built at runtime) all need slide-aware handling.

### Cost
- **Compiler work**: cyrius doesn't have a PIE mode today. The cross-repo work is filed at [`cyrius/docs/development/proposals/2026-05-11-pie-support.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md) and slotted as a **v6.1.x** candidate in cyrius's roadmap (after the v6.0.0 rename + cleanup arc). Hand-rolled relocation table is the kludge alternative — kernel-only but fragile, rejected in the cyrius proposal for the same reasons.
- **Boot complexity**: the boot shim grows substantially. Today it's ~150 lines of hand-encoded asm; with relocation, double that.
- **Debugging cost**: every kernel address in serial output / fault dumps becomes slide-relative. Need a slide-aware symbolizer to make sense of crash data. The v1.27.1 SMAP debugging cost 14 days; full-KASLR debugging would be even harder without tooling.
- **Multi-session**: realistically 1.28.0 + 1.28.0.1 + 1.28.0.2 to land safely.

### Benefit
- Defeats *all* classes of pre-computed gadget attacks against the kernel binary.
- Matches the "classic" KASLR design that Linux and the BSDs ship.

## Option B — Data-Only KASLR (recommended for 1.28.0)

Keep the kernel binary at fixed `0x100000`. Randomize the **location of kernel-managed dynamic data** within the available physical memory.

### What changes
- **Boot shim** unchanged.
- **Kernel binary** unchanged — stays at `0x100000`.
- **PMM bitmap** still at its current location, but the **first-page-hint** seed comes from RDRAND so the bitmap is consulted in shuffled order. Heap, proc_table, vfs_table allocations land at randomized offsets within the available physical memory.
- **Kernel stack** for each ring-3 transition pulls from a randomized slot within the per-CPU stack pool.
- **`proc_table[]`** and **`vfs_table[]`** still globals, but if we move them behind allocators (which is roughly the v1.28.3 struct-refactor scope), they'd land at randomized offsets too. v1.28.0 can defer that bit and just randomize the *heap* layout, leaving the static globals where they are.

### Cost
- **PMM tweak**: 20–50 lines. Add an RDRAND-seeded next-page hint that biases `pmm_alloc` toward a randomized starting offset on each boot.
- **Heap tweak**: bias `heap_init` to start at a randomized 2 MB-aligned offset within the available physical memory band (16 MB – end-of-RAM).
- **No compiler work.** No boot shim changes.
- **Debuggable**: addresses still print in their natural form; only the relative offset of heap-allocated structures changes per boot. Symbolizing a fault dump still works the same way.
- **Single-session land**: realistically 1.28.0 in one patch.

### Benefit
- Defeats trivial heap-layout ROP: an attacker who guesses heap addresses based on a prior boot's layout sees a different layout on the next boot.
- Does *not* defeat attacks against the kernel binary itself — function-entry addresses are still predictable. That's the limit of this scope.
- Sets the foundation for full KASLR later: the PMM-shuffle / heap-base-shuffle code is reusable when (if) we do full relocation.

### What this does NOT defend against
- Pre-computed gadgets in the kernel binary (the binary is still at a known address).
- An attacker who can read kernel memory and discover the randomized base before exploiting.
- Side-channel leaks of the randomization seed.

## Recommendation

**Ship data-only KASLR as 1.28.0.** It's the right scope for a focused minor.0 release: closes Security Hardening S7 in its bounded form, lands in one session, builds the entropy + shuffle plumbing we'd need for full KASLR anyway. Full KASLR becomes a candidate **once cyrius ships PIE codegen** ([`cyrius/proposals/2026-05-11-pie-support.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/proposals/2026-05-11-pie-support.md), slotted for v6.1.x post-v6.0.0); until then it stays Planned with the dependency visible.

Reframe the S7 line in the roadmap to be explicit that v1.28.0 is the data-only scope; full relocation stays open as a 1.29+ candidate.

## Work breakdown for Option B (the 1.28.0 plan if approved)

1. **Entropy source** — add `rdrand()` helper to `kernel/arch/x86_64/io.cyr` (3 bytes inline asm: `0F C7 F0` for `rdrand eax`, then `48 0F C7 F0` for `rdrand rax`). aarch64 already has `rdtsc`-equivalent via `mrs CNTVCT_EL0`; reuse as the entropy source there (lower-quality but acceptable for KASLR).
2. **PMM seed** — in `pmm_init`, after the bitmap is set up, set the `next_free` hint to `rdrand() % pmm_total`. Existing `pmm_alloc` walks forward from the hint, wrapping; first allocations land at random offsets.
3. **Heap base shuffle** — in `heap_init`, instead of pinning the heap base to a fixed address, pull a 2 MB-aligned slot from PMM and use that as the heap start.
4. **Per-CPU stack pool** — for SMP, allocate one extra page per CPU and use `rdrand()` to pick the within-page offset for the stack top. (Stack still grows down from a 4 KB-aligned base; the randomization is the *which page* in the pool.)
5. **Boot reproducibility hatch** — when `MEMORY_ISOLATION_TEST` or other debugging modes are active, optionally honor a fixed seed (e.g., from a `KASLR_SEED` environment-style mechanism, or a compile-time `#define KASLR_SEED 0xdeadbeef`) so debugging is deterministic. Document the hatch in CLAUDE.md's Architecture Notes.
6. **CI assertion** — `boot-test` job adds a check that two consecutive boots produce *different* heap base addresses (read from a serial-print probe added at boot). Without this, randomization could silently regress to no-op and we wouldn't catch it.
7. **CHANGELOG** — document the scope explicitly: "1.28.0 ships data-only KASLR; full binary relocation deferred. See `proposals/2026-05-11-kaslr-scope.md`."

Estimated diff: 100–200 lines across `pmm.cyr`, `heap.cyr`, `io.cyr`, `boot_shim.cyr` (for SMP stack pool only), plus boot-test assertion in CI. One session.

## Open questions

- **`rdrand` availability on the QEMU runner.** Default `-cpu max` exposes RDRAND, but if a future CI runner used `-cpu Haswell` (no RDRAND on some Haswell SKUs) or anything older, we'd need a software fallback. **Decision**: assume RDRAND for v1.28.0; fall back to `rdtsc & 0xFFFFFFFF` if `rdrand` returns 0 with carry-flag clear (the per-Intel-SDM failure mode). Document the fallback.
- **Should `KASLR_SEED` be a compile-time `#define` or runtime cmdline?** Compile-time is simpler and matches the existing `MEMORY_ISOLATION_TEST` shape. Multiboot1 cmdline parsing isn't wired today. **Decision**: compile-time `#define KASLR_SEED <hex>` for 1.28.0; cmdline-driven seeding is a 1.29+ enhancement once we wire multiboot args.
- **Does the v1.27.1 memory-isolation test need any update?** The test allocates two `phys` regions at fixed addresses (`0xE00000`, `0x1000000`) and calls `pmm_set` to mark them used. Under KASLR these addresses might already be the random heap start. **Decision**: add `pmm_is_free` checks before claiming, fall back to the next free 2 MB-aligned region if collision; OR mark the test as requiring a fixed seed (matches the `MEMORY_ISOLATION_TEST` reproducibility hatch above). Lean toward the seed approach — simpler.

## Decision required

- [ ] Approve Option B (data-only KASLR) as the 1.28.0 scope.
- [ ] Approve the 7-step work breakdown.
- [ ] Approve the `MEMORY_ISOLATION_TEST` seeded-reproducibility hatch.

Promote this proposal to an ADR if approved — it carries enough "why not the other thing" content to be worth durable capture.
