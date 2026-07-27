# Issue: memory-isolation test page-faults on `store64(0xC00000, ...)` even after cr3_load + PD[6] verified correct

**Status**: **CLOSED** at v1.27.1. Root cause was SMAP, not page-table corruption. Test now runs in default builds and asserts `Memory isolation: PASS`.
**Date**: 2026-04-27 → 2026-05-11 (resolved)
**Affects**: `kernel/core/main.cyr` memory-isolation test (was gated behind
            `-D MEMORY_ISOLATION_TEST` v1.25.1–v1.27.0; gate dropped v1.27.1).
**Related**: closes the cr3-load-helper part of the puzzle
            ([../2026-04-27-cr3-load-helper.md](../2026-04-27-cr3-load-helper.md));
            this doc was about the *deeper* fault after the cr3_load fix.

## Resolution (v1.27.1)

**Root cause: SMAP (Supervisor Mode Access Prevention).** The boot
shim's CR4 OR-mask `0x300020` (boot_shim.cyr line 52) sets SMEP+SMAP.
`proc_map_page` writes per-process PD entries with `0x87` (P | RW | US
| PS) because the per-process address space pages must be reachable
from CPL=3. SMAP traps CPL=0 access to US=1 pages unless `RFLAGS.AC=1`.
The test runs in CPL=0 (kernel main) but writes to `0xC00000` which
under AS1 is a US=1 page → SMAP `#PF` → cascade to `#GP` → `#DF` →
triple fault.

Every observed forensic detail re-reads cleanly under SMAP:

