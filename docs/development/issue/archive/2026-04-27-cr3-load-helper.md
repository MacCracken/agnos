# Issue: `var x = expr; asm { mov cr3, rax }` pattern is broken under cc5

**Status**: open — implementation queued for agnos v1.26.0
**Date**: 2026-04-27
**Target**: agnos 1.26.0
**Affects**: `kernel/core/proc.cyr` (new helper),
            `kernel/core/main.cyr` (memory-isolation test rewrite),
            possibly `kernel/arch/x86_64/apic.cyr` and other call sites
            using the same pattern (audit pass).
**Author**: Robert MacCracken

## Summary

agnos v1.25.1 left the memory-isolation test gated behind
`#ifdef MEMORY_ISOLATION_TEST` because, even after the per-process
PD-mirror fix in `proc_create_address_space()`, the test's manual
cr3-switch pattern triple-faults under cc5. The pattern is:

```cyrius
var switch1 = as1;
asm { mov cr3, rax; }
```

This relies on a cc3-era implementation detail: that `var x = expr;`
leaves `expr`'s value in `RAX` after the assignment. cc5's regalloc
is more aggressive — it may spill the value to the stack and not
keep it live in RAX through the inline-asm boundary.

QEMU `-d cpu_reset,int` forensics showed:

- Initial fault under v1.25.0: `CR2=0x219C43A9` (kernel data ~561 MB,
  unmapped under per-process CR3) → fixed in v1.25.1 by extending
  the per-process PD copy to cover all 1 GB.
- After v1.25.1 fix: fault moves to `CR2=0xC00000` (the test page
  itself) with `RIP=0x123BD7` landing in the gvar zero block. RIP
  in zeros means execution ran past the test code into the data
  section — which only happens if the cr3 load actually went to a
  bogus value, the next access faulted, the IDT handler chain
  trampolined wrong, and we ended up executing nulls.

That second fault is consistent with `mov cr3, rax` loading a value
from RAX that wasn't `as1`. cc5's spill might leave `0xAAAA` in RAX
(the test value, since `RAX=0xaaaa` showed up in the fault dump),
or some other prior value.

## Background

### Why the pattern existed

The Cyrius kernel uses raw inline asm via `asm { 0xXX; ... }` byte
sequences. To pass a value into an asm block, two patterns are in
common use across the kernel today:

1. **Function with stack-relative loads** (`kernel/arch/x86_64/io.cyr`):
   ```cyrius
   fn outb(port, val) {
       asm {
           0x48; 0x8B; 0x55; 0xF8;   # mov rdx, [rbp - 8]   (first param)
           0x48; 0x8B; 0x45; 0xF0;   # mov rax, [rbp - 16]  (second param)
           0xEE;                       # out dx, al
       }
       return 0;
   }
   ```
   This is robust: Cyrius always allocates params at fixed `[rbp-N]`
   slots, regardless of regalloc decisions. Works under both cc3
   and cc5.

2. **Top-level assign-then-asm** (the broken pattern in
   `kernel/core/main.cyr` memory-isolation test):
   ```cyrius
   var switch1 = as1;
   asm { mov cr3, rax; }
   ```
   This is *not* a function call — it runs at the top level inside
   `kmain`'s emit. The author assumed `var x = y;` would leave `y`'s
   value in RAX. That's an incidental cc3 codegen detail, not a
   Cyrius language guarantee.

### Other sites using pattern 2

A grep across `kernel/` for `asm { mov cr3, rax; }` immediately
preceded by `var X = Y;` finds:

- `kernel/core/main.cyr` — memory-isolation test (3 sites: AS1, AS2,
  back to AS1, plus the kernel-CR3 restore using `var
  kern_cr3_restore = 0x1000;`).

The `mov rax, cr3 / mov cr3, rax` pattern (TLB flush) in
`apic.cyr`, `paging.cyr`, `ring3.cyr`, `iommu.cyr` is *different*
and safe — both reads of CR3 and writes-to-CR3 use the SAME register
that was just read, so RAX is guaranteed to hold the right value.

So memory-isolation test is the only site at risk. Out of scope:
auditing whether any future kernel code adopts pattern 2 by
copy-paste.

## Decision

### Path A — `cr3_load()` helper (recommended)

Add a single helper in `kernel/core/proc.cyr`:

