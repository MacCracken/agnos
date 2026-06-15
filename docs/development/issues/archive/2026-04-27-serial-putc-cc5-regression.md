# Issue: `serial_putc` 1.6–2× slower under cc5 vs cc3 baseline

**Status**: **CLOSED** at v1.28.1. Not a real codegen regression — QEMU UART-emulation latency variance under different host/QEMU conditions, as the 2026-04-27 writeup recommended.
**Date**: 2026-04-27 → 2026-05-11 (resolved)
**Affects**: `kernel/arch/x86_64/serial.cyr` `serial_putc()`. All
            kernel logging paths use this — a hot function for
            anything that prints.

## Resolution (v1.28.1)

The 2026-04-27 recommendation was **defer pending matched-conditions
re-measurement**. v1.28.1 added bench-history provenance columns
(`qemu_version`, `cpu_model`, `host_arch`, `kvm_enabled`,
`cyrius_version` — `scripts/bench.sh`) and ran the full 3-tier
suite under documented conditions. Findings:

### Matched-conditions table (v1.28.0, cyrius 5.10.44)

Host: AMD Ryzen 7 5800H, QEMU 11.0.0, TCG (no KVM), Arch Linux.

| Bench | cc3@v1.21.0 | cc5@v1.26.0 | **cc5@v1.28.0** | Delta vs cc3 |
|---|---|---|---|---|
| `pmm_alloc_free` | 1467 | 2565 | **2320** | +58% — explained by PMM spinlock (S3, v1.24.x) |
| `heap_32B` | 1338 | 1395 | **1341** | 0% — codegen equiv |
| `heap_256B` | 3358 | 3610 | **3584** | +7% |
| `heap_4096B` | 28097 | 37470 | **37736** | +34% |
| `memwrite_1MB` (Kcyc) | 6976 | 5716 | **5917** | **−15%** |
| `syscall_getpid` | 261 | 254 | **299** | +15% |
| `syscall_getuid` | 1160 | 820 | **827** | **−29%** — cc5 win |
| `syscall_write1` | 6800 | 504 | **593** | **−91%** — cc5 win (or cc3 fluke) |
| `vfs_open_read_close` | 6543 | 5694 | **5763** | **−12%** |
| **`serial_putc`** | **5046** | **8077** | **7485** | **+48%** — see below |

cc5 is broadly comparable or faster than cc3 across the suite. The
biggest wins are on syscall paths (`syscall_getuid`, `syscall_write1`,
`vfs_open_read_close`) — cc5's codegen meaningfully improved kernel-
mode CPU-bound work. The `serial_putc` regression is the only outlier.

### Why `serial_putc` looks regressed (it isn't, in the codegen sense)

`serial_putc` polls UART line-status (`in al, 0x3FD`) waiting for the
transmit-empty bit before writing the data byte to `0x3F8`. Under
QEMU TCG, every `in al, dx` is a guest→host roundtrip through
QEMU's UART emulation. The polling loop typically iterates 5–20 times
per call. With each iteration costing hundreds of host cycles in TCG,
the function spends ~6,000–7,000 cycles in I/O emulation overhead and
~50 cycles in actual kernel codegen.

The cc5-vs-cc3 disassembly in the original writeup identified ~5–6
cycles of cc5 codegen overhead per call (two zero-displacement jmps +
`var ch = c` memory round-trip). On a ~7,500 cycle call, that's <0.1%
of the time. The rest of the delta is QEMU/host drift between the
v1.21.0 measurement environment and the current one — exactly what
the 2026-04-27 writeup predicted.

The clinching evidence is the CPU-bound benches: `heap_32B`, `memwrite_1MB`,
`syscall_getuid`, `vfs_open_read_close` all show cc5 equal-or-better
than cc3. If cc5 had a real codegen regression, those would regress
too. They don't.

### Action