| Observation | SMAP explanation |
|---|---|
| Pre-switch PD[6] read works | kernel page tables are US=0 (kernel's own identity map uses `0x83`) |
| Post-switch `serial_println` works | reads from kernel `.rodata` mapped US=0 via the per-process PD copy of the kernel PD entries (v1.25.1) |
| `store64(0xC00000, …)` faults | exactly the US=1 access SMAP is supposed to trap |
| `CR2=0xC00000` matches the literal | SMAP `#PF` reports the faulting linear address per SDM Vol 3 §4.7 |
| Same fault under cyrius 5.7.22 and 5.10.44 | SMAP is hardware behavior — toolchain-independent |

### Fix

`stac` (`0F 01 CB`) / `clac` (`0F 01 CA`) brackets around each
access block in the test:

```cyrius
cr3_load(as1);
asm { 0x0F; 0x01; 0xCB; }   # stac
store64(0xC00000, 0xAAAA);
var val_as1 = load64(0xC00000);
asm { 0x0F; 0x01; 0xCA; }   # clac
```

Per Intel SDM Vol 3 §6.12.1.4, interrupt entry clears RFLAGS.AC
implicitly, so the bracket discipline survives a preempting interrupt.

### Hypotheses that turned out wrong

The 2026-04-27 hypotheses (PML4/PDPT clobber between proc_map_page
and cr3_load; stack-canary dangling pointer; cc5 codegen mis-emitting
the store; IDT mapping under AS1) were all reasonable given the
evidence shape, but every one of them assumed the fault was about
*page-table state* rather than *access-control hardware bits*. The
SMAP bit in CR4 was visible in the original fault dump (CR4=`0x300020`)
but went unread for ~14 days. Calling that out as a process note —
*read every bit of CR0/CR3/CR4 the next time a page-walk faults
inexplicably*.

### Diagnostic that solved it

Pattern-matching `proc_map_page`'s `0x87` flag (US=1) against the
0x300020 CR4 dump (SMAP=1) during the 1.27.1 scoping session. No new
instrumentation required — the data was already in the original
forensic capture.

---

# Original (2026-04-27) writeup follows


## Summary

After v1.26.0 added the `cr3_load()` helper and replaced the
`var x = expr; asm { mov cr3, rax }` pattern, the test still
page-faults on the very first `store64(0xC00000, 0xAAAA)` after
`cr3_load(as1)`. The fault chain is identical to v1.25.1:
`#PF (CR2=0xC00000) → #GP → #DF → triple fault`.

Yet:
- `cr3_load(as1)` returns successfully (proven by serial-print
  diagnostic: `"post cr3_load(as1)"` is emitted, which means a
  serial-port `out` instruction ran AFTER the cr3 switch — i.e.
  kernel code & static-string data are reachable under AS1's CR3).
- AS1's PD[6] = `0xE00087` (`phys1 | 0x87`), verified by walking
  `as1 → PML4[0] → PDPT[0] → PD[6]` from kernel CR3 *before* the
  cr3 switch. Exactly what `proc_map_page` is supposed to write.
- AS1's CR3 = `0x204000` shows up correctly in the fault dump.

So every visible part of the page-table machinery looks right, but
the access still faults. Diagnosis incomplete — see hypotheses below.

## Forensic data

Collected via:
```sh
qemu-system-x86_64 -kernel build/agnos -cpu max -display none \
  -serial stdio -d cpu_reset,int -D /tmp/inv.log -no-reboot
```

(plus a small in-kernel diagnostic block printing AS1 PD[6] before
the cr3 switch, and serial markers around each statement).

```
Memory isolation test...
AS1 PD[6] = 14680199 (expected 14680199)        ← 0xE00087, correct
about to cr3_load(as1)                          ← printed
post cr3_load(as1)                              ← printed (=> CR3 is AS1, code+strings reachable)
[boot stops — no "post store" line, fault triggers]
```

Fault dump:

```
v=08 (#DF) e=0000 i=0 cpl=0
IP=0008:0x123BD7  SP=0010:0x11BBB0
RAX=0xaaaa  RBX=0x219c43a9  RCX=0xc00000  RDX=0x1000000
RSI=0xc00000  RDI=0x204000  RBP=0x200000  RSP=0x11bbb0
CR0=80000011  CR2=0xc00000  CR3=0x204000  CR4=0x300020
EFER=0xd01
check_exception old: 0x8 new 0xd → Triple fault
```

`RIP=0x123BD7` lands in the gvar zero block (kernel `.bss` /
zero-init region from ~0x11B530 to ~0x13C030). That means
execution ran past valid kernel `.text` into zeros, where each
`00 00` decodes as `add [rax], al`. With `RAX=0xaaaa`, those
adds incrementally touch addresses near 0xaaaa.

`RBX=0x219c43a9` looks like a 32-bit RDRAND-flavored value (the
stack-canary secret, plausibly). It survives across the cr3 switch
because RBX is callee-saved.

## Why I think it's NOT what it looks like

### Not cr3_load
`post cr3_load(as1)` is printed AFTER the cr3 switch. That print
runs `serial_println` which:
1. Reads chars from a kernel string at fixed VA in `.rodata`
   (mapped under AS1 via the per-process PD-copy v1.25.1 fix).
2. Writes each char to UART port 0x3F8 via `out dx, al`.

Both work. So CR3 is AS1, kernel code path + kernel data are
reachable. cr3_load is fine.

### Not PD[6]
The pre-switch diagnostic reads PD[6] from kernel CR3 (which has
the same `new_pd` page identity-mapped via the kernel's 1 GB PD
extension from v1.25.0). Value: `0xE00087`. P=1, RW=1, US=1,
PS=1 — every bit needed for a kernel-mode write to succeed.

### Not proc_map_page
Same as above — it wrote the right value.

### Not the cr3-switch TLB flush
`mov cr3, rax` always invalidates non-global TLB entries. We have
no global pages set (no G bit in any PD entry). After the switch,
the TLB is empty. The walk for VA=0xC00000 must hit physical
memory (`new_pd[6]` at the `new_pd` physical address), and we
verified that holds 0xE00087.

## Hypotheses (ordered by plausibility)

### 1. PML4[0] / PDPT[0] gets clobbered between proc_map_page and cr3_load

If something between `proc_map_page(as1, 0xC00000, phys1)` and
`cr3_load(as1)` overwrote AS1's PML4[0] or PDPT[0], the walk
under CR3=AS1 would fail. The pre-switch diagnostic walked
PML4[0]→PDPT[0]→PD[6] successfully though — so they were correct
*at diagnostic time*. Anything between the diagnostic and
cr3_load could still corrupt them.

The intervening code:
```cyrius
var dbg_pd6 = load64(dbg_pd_addr + 48);
serial_print("AS1 PD[6] = ", 12);
kprint_num(dbg_pd6);
…
cr3_load(as1);
```

`serial_print` and `kprint_num` shouldn't touch page-table
memory. But cyrius might allocate stack/locals near the page-table
allocation — could a local-variable write spill onto `new_pml4`
or `new_pdpt`?

**How to test:** do a *post-switch* diagnostic. After cr3_load,
read AS1's PD[6] back via VA addressing. If it doesn't match
0xE00087, something corrupted it. If it does, hypothesis fails.
(Tricky because to read PD[6], we have to walk PML4→PDPT→PD,
which itself can fault — a chicken-and-egg.)

### 2. Stack canary check leaves a dangling pointer

v1.22.0 added stack canaries with a kernel-static `_canary` global
seeded from RDRAND. If a function on the stack frame has a canary
prologue, it stores `_canary`'s value at `[rbp-16]` (or wherever
the canary slot is). The check loads `[rbp-16]` and compares.

If `RBX` is being preserved across calls and *happens* to hold
the canary value (RDRAND output), and the test code dereferences
it (treating it as a pointer)… that explains `RBX=0x219c43a9` in
the fault dump. But then CR2 would be `0x219c43a9`, not
`0xC00000`. Doesn't match. Hypothesis weak.

### 3. cc5 codegen for the test's top-level statements is broken in a way that the diagnostics didn't expose

The diagnostic prints we added run *before* the failing store.
Maybe cc5 reorders statements OR emits the store64 with a wrong
operand (e.g. `mov [rax], imm` where rax holds something other
than 0xC00000). The fault `CR2=0xC00000` argues against this —
the CPU faulted on access to *exactly* 0xC00000, the literal
in the source.

### 4. The IDT itself is wrong under AS1's CR3

If AS1's PD doesn't map the IDT memory (at 0x11BB30 per the
fault dump), then the FIRST page-fault triggers a #PF on IDT
load. That cascades to #GP→#DF.

But the IDT is at ~1.15 MB, within PD[0]'s 0–2 MB range. AS1
inherits PD[0] from kernel (the per-process PD copy in
proc_create_address_space copies entry 0). So PD[0] is mapped.

…unless AS1's PD[0] has the wrong protection bits and the IDT
read needs RW or U that isn't there. Possible — kernel's PD[0]
was set by pt_init *without* the U bit (only PML4 and PDPT[0]
got U); only the PML4/PDPT need U for kernel access in long
mode. **Worth re-checking:** does CPU walk require U-bit
consistency at PD level for CPL=0 access? Per Intel SDM Vol 3
section 4.6, U/S=0 (supervisor only) at any level blocks
CPL=3 access; CPL=0 ignores it. So PD[0] without U should be
fine for kernel.

## Diagnostic path for next session

In priority order:

1. **Post-switch PD[6] read** — after cr3_load(as1), do
   `load64(dbg_pd_addr + 48)` and print. dbg_pd_addr is in
   AS1's identity-mapped range (we walked it pre-switch).
   If the value differs from 0xE00087, page tables were
   corrupted between diagnostic and switch.

2. **Walk PML4/PDPT post-switch** — check they're still pointing
   where we set them.

3. **Use cyrius CYRIUS_SYMS=** at build time to emit a symbol
   map for the kernel binary. Then map RIP=0x123BD7 back to
   the source function it's "in" (or just-past). That tells us
   whether RIP lands in a Cyrius-emitted helper or pure
   garbage-execution from a corrupted return.

4. **Try `qemu-system-x86_64 -d page,mmu`** (GDB-attached if
   needed) to see the page-walk on the failing access. QEMU
   prints why each level resolved to a fault.

5. **Single-step from `cr3_load` return** — `qemu -s -S` +
   `gdb` attached, set a breakpoint at the test's
   `store64(0xC00000, ...)`, single-step into and inspect
   page-walk.

## Workaround for now

Memory-isolation test stays gated behind
`-D MEMORY_ISOLATION_TEST`. v1.26.0's cr3_load helper still
ships — it's a real correctness fix for the
`var x = expr; asm { mov cr3, rax }` pattern even outside this
test. When the deeper diagnosis lands, re-enabling the test is
a one-line change (drop the `#ifdef`).