```cyrius
fn cr3_load(cr3_val) {
    asm {
        0x48; 0x8B; 0x45; 0xF8;   # mov rax, [rbp - 8]   (cr3_val)
        0x0F; 0x22; 0xD8;         # mov cr3, rax
    }
    return 0;
}
```

Replace each `var switch_X = AS; asm { mov cr3, rax; }` in the test
with `cr3_load(AS)`. Remove the `#ifdef MEMORY_ISOLATION_TEST` gate
and re-enable the test by default.

**Pro:** Robust against cc5 regalloc, future cc6 regalloc, etc.
Matches the `outb` / `inb` pattern already in the kernel. Six
bytes of inline asm per call site (7 bytes if you count the call
+ ret overhead, but DCE will inline if it can).

**Con:** Adds a function call to a critical-path operation
(per-process address-space switch). Negligible — context switches
already do plenty of expensive work; one extra call is in the noise.

**Acceptance gate:**
- `kernel/core/main.cyr` memory-isolation test runs and prints
  `"Memory isolation: PASS"` after the cr3 dance.
- CI `Userland exec complete` checkpoint stays green (no regression
  in subsequent flow).
- Boot output still reaches the bench harness + `=== done ===`.

### Path B — Direct asm with literal cr3 value

For cases where the cr3 value is a known literal (e.g., the kernel
restore `0x1000`), use:

```cyrius
asm { 0x48; 0xB8; 0x00; 0x10; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00;  # mov rax, 0x1000
      0x0F; 0x22; 0xD8; }                                            # mov cr3, rax
```

**Pro:** No function-call overhead.

**Con:** Only works for compile-time literals. The test needs to
load AS1/AS2 which come from `proc_create_address_space()` — they
*aren't* literals.

Use Path B for the `0x1000` kernel-restore site. Use Path A for
the AS1/AS2 sites.

### Path C — Investigate cc5 codegen, file upstream

Disassemble what cc5 actually emits for `var switch1 = as1; asm {
mov cr3, rax; }` and check whether RAX is intentionally clobbered
between the two statements. If yes, file as a cyrius compiler issue
(possibly under a "preserve RAX across consecutive `var x = expr`
+ `asm`-using-RAX" feature). If the upstream answer is "this was
never a guarantee, fix your kernel," fall back to Path A.

**Pro:** Might benefit other kernel code if there's a real bug.

**Con:** Path A works regardless of the upstream answer. Time to
upstream answer is unbounded.

## Recommendation

**Path A** for AS1/AS2 sites, **Path B** for the `0x1000` literal
restore. Skip Path C unless we run into the same pattern elsewhere
and want a language-level guarantee.

## Implementation sketch

```diff
--- a/kernel/core/proc.cyr
+++ b/kernel/core/proc.cyr
@@ -113,6 +113,16 @@ var kpti_user_cr3 = 0x1000;
 
+fn cr3_load(cr3_val) {
+    # Load cr3_val (first param at [rbp-8] per Cyrius calling
+    # convention) into RAX, then write to CR3. Used in place of
+    # `var x = y; asm { mov cr3, rax; }` — that pattern relies on
+    # cc3-era codegen leaving the assigned value in RAX, which
+    # cc5's regalloc breaks.
+    asm { 0x48; 0x8B; 0x45; 0xF8; 0x0F; 0x22; 0xD8; }
+    return 0;
+}
+
 fn proc_create_address_space() {
     ...
```

```diff
--- a/kernel/core/main.cyr
+++ b/kernel/core/main.cyr
@@ -279,7 +279,6 @@ serial_println("Memory isolation test...", 23);
 ...
-#ifdef MEMORY_ISOLATION_TEST
-var switch1 = as1;
-asm { mov cr3, rax; }
+cr3_load(as1);
 store64(0xC00000, 0xAAAA);
 ...
-var kern_cr3_restore = 0x1000;
-asm { mov cr3, rax; }
+# Path B for literal: inline mov rax, 0x1000; mov cr3, rax
+asm {
+    0x48; 0xB8; 0x00; 0x10; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00;
+    0x0F; 0x22; 0xD8;
+}
-#endif
```

## Out of scope

1. **`serial_putc` 2× regression** (Active item #7). Different
   issue — that one is about cc5 codegen for the inline-asm
   sequence inside the function, not the assign-then-asm pattern.
   Tracked separately.
2. **Auditing other kernel code for the same pattern.** Already
   confirmed memory-isolation test is the only site (above).
3. **Path C upstream investigation.** Skip unless a future site
   surfaces the same problem.
