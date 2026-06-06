#!/bin/sh
# AGNOS 3-tier kernel benchmarks
# Outputs: BENCHMARKS.md (auto-generated), bench-history.csv (append)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"

# kashi freestanding font-data core (1.37.5 fold-in). fb_console.cyr references
# KASHI_FONT_VGA_8X16 et al., so EVERY kernel build — including this bench
# build — must prepend kashi's font_data.cyr (a bare `cyrius build` fails on
# 'undefined KASHI_FONT_VGA_8X16'). Resolution mirrors scripts/build.sh:
# sibling-checkout default, auto-clone the pinned tag when absent.
KASHI_DIR="${KASHI_DIR:-$ROOT/../kashi}"
KASHI_REF="${KASHI_REF:-1.0.0}"
if [ ! -f "$KASHI_DIR/src/font_data.cyr" ]; then
    echo "  kashi not at $KASHI_DIR — cloning $KASHI_REF for bench build..." >&2
    rm -rf "$KASHI_DIR"
    git clone --quiet --depth 1 --branch "$KASHI_REF" \
        https://github.com/MacCracken/kashi.git "$KASHI_DIR" >&2 || {
        echo "ERROR: kashi clone failed (ref=$KASHI_REF)" >&2
        exit 1
    }
fi

echo "Building AGNOS with benchmarks..."
# The bench build rewrites the kybernet() launch in core/boot_finish.cyr to
# `bench_run_all(); arch_halt();` (boot_finish.cyr is where the launch site
# moved at the 1.36.2 split — main.cyr no longer holds `kybernet();`).
# bench_run_all() lives in core/bench.cyr (a build-time entry; inert in the
# normal build because boot_finish.cyr calls kybernet() there). It runs the
# three rdtsc tiers and prints the [tier1]/[tier2]/[tier3] + `=== done`
# markers this script parses below.
BFIN_CYR="$ROOT/kernel/core/boot_finish.cyr"
# `.benchbak` (not `.bak`): the kernel tree carries some committed `*.cyr.bak`
# cruft, and a plain `.bak` suffix would collide with / clobber those tracked
# files. `.benchbak` is a private suffix this script fully owns.
BFIN_BAK="$BFIN_CYR.benchbak"
cp "$BFIN_CYR" "$BFIN_BAK"

# Guard the test_procs shape: the boot-test procs (KTEST-gated) are already in
# their no-op `if (0 == 1)` form and must NOT busy-loop, else a scheduled proc
# would keep the scheduler alive past bench's arch_halt. We make a .bak and
# restore it unchanged (no transformation needed at the current shape), but the
# guard fails loudly if a future reshape reintroduces a `while (1 == 1)` busy-
# loop into test_procs.cyr — see that file's header comment.
TPROC_CYR="$ROOT/kernel/user/test_procs.cyr"
TPROC_BAK="$TPROC_CYR.benchbak"
cp "$TPROC_CYR" "$TPROC_BAK"
# `grep -c` exits 1 on zero matches — which is the EXPECTED case here (the
# procs are already no-ops). `|| true` keeps `set -e` from treating the
# zero-match (the healthy state) as a script failure.
TPROC_BUSY=$(grep -c 'while (1 == 1) {' "$TPROC_CYR" || true)
if [ "$TPROC_BUSY" -ne 0 ]; then
    echo "ERROR: bench.sh expected 0 'while (1 == 1) {' busy-loops in test_procs.cyr, found $TPROC_BUSY" >&2
    echo "       a busy-looping test_proc would keep the scheduler alive past bench's arch_halt." >&2
    echo "       test_procs.cyr shape diverged from bench.sh's contract — see file header comment." >&2
    rm -f "$TPROC_BAK"
    exit 1
fi
# Guard the call-site rewrite: if `kybernet(); arch_halt();` ever moves or is
# renamed (as it did at the 1.36.2 split when it left main.cyr for boot_finish),
# the sed would silently no-op and bench_run_all() would never be wired in —
# the bench kernel would just boot normally and emit ZERO numbers, populating an
# empty BENCHMARKS.md while exiting 0. Fail loud instead. Expect exactly one.
BFIN_MATCHES=$(grep -c 'kybernet(); arch_halt();' "$BFIN_CYR" || true)
if [ "$BFIN_MATCHES" -ne 1 ]; then
    echo "ERROR: bench.sh expected exactly 1 'kybernet(); arch_halt();' launch site in $BFIN_CYR, found $BFIN_MATCHES" >&2
    echo "       the bench entry-point rewrite would no-op — boot_finish.cyr's launch site diverged from bench.sh's contract." >&2
    rm -f "$BFIN_BAK" "$TPROC_BAK"
    exit 1
fi
sed -i 's/kybernet(); arch_halt();/bench_run_all(); arch_halt();/' "$BFIN_CYR"

