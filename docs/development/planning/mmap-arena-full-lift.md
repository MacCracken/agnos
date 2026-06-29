# User mmap-arena full lift — design + bite plan (1.50.2+)

**Goal (user, 2026-06-29):** let a single process `mmap` *many GB*, up to machine RAM — not the current ~768 MB cap — on a 62 GB+ box. Chosen approach: a **high-VA anonymous arena backed by the direct-map**.

## Current state (the cap)

- `sys_mmap` (`kernel/core/proc.cyr`) bumps a **global** cursor `mmap_next_vaddr` through `[0x10000000, ~0x3FA00000)` = `[256 MB, ~1 GB)`, 2 MB pages, ~768 MB usable.
- The arena lives in the per-process **0–1 GB PD** (PD slots 128..511). It can't grow down (kernel identity owns 0–256 MB) or past 1 GB (PDPT[1] is the next 1 GB region).
- Two caps: (1) the cursor is global (arena shared across all procs); (2) a single proc tops out at ~768 MB.

## VA layout (why PDPT[128])

Per-process CR3 (`proc_create_address_space`): own PML4 + own PDPT (copies kernel PDPT[1..511] from `0x2000`) + own 0–1 GB PD. So each proc can hold **private** high-PDPT entries.

| PDPT range | VA | Use |
|---|---|---|
| [0..3] | 0–4 GB | kernel identity + 0–1 GB PD (low arena, code, stack) + device BARs + FB (all ≤4 GB) |
| [8..71] | 8–72 GB | **direct-map** (`DIRECTMAP_BASE=8 GB + phys`; bitmap caps RAM at 64 GB → tops at PDPT[71]) |
| **[128..511]** | **128–512 GB** | **high user arena** (free; above the max direct-map; kernel leaves these 0) |

PDPT[128..511] being kernel-zero is load-bearing: a *present* entry there is unambiguously a per-process arena PD, so teardown can free it without risk of touching a shared kernel PD. (PDPT[4..7] = 4–8 GB is also free but only 4 GB before the direct-map; the 128 GB base gives 384 GB of arena and a clean teardown boundary.)

`USER_HIMMAP_BASE = 0x2000000000` (128 GB). High arena = `[128 GB, 512 GB)`, 2 MB pages.

## Why the direct-map matters

User pages are reached by ring 3 through the high VA → per-proc PD → phys (anywhere in RAM) — no direct-map needed for the *user* access. The direct-map is only for the **kernel's** zero-fill: `sys_mmap` zeroes a freshly-allocated >256 MB region via `pmm_kva_for_access(phys)` (= `DIRECTMAP_BASE + phys`) under the caller's per-proc CR3, which inherits PDPT[8..] from the kernel. (Same handle the 1.49.12 fix already uses for the low arena.)

## Bites

- **1a — `proc_map_page_hi` (DONE, 1.50.2).** On-demand per-proc PDPT-entry + PD allocation for VA ≥ 128 GB; sibling maps reuse the PD. Dormant (not wired into `sys_mmap`). Verified hermetically by `MMAP_HIMEM_SELFTEST` (`mmap-himem: chain PASS`). Production byte-unaffected; `check.sh` 11/11.
- **1b — wire + teardown + end-to-end (DONE, 1.50.2, QEMU-validated).**
  1. ✅ `sys_mmap`: dropped the `length > 1 GB` reject; small allocs use the low arena, big/overflow spill to the high arena via `himmap_next_vaddr` + `proc_map_page_hi` (zero-filled through the direct-map handle). Single sanity cap `length ≤ 64 GB`.
  2. ✅ `proc_free_address_space`: sweeps per-proc **PDPT[128..511]**, freeing each present+user arena PD's 2 MB pages + the PD page. (Safe because kernel PDPT[128..511] are 0 / supervisor.)
  3. ⏳ `sys_munmap` high range — **DEFERRED** (a high `addr ≥ 128 GB` falls through the existing `> 0x40000000` guard → returns -1; no leak, the teardown above reclaims at exit). Follow-on.
  4. ✅ `MMAP_HIMEM_E2E_SELFTEST`: 1.026 GB contiguous (513 × 2 MB) spanning PDPT[128]+[129], free-count drops by 513, teardown restores it fully — `mmap-himem-e2e: >1GB map+free PASS` at `-m 4G`. No regression: `check.sh` 11/11, `agnsh-smoke` + 8G boot-to-prompt. (A *ring-3* >1 GB read/write test is bite 1c / a userland program — the selftest drives `proc_map_page_hi` + teardown directly.)
- **1c — iron burn (NEXT).** Per-proc-CR3 page-table change → iron-gated. Build a burn with `MMAP_HIMEM_E2E_SELFTEST=1` to run the >1 GB map+free on real silicon, and/or a userland program that `mmap`s >1 GB + touches it.
- **Follow-ons (1.50.x patches):**
  - ✅ **1.50.3 — high-range `sys_munmap`** (`proc_unmap_2mb_hi`; per-page PDPT walk, free + clear PDE, idempotent; LIFO cursor rewind). `mmap-himunmap: PASS`.
  - ✅ **1.50.4 — per-process cursor** (`proc_himmap_next[16]` + `himmap_reserve(pid,len)` replaces the global `himmap_next_vaddr`; each proc gets its own `[128 GB,512 GB)`). `mmap-himem-perproc: PASS`.
  - ✅ **1.50.5 — NX on anonymous arena pages (W^X)** — new `proc_map_page_nx` backs the low arena, `proc_map_page_hi` NX's the high arena; ELF code stays executable on `proc_map_page`. Every arena-PDE phys extraction switched to the bit-63-safe mask `0x000FFFFFFFE00000`. `mmap-himem: chain PASS` asserts NX; `exec-smoke` 15/15.
  - ✅ **1.50.6 — PF_X-aware ELF mapping + NX user stack (W^X)** — both loaders read `p_flags` and map `PF_X` segments executable / non-`PF_X` NX, and NX the user stack (`0x3FC00000`). `exec-smoke` + `ring3-smoke` PASS. **Finding: cyrius/cyrld emits one RWE PT_LOAD per binary** (code+data packed), so segment-level W^X is moot until cyrius emits separate RX/RW segments — the PF_X mechanism is future-proof, the stack NX is the live win. **Remaining W^X surface = the cyrius single-RWE code+data segment** (a cyrius-side change, out of agnos scope).
  - ⏸ **ring-3 userland >1 GB program — DEFERRED** (user 2026-06-29: nothing in the cyrius ecosystem demands >1 GB RAM yet; desktop is the natural trigger). The kernel mechanism is iron-proven via `MMAP_HIMEM_E2E_SELFTEST`; revisit when a desktop workload needs it.

## Risks / notes

- **Teardown is mandatory before wiring ships** — without bite 1b.2 every proc that touches the high arena leaks its PDs + pages on exit. So 1b lands wire + teardown together.
- 4 KB `pmm_alloc` for the on-demand PD stays ≤256 MB (identity) — unchanged. Only the 2 MB user data pages go high (zeroed via the direct-map handle).
- The high PDEs are `0x87` (user, executable — matches `proc_map_page`; no NX). A later hardening pass could set NX on anonymous arena pages (W^X), but that mirrors the existing low-arena behavior, not a regression.
- Global vs per-proc cursor: 1b uses a **global** `himmap_next_vaddr` (matches the low arena; 384 GB of VA + LIFO munmap makes exhaustion remote). A per-proc cursor is a later refinement if long-running multi-proc workloads exhaust the global bump.
