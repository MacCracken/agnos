# cyrius: `load64`/`store64` don't reach a ≥4 GB virtual address

**Filed:** 2026-06-28 (agnos 1.49.9, RAM-arc bite 3b)
**Severity:** blocks the agnos >256 MB RAM extension (kernel can't use RAM above the 256 MB identity ceiling)
**Component:** cyrius codegen — `load64`/`store64` (likely all `loadN`/`storeN`) address handling
**Toolchain seen:** cycc 6.3.0 (kernel pin 6.2.44)
**Status:** ✅ **ROOT-CAUSED + RESOLVED (2026-06-28)** — NOT a cyrius bug AND not a direct-map
construction bug. The direct-map is built correctly and works; it was being *tested* under the wrong
page tables. The boot-time probe ran under **gnoboot's transient boot CR3** (`0x3fc01000`), whose
`PDPT[8]` is a **1 GB identity huge page to phys 8 GB** (usually unbacked → reads 0, no fault) — NOT
the kernel's direct-map, which lives in the kernel PML4 at `0x1000`. Under the kernel CR3 (`0x1000`,
where kernel threads and every per-proc CR3 run) the identical `store64`/`load64` to a >256 MB
direct-map VA round-trips perfectly. See "Root cause" below. cyrius exoneration stands ("Resolution").

---

## Root cause — boot ran on gnoboot's CR3, not the kernel's (2026-06-28)

**The active CR3 at the boot probe is `0x3fc01000` (gnoboot/UEFI's PML4), not `0x1000` (the kernel's).**
The kernel installs the direct-map into the PML4 at phys `0x1000` (`PDPT[8] @ 0x2000` → `dm_pd`), but
the CPU at boot is still walking gnoboot's tables, which the kernel never edits. The whole confusion
chain unwinds from there:

- **Why C (the >256 MB access) read 0 with no fault:** gnoboot's `PDPT[8] = 0x2000000e3` — a 1 GB
  **identity** huge page (PS=1) mapping VA 8–9 GB → phys 8–9 GB. With <8 GB RAM that phys is unbacked,
  so QEMU/hardware returns 0 on read and silently drops the write — a *present* mapping, hence no #PF.
- **Why the OLD always-on probe falsely passed** (`load64(DIRECTMAP_BASE+100MB) == load64(100MB)`):
  both ran under gnoboot's CR3, both read 0 (the directmap side hit the unbacked 8 GB identity page;
  the identity side read a still-zero phys 100 MB), `0 == 0` → "directmap: low+hi OK". A two-zero
  match, never a real translation. This false pass is exactly what masked the bug and got it
  mis-blamed on a cyrius load/store truncation.
- **The empirical walk that nailed it** (boot CR3, `-m 1024M`, all values confirmed via `kprint_hex`):
  | probe | result | meaning |
  | --- | --- | --- |
  | `CR3` | `0x3fc01000` | **active table is gnoboot's, not 0x1000** |
  | kernel `PML4[0]/PDPT[8]/dm_pd/PD[160]` | `2007 / ffff003 / ffff000 / 14000083` | kernel direct-map built **correctly** (PD[160] → phys 320 MB, present+RW+2 MB) |
  | A: identity-write 100 MB, directmap-read | `0` (≠ `0x11111111`) | directmap VA and identity VA resolve to **different** phys pages |
  | B: directmap-write 100 MB, identity-read | `0x11111111` (the A value, ≠ `0x22222222`) | the directmap write went to a phantom page; identity still holds A |
  | C: store/load `0x214000000` (320 MB) | `0` | the unbacked-8 GB identity page absorbing the round-trip |
  | gnoboot `PDPT[8]` | `0x2000000e3` | **1 GB identity huge page → phys 8 GB** (the phantom) |
  | E: same round-trip under **CR3 0x1000** | `0xcafebabe` ✅ | **direct-map works** — pure page-table-tree difference, cyrius identical |

**Why the direct-map is nonetheless fully usable at runtime.** gnoboot's CR3 is purely transient —
active only from kernel entry until the first context switch, and **never captured or reloaded**
anywhere (every `cr3_load` targets `0x1000`, a per-proc CR3, or a KPTI pair derived from those). The
kernel's canonical "kernel CR3" is `0x1000`, which holds the direct-map directly; every per-proc CR3
copies `PDPT[1..511]` from `0x2000` (`proc.cyr` ~line 487), so it inherits `PDPT[8]` too. So *every*
context the direct-map's real consumers run in — `sys_mmap` page-zeroing under the caller's per-proc
CR3, exec segment copy, kernel threads at `0x1000` — already reaches >256 MB phys correctly. The only
context that can't is gnoboot's boot CR3, which touches no >256 MB page.

### Fix applied (agnos 1.49.10)

- **Replaced the false-positive boot probe** (`main.cyr`) with one that round-trips a true >256 MB VA
  (phys 320 MB, low bits non-aliasing) **under the kernel CR3 0x1000** — the context consumers use —
  then restores the live CR3. Gated on `RAM > 320 MB && RSP < 256 MB` so the brief CR3 switch is
  always stack-safe (boot stack is identity-mapped <256 MB under `0x1000`); else a structural
  "is `PDPT[8]` installed" check. New boot lines: `directmap: >256MB OK (kernel CR3)` (verified in
  QEMU `-m 1024M`) / `directmap: installed` (≤320 MB).