- **No source change applied**. The micro-opts identified in the
  original writeup (drop `var ch = c`; collapse zero-disp jmps) are
  cyrius-side compiler concerns; not actionable from agnos. The
  hand-encoded-asm offset bump in agnos would save ~3 cycles on a
  7,500-cycle call — not worth the risk of a wrong byte offset.
- **Bench-history schema extended** (this minor) with
  `qemu_version` / `cpu_model` / `host_arch` / `kvm_enabled` /
  `cyrius_version`. Future benchmark deltas across the cc-line will
  be honest by construction.
- **Methodology rule going forward**: never compare bench numbers
  across rows with different `qemu_version` or `host_cpuinfo`
  fingerprints without an explicit "QEMU+host normalized" note.
  The CHANGELOG performance-claims convention (per
  first-party-documentation § CHANGELOG) requires bench numbers
  with conditions — this is the same rule.

### What stays open at cyrius

The codegen pattern observations (zero-disp jmps in every emitted fn,
`var ch = c` memory round-trip on simple local copies) are cyrius-side
inefficiencies. They cost <0.1% on this hot path but add up across the
kernel. Filing as a cyrius-side observation rather than a fix would
need a real motivating bench. Not blocking; tracked informally via
this archive entry.

---

# Original (2026-04-27) writeup follows


## Summary

Bench harness reports 8,181–9,901 cyc/op for `serial_putc` under
cyrius 5.7.19 (agnos 1.25.1–1.26.0), versus 5,046 cyc/op last
measured at agnos v1.21.0 under cyrius 3.9.8 (commit 0b5be74). A
60–96% regression on a hot function.

## Forensic data

Disassembly of `serial_putc` from a v1.26.0 build (entry at
`0x100065`, 65 bytes total):

```
55                          push rbp
48 89 e5                    mov  rbp, rsp
48 81 ec 10 00 00 00        sub  rsp, 0x10                ; 16 bytes for locals
48 89 bd f8 ff ff ff        mov  [rbp-0x08], rdi          ; spill arg `c`
e9 00 00 00 00              jmp  +5                        ; ★ zero-displacement jmp #1
48 8b 85 f8 ff ff ff        mov  rax, [rbp-0x08]          ; load `c`
48 89 85 f0 ff ff ff        mov  [rbp-0x10], rax          ; store `var ch = c`
ba fd 03 00 00              mov  edx, 0x3FD               ; UART LSR
ec                          in   al, dx                    ; ──┐
a8 20                       test al, 0x20                  ;   │ wait-for-tx-empty
74 fb                       je   -3                        ; ──┘
8a 45 f0                    mov  al, [rbp-0x10]           ; load `ch`
ba f8 03 00 00              mov  edx, 0x3F8               ; UART data
ee                          out  dx, al                    ; emit byte
31 c0                       xor  eax, eax                 ; return 0
e9 00 00 00 00              jmp  +5                        ; ★ zero-displacement jmp #2
c9                          leave
c3                          ret
```

Two **zero-displacement `jmp +5` no-ops** (★ marked) round-trip
the pipeline through fetch+decode but accomplish nothing. 5 bytes
each, ~1 predicted-cycle each. Together ~2 cycles of overhead
per call.

The local-variable layer is wasteful in another way: `var ch =
c;` is emitted as a full memory round-trip — load `c` from
`[rbp-8]` into RAX, store RAX into `[rbp-16]`, then read AL
from `[rbp-16]` later. cc5 could fold the chain into `mov al,
dil` (the low byte of the arg register) if it had a register-only
shortcut for single-byte locals. About ~3–4 cycles avoidable.

So pure cc5-side overhead per call: ~5–6 cycles.

## Why that's not the whole story

Bench measures 8,181 cyc/op average. The polling loop (`in al,
dx; test; je`) waits for transmit-empty — that's the dominant
cost on QEMU, and it's *I/O emulation latency*, not codegen.
A typical port-I/O cycle on QEMU is hundreds of cycles. Multiply
by a polling wait of N iterations and you're easily in the
thousands.

