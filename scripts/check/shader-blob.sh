#!/bin/sh
# shader-blob — assemble a gfx90c shader source and emit (or CHECK) its kernel store32 table.
#
# ⛔ THE RISK THIS CLOSES IS TRANSCRIPTION. The kernel ships each shader as a `store32` table in
# kernel/core/gpu.cyr. Those dwords are supposed to be exactly what the assembler produced from the
# .s file — but nothing enforced it. A hand-edited table, a dword dropped during a paste, or a .s
# edited after the table was generated all ship green: the kernel builds, the blob is the wrong
# length or the wrong instruction, and the failure appears on iron as a wedged queue or a wrong
# picture with no pointer back to the cause.
#
# ⚠ WHAT THIS IS NOT. This is ONE assembler. The tree's standing discipline (gpu.cyr:2468) is that
# every shipped dword is verified by TWO INDEPENDENT assemblers — llvm-mc and the sovereign
# tests/gpu/edgeasm.cyr emitter — so that a bug in either is caught by the other. This script closes
# the "kernel table != assembled source" gap mechanically; it does NOT replace the second assembler,
# and a blob checked only by this script has not met the bar for a hardware run.
#
# Usage:
#   scripts/check/shader-blob.sh emit  kernel/shaders/tri_rgba.s tri_rgba   # print the Cyrius writer
#   scripts/check/shader-blob.sh check kernel/shaders/tri_rgba.s tri_rgba   # diff vs the committed table
#   scripts/check/shader-blob.sh rsrc  kernel/shaders/tri_rgba.s tri_rgba   # print harvested RSRC1/RSRC2
set -u

MODE="${1:-}"; SRC="${2:-}"; NAME="${3:-}"
[ -n "$MODE" ] && [ -n "$SRC" ] && [ -n "$NAME" ] || {
    echo "usage: $0 {emit|check|rsrc} <shader.s> <name>"; exit 2; }
[ -f "$SRC" ] || { echo "shader-blob: no such source: $SRC"; exit 2; }

# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for t in llvm-mc llvm-objcopy; do
    command -v "$t" >/dev/null 2>&1 || { echo "shader-blob: missing $t"; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

llvm-mc -triple=amdgcn-amd-amdhsa -mcpu=gfx90c -filetype=obj "$SRC" -o "$WORK/o" 2>"$WORK/err" || {
    echo "shader-blob: ASSEMBLY FAILED"; cat "$WORK/err"; exit 1; }
llvm-objcopy -O binary --only-section=.text   "$WORK/o" "$WORK/text"   2>/dev/null
llvm-objcopy -O binary --only-section=.rodata "$WORK/o" "$WORK/rodata" 2>/dev/null

# ⚠ RSRC1/RSRC2 are read from the kernel descriptor at .rodata bytes 48 and 52 — HARVESTED, never
# counted. A hand-derivation of edge_cov's RSRC1 once gave an SGPR field of 2 where the assembler
# grants 3; under-allocating the SGPR file corrupts the carry chain and lanes write the WRONG
# PIXELS, which is a plausible wrong picture rather than a fault.
python3 - "$WORK" "$NAME" "$MODE" "$ROOT" <<'PY'
import sys, re, os
work, name, mode, root = sys.argv[1:5]
text = open(os.path.join(work, "text"), "rb").read()
rod  = open(os.path.join(work, "rodata"), "rb").read()
dw = [int.from_bytes(text[i:i+4], "little") for i in range(0, len(text), 4)]
r1 = int.from_bytes(rod[48:52], "little"); r2 = int.from_bytes(rod[52:56], "little")

if mode == "rsrc":
    print("%s: %d dwords" % (name, len(dw)))
    print("RSRC1 = 0x%08X  -> %d VGPRs, %d SGPRs" % (r1, (r1 & 0x3F)*4+4, ((r1 >> 6) & 0xF)*8+8))
    print("RSRC2 = 0x%08X" % r2)
    raise SystemExit(0)

lines = ["fn %s_write(dst_phys) {" % name]
for i, d in enumerate(dw):
    lines.append("    store32(dst_phys + %-5d 0x%08x);" % (i*4 + 0x2C - 0x2C, d) if False
                 else "    store32(dst_phys + %-5s 0x%08x);" % (str(i*4) + ",", d))
lines.append("    return %d;" % (len(dw)*4))
lines.append("}")
gen = "\n".join(lines)

if mode == "emit":
    print(gen); raise SystemExit(0)

# check: pull the committed writer out of gpu.cyr and compare dword for dword.
src = open(os.path.join(root, "kernel/core/gpu.cyr")).read()
m = re.search(r"fn %s_write\(dst_phys\) \{(.*?)\n\}" % re.escape(name), src, re.S)
if not m:
    print("shader-blob: FAIL -- no fn %s_write in kernel/core/gpu.cyr" % name); raise SystemExit(1)
got = [int(x, 16) for x in re.findall(r"store32\(dst_phys \+ \s*\d+,\s*(0x[0-9a-fA-F]+)\)", m.group(1))]
if len(got) != len(dw):
    print("shader-blob: FAIL -- %s_write has %d dwords, the assembled shader has %d"
          % (name, len(got), len(dw))); raise SystemExit(1)
bad = [(i, g, w) for i, (g, w) in enumerate(zip(got, dw)) if g != w]
if bad:
    print("shader-blob: FAIL -- %d dword(s) differ from the assembled source:" % len(bad))
    for i, g, w in bad[:8]:
        print("    [%3d] table 0x%08x  assembled 0x%08x" % (i, g, w))
    raise SystemExit(1)
print("shader-blob: %s OK -- %d dwords match the assembled source" % (name, len(dw)))
print("            RSRC1 = 0x%08X  RSRC2 = 0x%08X" % (r1, r2))
PY