# Restore the rewritten sources no matter how we exit from here (build error,
# QEMU failure, parse failure). The trap fires before the EXIT, leaving
# core/boot_finish.cyr + user/test_procs.cyr byte-identical to HEAD.
restore_sources() {
    [ -f "$BFIN_BAK" ]  && mv -f "$BFIN_BAK"  "$BFIN_CYR"
    [ -f "$TPROC_BAK" ] && mv -f "$TPROC_BAK" "$TPROC_CYR"
}
trap restore_sources EXIT INT TERM

if [ ! -x "$CYRB" ]; then
    echo "ERROR: cyrius required" >&2; exit 1
fi

# Build the PRODUCTION ELF64 kernel (kybernet→bench_run_all already rewritten).
# scripts/build.sh owns the kashi font-data prepend + the ELF64/multiboot2
# gates (CYRIUS_ELF64_KERNEL=1, #define ELF64_KERNEL) + the multiboot2
# validation. The bench kernel must take the SAME ELF64 path the real kernel
# does: the legacy `qemu -kernel` ELF32 entry hangs in apic_init under modern
# QEMU, so bench (like every smoke test) boots via gnoboot + OVMF below.
KASHI_DIR="$KASHI_DIR" sh "$ROOT/scripts/build.sh" >&2
cp "$ROOT/build/agnos" "$ROOT/build/agnos_bench"

# Sources restored — undo the trap so a later non-build failure doesn't try to
# restore already-restored files.
restore_sources
trap - EXIT INT TERM

echo "Booting bench kernel via gnoboot + OVMF..."
# The bench kernel reaches core/boot_finish.cyr and runs bench_run_all() in
# place of kybernet(), then arch_halt()s — it never execs userland, so no
# rootfs is needed. We still build a minimal GPT image (ESP with gnoboot +
# /boot/agnos) because gnoboot is the only ELF64 entry path (QEMU rejects the
# ELF64 kernel on its Linux `-kernel` protocol — no PVH note). Mirrors
# scripts/agnsh-smoke.sh's OVMF plumbing, minus the ext2 data partition.
GNOBOOT_ROOT="${GNOBOOT_ROOT:-$ROOT/../gnoboot}"
GNOBOOT="$GNOBOOT_ROOT/build/BOOTX64.EFI"
OVMF_CODE_CANDIDATES="/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_CANDIDATES="/usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE=""; for c in $OVMF_CODE_CANDIDATES; do [ -f "$c" ] && { OVMF_CODE="$c"; break; }; done
OVMF_VARS_SRC=""; for c in $OVMF_VARS_CANDIDATES; do [ -f "$c" ] && { OVMF_VARS_SRC="$c"; break; }; done

OUTPUT=""
if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS_SRC" ]; then
    echo "WARN: OVMF not found — cannot boot bench kernel; numbers will be empty" >&2
elif [ ! -f "$GNOBOOT" ]; then
    echo "WARN: gnoboot not built at $GNOBOOT — cannot boot bench kernel; numbers will be empty" >&2
else
    BWORK="$ROOT/build/bench-boot"
    rm -rf "$BWORK"; mkdir -p "$BWORK"
    IMG="$BWORK/bench.img"
    dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
    parted -s "$IMG" mklabel gpt mkpart ESP fat32 1MiB 33MiB set 1 esp on
    mformat -i "$IMG"@@1048576 -F
    mmd -i "$IMG"@@1048576 ::EFI ::EFI/BOOT ::boot
    mcopy -i "$IMG"@@1048576 "$GNOBOOT" ::EFI/BOOT/BOOTX64.EFI
    mcopy -i "$IMG"@@1048576 "$ROOT/build/agnos_bench" ::boot/agnos
    cp "$OVMF_VARS_SRC" "$BWORK/vars.fd"; chmod +w "$BWORK/vars.fd"
    # Accel: prefer KVM (-cpu host) for stable, real-cycle rdtsc. TCG's
    # rdtsc is host-TSC-based and swings ~5x run-to-run, which makes fine
    # perf deltas unmeasurable. Fall back to -cpu max (TCG) when /dev/kvm is
    # absent or BENCH_KVM=0. The CSV records kvm_enabled so KVM and TCG rows
    # stay non-comparable on purpose.
    BENCH_ACCEL="-cpu max"
    if [ -r /dev/kvm ] && [ "${BENCH_KVM:-1}" = "1" ]; then BENCH_ACCEL="-enable-kvm -cpu host"; fi
    OUTPUT=$(timeout "${QEMU_TIMEOUT:-40}" qemu-system-x86_64 \
        -machine q35 -m 512M $BENCH_ACCEL \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$BWORK/vars.fd" \
        -drive "file=$IMG,format=raw,if=none,id=disk0" \
        -device "nvme,drive=disk0,serial=AGNOS-BENCH" \
        -serial stdio -display none -no-reboot 2>/dev/null | tr -d '\0' || true)
    rm -rf "$BWORK"
fi

COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo "dev")