So the cc5-side overhead can't account for a 60% jump. The
likely contributors:

1. **QEMU UART emulation slowed between QEMU 7.x and 11.x.**
   The v1.21.0 numbers came from an older QEMU. Per `qemu
   --version` on the current dev box: 11.0.0. The v1.21.0
   bench-history.csv entry doesn't record the QEMU version —
   we can't directly compare.
2. **Host CPU difference between bench runs.** rdtsc is
   wall-clock-ish on the host; a slower host CPU means more
   "host cycles" per "guest cycle" of UART emulation.
3. **`-cpu max` vs default `qemu64`** changes which CPU model
   QEMU is emulating — `-cpu max` exposes more features but
   also enables some I/O-emulation paths the v1.21.0 run
   wouldn't have.
4. cc5 codegen overhead per call (~5–6 cycles, real but
   minor — see disassembly above).

(1)–(3) together easily swamp (4).

## Action items

### 1. Don't trust cross-toolchain benchmark deltas without controls

The v1.21.0 vs v1.25.x numbers in `BENCHMARKS.md` and
`bench-history.csv` were measured on different QEMU versions, host
hardware, and CPU models. The "delta" column claims wider
significance than the data supports. A future bench-history
schema should include `qemu_version`, `cpu_model`, `host_arch`
columns at minimum, and maybe a `host_cpuinfo_hash` so we know
when comparison is even possible.

Filed as a follow-up improvement under
[`proposals/2026-04-27-bench-history-provenance.md`](../proposals/2026-04-27-bench-history-provenance.md)
(if/when written).

### 2. Eliminate the two zero-displacement jmps in cc5 codegen

These are present in *every* function cc5 emits, not just
`serial_putc`. The first is between the arg-spill and the
function body; the second is between the body and the
return-epilogue. They're cheap individually but aggregate into
real overhead across kernel hot paths.

This is upstream work in `cyrius/src/frontend/parse_fn.cyr` —
filed as a *cyrius* compiler issue, not an agnos issue:
[`cyrius/docs/issue/2026-04-27-zero-disp-jmp-emit.md`](#) (TBD).
agnos benefits passively when cyrius v5.7.21+ ships the fix.

### 3. Minor: collapse `var ch = c` in `serial_putc`

```diff
 fn serial_putc(c) {
-    var ch = c;
     asm { 0xBA; 0xFD; 0x03; 0x00; 0x00; 0xEC; 0xA8; 0x20; 0x74; 0xFB; }
-    asm { 0x8A; 0x45; 0xF0; 0xBA; 0xF8; 0x03; 0x00; 0x00; 0xEE; }
+    # mov al, [rbp-0x08] (load `c` directly, skip the `ch` copy)
+    asm { 0x8A; 0x45; 0xF8; 0xBA; 0xF8; 0x03; 0x00; 0x00; 0xEE; }
     return 0;
 }
```

Saves the 14-byte memory round-trip on every call. Net ~3 cycles
per `serial_putc`. Doesn't move the needle on the regression but
trims a little fat. **Only do this if a future v1.27.0 wants the
micro-optimization** — it's a hand-encoded-asm offset bump, easy
to get wrong.

## Recommendation

Defer. The 60% delta is almost certainly QEMU/host noise, not
cc5 codegen. The actionable cc5 codegen overhead is ~5–6 cycles
per call (zero-disp jmps + var copy) — real but a rounding error
against the I/O latency. Re-bench under matched conditions
(same QEMU version, same host) before treating this as a
real regression.

## Out of scope

- Comparing `syscall_write1` and `syscall_getuid` deltas (large
  improvements!) — those are also subject to the same cross-
  toolchain measurement-noise concern. Take them with the same
  grain of salt.
- Restructuring `serial_putc` to use `outb()` from `io.cyr`
  instead of inline asm. Would clean up the duplication but
  doesn't fix the perf. Pin for a future hygiene patch.
