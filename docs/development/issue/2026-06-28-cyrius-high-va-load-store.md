# cyrius: `load64`/`store64` don't reach a ≥4 GB virtual address

**Filed:** 2026-06-28 (agnos 1.49.9, RAM-arc bite 3b)
**Severity:** blocks the agnos >256 MB RAM extension (kernel can't use RAM above the 256 MB identity ceiling)
**Component:** cyrius codegen — `load64`/`store64` (likely all `loadN`/`storeN`) address handling
**Toolchain seen:** cycc 6.3.0 (kernel pin 6.2.44)

## Symptom

A `store64`/`load64` to a **virtual address ≥ 4 GB** does not reach the physical page the
MMU maps that VA to. The write appears to be dropped (or applied to a different/low address);
the subsequent read returns `0`, **with no page fault**.

The page tables are correct — this is not an MMU/mapping bug. It is the emitted memory
access not using the full 64-bit address.

## Repro (in-kernel, agnos)

agnos builds a kernel direct-map: physical RAM mapped at `DIRECTMAP_BASE + phys`, with
`DIRECTMAP_BASE = 0x200000000` (8 GB), as 2 MB pages in the kernel PDPT @ `0x2000` (entry 8).
At boot, with `-m 1024M` (so phys 320 MB is real RAM):

```
# read the live page-table chain for VA 0x214000000 (= DIRECTMAP_BASE + 320 MB):
PDPT[8] = 0xffff003                      # -> PD page, present
PD[160] = 0x14000083                     # -> phys 0x14000000 (320 MB), present + writable + 2 MB
# the mapping is exactly right. now access it:
store64(0x214000000, 0xA5A5A5A5);
load64(0x214000000)  ==> 0               # WRONG: expected 0xA5A5A5A5, got 0, no fault
```

By contrast a VA whose **low 32 bits alias a live low mapping** "works" — `0x206400000`
(8 GB + 100 MB) reads the same bytes as identity `0x6400000` (100 MB), because the low bits
coincide with the identity map. That is exactly why agnos's original ≤100 MB direct-map probe
passed falsely: it never exercised a high VA whose low bits *don't* already resolve.

## Inference

`load64`/`store64` appear to compute or use only the **low bits** of the address (a 32-bit
displacement / truncated pointer), so any VA ≥ 4 GB is silently mis-addressed. The address
*value* is fine in cyrius arithmetic — `kprint_hex` shows the full `0x214000000` — so it's the
emitted load/store instruction's effective address, not the value computation.

## Impact on agnos

- The kernel reaches PMM pages either via the **identity map** (0–256 MB, the per-proc CR3's
  reliable window) or, for anything above that, via the **direct-map at 8 GB**. The latter is
  unusable from cyrius, so kernel-reachable RAM is capped at the 256 MB identity ceiling.
- agnos 1.49.7's direct-map was therefore **never truly access-validated** (the probe aliased
  the identity). 1.49.9 holds `pmm_alloc_2mb` at 256 MB and keeps the rest of the >256 MB
  machinery (4 GB bitmap, `pmm_kva_for_access`, the elf.cyr access-handle split) dormant.

## What's needed

`loadN`/`storeN` should use the **full 64-bit effective address**. Once a ≥4 GB VA round-trips
(`store64(va, x); load64(va) == x` for a correctly-mapped `va ≥ 4 GB`), agnos lifts the
`pmm_2mb_top_region` cap + re-grows the bitmap and >256 MB RAM comes online with no new VM work.

A minimal standalone repro (no agnos): map any phys page at a ≥4 GB VA in a fresh PML4/PDPT/PD,
reload CR3, then `store64`/`load64` the high VA and compare — it should round-trip and currently
will not.

**Also filed upstream in cyrius:** `cyrius/docs/development/issues/2026-06-28-agnos-high-va-load-store.md`.
