# Issue: `serial_putc` 1.6–2× slower under cc5 vs cc3 baseline

**Status**: open — partial diagnosis, no actionable fix yet
**Date**: 2026-04-27
**Affects**: `kernel/arch/x86_64/serial.cyr` `serial_putc()`. All
            kernel logging paths use this — a hot function for
            anything that prints.

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
