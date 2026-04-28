# Proposal: Extend kernel identity map to cover QEMU's ACPI table region

**Status**: **resolved** — Path A landed in agnos v1.25.0; see [Resolution](#resolution-2026-04-27)
**Date**: 2026-04-27
**Target**: agnos 1.25.0 (shipped 2026-04-27)
**Affects**: `kernel/arch/x86_64/boot_shim.cyr` (PD entries) and/or
            `kernel/arch/x86_64/paging.cyr` (`paging_init` extension),
            `kernel/core/acpi.cyr` (defensive bounds).
**Author**: Robert MacCracken

## Resolution (2026-04-27)

**Path A landed in agnos v1.25.0** — the simpler PD-only variant
(no PDs allocated for >1 GB; PDPT[1..3] hold 1 GB huge pages
instead). Single-file change in `kernel/arch/x86_64/paging.cyr`
`pt_init`:

```cyrius
# Was: for (var i = 0; i < 8; i = i + 1) {  // 16 MB
for (var i = 0; i < 512; i = i + 1) {       // 1 GB via PD
    pt_map_2mb(0x3000, i, i * 0x200000);
}
# PDPT[1..3] = 1 GB huge pages (PDPE1GB) for 1–4 GB
store64(0x2000 + 1 * 8, 0x40000000 | 0x83);
store64(0x2000 + 2 * 8, 0x80000000 | 0x83);
store64(0x2000 + 3 * 8, 0xC0000000 | 0x83);
```

Net: ~10 lines changed, ~14 lines of comments. Binary size delta
+128 B (248,720 → 248,848).

**Boot output post-fix** (under `qemu-system-x86_64 -kernel
build/agnos -cpu max`):

```
AGNOS kernel v1.25.0
…
Page tables: 1024MB mapped         ← was: 16MB
…
Devices registered
ACPI: RSDP at 1008880              ← previously: triple fault here
PCI: 4 devices
VFS initialized
…
Scheduler test done. Timer ticks: 154
VFS write: OK
Initrd: 2 files
initrd hello.txt: Hello, AGNOS!
initrd test: PASS
VFS memfile read: HELLO
Memory isolation test..            ← new failure surface (separate bug)
```

CI gate moved from `grep -q "AGNOS"` (matches line 1, useless after
the kmode fix) to `grep -q "Scheduler test done"` — a checkpoint
that requires ACPI + PCI + IOMMU + syscall + scheduler all to work.
Future ACPI-class regressions cannot pass CI green now.

**Memory isolation test surfaces a separate bug** (filed as Active
item #5 in the roadmap) — the test does cr3-switches to per-process
address spaces while interrupts are enabled, and the timer ISR
faults trying to touch kernel data not mapped in the user CR3.
That's pre-existing — it was just hidden behind the ACPI fault.
Out of scope for this proposal.

## Summary

Boot reaches "Devices registered" (the last `serial_println` from
`kernel/core/main.cyr` before `acpi_init()`) and then triple-faults.
Symptom: 19,485 interrupts → reset, no further serial output.

QEMU `-d cpu_reset,int` shows the canonical fault chain:
`#PF (0x0e) → #GP (0x0d) → #DF (0x08) → triple fault`. The faulting
address (`CR2`) is `0x07FE232C`. That address is in QEMU's ACPI table
region — SeaBIOS places RSDT / MADT / DMAR / etc. just below 2 GB.

The agnos kernel only identity-maps 0–16 MB:
- Boot shim seeds PD[0]+PD[1] for 0–4 MB before long mode
  (`kernel/arch/x86_64/boot_shim.cyr`).
- `paging_init()` extends to 16 MB after long mode entry
  (`kernel/arch/x86_64/paging.cyr`).

ACPI tables at ~134 MB are unmapped. `acpi_init()` finds RSDP in
the low BIOS-ROM scan (mapped), reads its `RsdtAddress` field
(`= 0x7FE2328`), tries to walk the RSDT at that VA, and faults.
The IDT is set up but the page-fault handler then trips on
something it dereferences (likely the same unmapped region) →
escalates to `#GP` → `#DF` → triple fault.

This is an **agnos kernel bug**, not a cc5 codegen issue. ACPI
parsing was added in v1.22.0 (per `CHANGELOG.md` "ACPI table
parsing (kernel/core/acpi.cyr): RSDP scan, RSDT/XSDT walk, DMAR
table parsing"), but the kernel's 16 MB identity-map ceiling was
never extended to cover where QEMU actually places ACPI tables.
The bug shipped silently in v1.22.0, v1.23.0, v1.24.0, and v1.24.1
— never noticed because every prior CI assertion (`grep -q "AGNOS"`)
matches the v1.24.x boot banner from line 1 of serial output, and
dev practice didn't read past `"Devices registered"`. v1.24.2 was
abandoned mid-flight (its doc-only edits fold into v1.25.0
alongside this fix) so it never tagged.

## Background

### QEMU ACPI memory layout

QEMU x86_64 with default RAM (128 MB) places ACPI tables in a
contiguous region just below the top of low memory. With 128 MB
RAM the layout is approximately:

| Region | Address | Notes |
|---|---|---|
| Low RAM | 0x00000000 – 0x00080000 | First 512 KB |
| EBDA (RSDP scan) | 0x0009FC00 – 0x000A0000 | RSDP usually here on real HW |
| BIOS ROM (RSDP scan) | 0x000E0000 – 0x000FFFFF | RSDP here on QEMU/SeaBIOS |
| Free RAM | 0x00100000 – 0x07FE0000 | Kernel + heap + everything |
| **ACPI tables** | **0x07FE0000 – 0x07FF0000** | RSDT/XSDT/FACP/MADT/DMAR/HPET |
| ACPI NVS | 0x07FF0000 – 0x08000000 | Reserved |
| Top of low RAM | 0x08000000 | 128 MB |

So `RsdtAddress = 0x07FE2328` (offset 0x2328 into the ACPI region).
agnos identity-maps 0x00000000 – 0x01000000 (16 MB), so RSDT is
~118 MB beyond the mapped range.

### Why "Devices registered" is the last working line

Looking at `kernel/core/main.cyr` boot sequence:

```
…
heap_init();                          # 16 MB heap, all in mapped range
serial_println("Heap initialized", 16);
dev_init();                           # registers serial, no MMIO touch
serial_println("Devices registered", 18);
acpi_init();                          # ← faults here
```

`acpi_init()` (`kernel/core/acpi.cyr`) does:
1. RSDP signature scan in 0x000E0000–0x000FFFFF (mapped, OK).
2. Read `RsdtAddress` (or `XsdtAddress`) from RSDP (read happens
   from low RAM, OK).
3. **Dereference that pointer to walk the RSDT entries** — first
   access to the unmapped 0x07FExxxx region.

Step 3 is the immediate fault site. RIP = 0x123ab3 (kernel `.text`
region) is somewhere inside `acpi_init` or one of its helpers
(`acpi_walk_rsdt` or similar — exact symbol unknown without the
`CYRIUS_SYMS=` mapping that agnos doesn't currently emit).

### Why the page-fault handler also faults

`#PF` handler installed by `idt_init` (default IDT default-handler
or one of the named handlers) lives in kernel `.text`, which IS
mapped (kernel is at 0x100000–0x13D000). But the handler reads
from `CR2` and probably tries to print/format the address — if any
intermediate buffer or table it touches lives outside the 16 MB
identity range (e.g. a kernel data variable that happened to land
there, or a stack frame near the top of allocated kernel memory),
it faults again.

More likely: the IDT's #PF gate uses an IST or stack pointer that
ends up in unmapped memory after handling chains, OR the kernel
GDT/TSS/RSP0 setup is fine but `kprint_num` walks the page tables
themselves to resolve the format buffer and tripps on a higher
PD/PT level mapping issue.

The exact `#GP` cause is secondary — the primary fix is to never
take the first `#PF` in the first place.

## Decision

Three viable paths.

### Path A — **Extend identity map to cover RAM (recommended)**

Identity-map the full lower 4 GB region in 2 MB huge pages during
`paging_init()`. PD has 512 entries × 2 MB = 1 GB per PD; need 4
PDs for 4 GB. Or, since PDPT entries can also use 1 GB pages
(`PS=1` at PDPT level), use 4 × 1 GB PDPT entries — no PD
allocation at all for the upper 3.5 GB.

**Pro:** Solves the ACPI fault, also future-proofs for any other
MMIO / ACPI / framebuffer / VirtIO BAR mapping that lands in low
RAM. Matches what xv6, Linux's early boot, and most teaching
kernels do.

**Con:** Wastes some kernel memory on PT entries (4 KB per 1 GB
PD = 16 KB total for 4 GB; negligible). Identity-maps physical
addresses the kernel "shouldn't" trust, but agnos already trusts
the multiboot loader to give correct memory info — this isn't a
new trust boundary.

**Acceptance gate:** Boot reaches the test-process scheduler
spawn and serial banner reads "Memory isolation: PASS" through
"Userland exec complete" without faulting.

### Path B — Targeted ACPI region map

Read RSDP, extract `RsdtAddress`, map exactly the 2 MB containing
that address before walking RSDT. Repeat for each table the RSDT
points to (FACP, MADT, DMAR, HPET, …).

**Pro:** Minimal mapped footprint, keeps the "kernel knows what
it can touch" model.

**Con:** Surgical and brittle. Every new ACPI table walked needs
its own map call. acpi_init can't run linearly anymore — it has
to thread VMM mapping into its scan loop. Higher complexity for
no real benefit over Path A.

### Path C — Defer ACPI parsing until VMM is up

Move `acpi_init()` after a `vmm_init()` that maps 0–4 GB on
demand via 4 KB pages. Conceptually clean (ACPI is "I/O", VMM
is the I/O manager), but agnos's `vmm_init()` currently maps
2 MB huge pages and doesn't handle on-demand. Bigger refactor.

## Recommendation

**Path A.** Smallest diff, no new abstractions, matches the
established agnos pattern of "kernel maps everything it could
need at boot." Implementation:

```cyrius
# kernel/arch/x86_64/paging.cyr — extend paging_init
fn paging_init() {
    # PML4[0] -> PDPT@0x2000 (already set by boot shim)
    # PDPT entries 0..3: 1 GB pages identity-mapping 0..4 GB.
    # Boot shim seeded PDPT[0] -> PD@0x3000. Promote to 1 GB
    # huge pages for clarity, OR leave PDPT[0] as-is (PD@0x3000)
    # and add PDPT[1..3] = 1 GB pages directly.
    var pdpt = 0x2000;
    # PDPT[1] = 1 GB at 0x40000000  (1-2 GB)
    store64(pdpt + 8,  0x40000000 | 0x83);   # P|RW|PS
    # PDPT[2] = 1 GB at 0x80000000  (2-3 GB)
    store64(pdpt + 16, 0x80000000 | 0x83);
    # PDPT[3] = 1 GB at 0xC0000000  (3-4 GB)
    store64(pdpt + 24, 0xC0000000 | 0x83);
    # Existing PD[0..7] for 0-16 MB inside PDPT[0] stays untouched.
    # Flush TLB.
    asm { mov rax, cr3; mov cr3, rax; }
}
```

3 added entries, ~8 lines of Cyrius. ACPI tables at 0x07FExxxx
fall inside PDPT[0]'s 1 GB range (the existing PD), so technically
even just *replacing* the boot-shim 4 MB seed with an 8-entry PD
covering 0–16 MB at `paging_init` time would be enough — but the
1 GB pages above are cheap insurance for the next time something
lands at 0x40000000+.

### Acceptance gate

The CI QEMU Boot Test should be tightened from
`grep -q "AGNOS"` (matches line 1) to
`grep -q "Memory isolation: PASS"` or
`grep -q "Userland exec complete"` — both come AFTER ACPI parsing,
PCI scan, IOMMU init, and would have caught this regression
before any of v1.22.0–v1.24.1 shipped.

## Out of scope (filed separately)

1. **CYRIUS_SYMS map emission** — agnos doesn't pass `CYRIUS_SYMS=`
   at build time, so RIP-to-function mapping has to be done by hand
   from the binary. cyrius supports this since v5.4.x. A one-line
   addition to `scripts/build.sh` (`CYRIUS_SYMS="$ROOT/build/agnos.syms"`)
   would have shaved hours off this diagnosis. Pin for 1.25.0+.
2. **CI boot assertion strengthened** — the existing
   `grep -q "AGNOS"` matches the boot banner from line 1 of serial
   output, so any kernel that prints its banner and then triple-faults
   passes the CI gate. After Path A lands, change the assertion to
   match a much later checkpoint (e.g. "Userland exec complete" or
   the `kybernet:` PID-1 banner).
3. **CI QEMU CPU model documented in the workflow comment** —
   already done in v1.24.0, but should be cross-referenced from
   this proposal in case Path A or any future change interacts
   with `-cpu max`'s exposed feature set.

## References

- `kernel/arch/x86_64/boot_shim.cyr` — PD[0]+PD[1] seeded for 0–4 MB
- `kernel/arch/x86_64/paging.cyr` — `paging_init()`, current 16 MB ceiling
- `kernel/core/acpi.cyr` — RSDP scan + RSDT walk (fault site)
- `kernel/core/main.cyr:79` — "Devices registered" line, last working serial output
- QEMU x86 ACPI table layout — `hw/i386/acpi-build.c` in QEMU source,
  `acpi_align_size` + `bios_linker_loader_alloc` place tables in the
  contiguous high-low-RAM region
- Multiboot1 §3.3 — `mmap_*` fields tell the kernel what RAM is
  available; agnos doesn't currently parse them but should once
  the identity map needs to be bounded by real RAM size