# v1.28.1: capture provenance so cross-run comparisons are honest.
# A serial_putc number under QEMU 7.x + KVM is not comparable to one
# under QEMU 11.x + TCG. Recording the conditions makes "did codegen
# regress?" a decidable question instead of a vibes-based one.
QEMU_VERSION=$(qemu-system-x86_64 --version 2>/dev/null | head -1 | awk '{print $4}' || echo "unknown")
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //; s/,/;/g' || echo "unknown")
HOST_ARCH=$(uname -m 2>/dev/null || echo "unknown")
KVM_ENABLED=0
if echo "${BENCH_ACCEL:-}" | grep -q '\-enable-kvm'; then
    KVM_ENABLED=1
fi
CYRIUS_VERSION=$(grep -oE '^cyrius = "[^"]+"' "$ROOT/cyrius.cyml" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || echo "unknown")

echo ""
echo "=== AGNOS Benchmarks v$VERSION ($COMMIT) ==="
# `|| true`: a zero-match grep exits 1, which would kill the script under
# `set -e` (e.g. if the boot produced no markers). Display is best-effort.
echo "$OUTPUT" | grep -E "cycles/op|Kcycles|submits|\[tier" || true
if ! echo "$OUTPUT" | grep -qE "cycles/op|Kcycles|\[tier"; then
    echo "WARN: no benchmark markers in boot output — BENCHMARKS.md sections will be empty." >&2
fi

# Generate BENCHMARKS.md
cat > "$ROOT/BENCHMARKS.md" << HEADER
# Benchmarks

> Auto-generated by \`scripts/bench.sh\` — do not edit manually.
> 3-tier kernel benchmark suite: core, subsystems, integration.

| | Current |
|---|---|
| **Date** | \`$DATE\` |
| **Commit** | \`$COMMIT\` |
| **Version** | $VERSION |
| **Environment** | QEMU x86_64, rdtsc cycles |

## core

| Benchmark | \`$COMMIT\` |
|---|---|
HEADER

echo "$OUTPUT" | sed -n '/\[tier1\]/,/\[tier2\]/p' | grep ":" | grep -v "tier" | while IFS= read -r line; do
    name=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
    val=$(echo "$line" | sed 's/.*: //')
    echo "| $name | $val |" >> "$ROOT/BENCHMARKS.md"
done

cat >> "$ROOT/BENCHMARKS.md" << MID

## subsystems

| Benchmark | \`$COMMIT\` |
|---|---|
MID

echo "$OUTPUT" | sed -n '/\[tier2\]/,/\[tier3\]/p' | grep ":" | grep -v "tier" | while IFS= read -r line; do
    name=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
    val=$(echo "$line" | sed 's/.*: //')
    echo "| $name | $val |" >> "$ROOT/BENCHMARKS.md"
done

cat >> "$ROOT/BENCHMARKS.md" << END

## integration

| Benchmark | \`$COMMIT\` |
|---|---|
END

echo "$OUTPUT" | sed -n '/\[tier3\]/,/=== done/p' | grep ":" | grep -v "tier\|done" | while IFS= read -r line; do
    name=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
    val=$(echo "$line" | sed 's/.*: //')
    echo "| $name | $val |" >> "$ROOT/BENCHMARKS.md"
done

echo "" >> "$ROOT/BENCHMARKS.md"
echo "Written to BENCHMARKS.md"

# Append to history CSV
# Schema (v1.28.1+): 7 base columns + 5 provenance columns appended at
# end. Old rows (pre-1.28.1) have empty trailing cells — CSV-compatible.
# Order: date,commit,version,tier,benchmark,value,unit,
#        qemu_version,cpu_model,host_arch,kvm_enabled,cyrius_version
# Pre-1.28.1 header had only 5 columns ("date,commit,benchmark,value,unit");
# the body rows were already writing 7 columns (with two empty fields
# for version+tier). v1.28.1 rewrites the header to match the body and
# adds the 5 provenance columns.
if [ ! -f "$ROOT/bench-history.csv" ]; then
    echo "date,commit,version,tier,benchmark,value,unit,qemu_version,cpu_model,host_arch,kvm_enabled,cyrius_version" > "$ROOT/bench-history.csv"
fi

echo "$OUTPUT" | { grep "cycles/op\|Kcycles" || true; } | while IFS= read -r line; do
    name=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
    val=$(echo "$line" | sed 's/.*: //; s/ .*//')
    unit=$(echo "$line" | sed 's/.* //')
    echo "$DATE,$COMMIT,$VERSION,,$name,$val,$unit,$QEMU_VERSION,$CPU_MODEL,$HOST_ARCH,$KVM_ENABLED,$CYRIUS_VERSION" >> "$ROOT/bench-history.csv"
done

rm -f $ROOT/build/agnos_bench
echo "Appended to bench-history.csv"