- Helpers added in `vmm.cyr`: `dm_read_cr3`, `dm_read_rsp`, `dm_roundtrip_kernel_cr3`.

### What's left for the >256 MB RAM feature (separate, mechanical — no VM redesign)

The direct-map blocker is **gone**. Bringing >256 MB RAM online now needs only:
1. Lift `pmm_alloc_2mb`'s 128-entry (256 MB) cap to the real RAM ceiling. User 2 MB allocs zero under
   the caller's per-proc CR3 → direct-map reachable → safe.
2. Re-grow the 4 KB PMM bitmap past 256 MB. The earlier 4 GB bitmap was a **static** array that blew
   the ~1.4 MB kernel-size cap — this needs a storage decision (BSS-backed bitmap, on-demand/2-level,
   or 2 MB-granularity-only tracking above the identity ceiling), not new paging work.
3. Keep kernel 4 KB allocations that are touched **under the boot CR3** (early-boot only) ≤256 MB;
   everything allocated/touched post-first-context-switch is unrestricted.

(Optional, larger, not required for the above: have the kernel switch to its own complete PML4 early
so the boot CR3 also carries the full kernel map — closes the "boot CR3 can't see kernel VM edits"
latent gap. Needs `0x1000`'s PDPT completed for the framebuffer/device BARs first.)

---

## Resolution — cyrius codegen exonerated (2026-06-28)

The cyrius x86_64 backend was root-caused by compiling the **exact repros below** with the pinned
compiler and disassembling the emitted bytes — in **agnos's real production kernel mode**
(`kernel;` + `#define ELF64_KERNEL` + `CYRIUS_ELF64_KERNEL=1`, exactly as `scripts/build.sh`
builds the kernel) and in the KASLR PIE variant (`+CYRIUS_PIE=1`). Every ≥4 GB load/store emits
the **full 64-bit effective address**:

| path | emitted bytes | width |
| --- | --- | --- |
| address literal | `48 b8 00 00 00 14 02 00 00 00` = `movabs rax,0x214000000` | full imm64 |
| `load64` | `48 8b 00` = `mov rax,[rax]` | full 64-bit base |
| `store64` | `48 89 01` = `mov [rcx],rax` | full 64-bit base |
| computed base+off | `48 01 c8` = `add rax,rcx` | full 64-bit |
| global slot | statically initialized `00 00 00 14 02 00 00 00` | full-width |

**Decisive:** on x86-64, an effective address can only be truncated to 32 bits by a `0x67`
address-size prefix or a 32-bit base register (`eax`/`ecx`). **Neither is emitted anywhere in the
binary.** A value round-trip confirmed it functionally: store `0x214000000`, load it back,
`>>32` → `2` (high bits survive); truncation would have yielded `0`. `src/backend/x86/emit.cyr`
(`EMOVI`, `ELOAD64`, `ESTORE64`) is also **git-byte-identical between the 6.2.44 kernel pin and
6.3.0**, so the exact bytes the kernel's compiler emits are the ones tested — exonerated at both
versions.

The two plausible disp32-narrowing paths were checked and ruled out: `EADDRA_IMM` (`48 05 imm32`)
is reachable only from a *compile-time* byte-array-literal index, never a runtime address; and the
PIE/object RIP-relative `lea [rip+disp32]` path rewrites only fixup-recorded symbol addresses,
never an `EMOVI` literal or the load/store base register (confirmed under `CYRIUS_PIE=1`).

### Therefore the bug is agnos-side (still open)

The full 64-bit VA reaches the CPU, so the low-32 alias agnos observes means the **active page
tables don't translate the high VA**. The "Inference" section below (32-bit truncation *in
cyrius*) is **disproven** — the low-32 aliasing is the agnos identity-map geometry showing through
an MMU miss, not an instruction-encoding artifact. This is consistent with §"Impact on agnos"'s
own note that the 1.49.7 direct-map "was never truly access-validated."

**Diagnostic recipe** (in the failing in-kernel repro, immediately before the store):

1. Read `CR3`; confirm it equals the physical address of the PML4 that actually contains the
   direct-map `PDPT[8]` entry walked below. **Active table ≠ separately-built table is the prime
   suspect** — the static walk may be reading a PML4 that isn't the one loaded in CR3 at access
   time.
2. Walk `PML4[idx(0x214000000)] → PDPT[8] → PD[160]` **from the live CR3**, not a precomputed
   pointer; verify the present bit + leaf phys `0x14000000` at every level.
3. `invlpg [va]` (or reload CR3) after any not-present → present transition — a missing flush
   yields a phantom read that looks exactly like this symptom.
4. Confirm the PD entry is a 2 MB page (PS bit set) and that `0x14000000` phys is RAM-backed.

If a *verified-active* mapping still mis-addresses, look next at agnos's own boot/asm trampolines —
not cyrius. The disassembly proves the instruction already carries the full VA in the base
register.

> Do **not** ask cyrius to "widen" any load/store emitter or `EADDRA_IMM` — the bytes are already
> correct, and changing them would break cycc self-host byte-identity and the seed-derive gate.

---

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

**Cyrius-side mirror:** removed 2026-06-28 after the codegen was exonerated (see "Resolution"
above). This agnos-side copy is now the canonical record; the bug is agnos paging, not cyrius.
