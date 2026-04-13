#!/bin/sh
# AGNOS kernel functional test suite
# Runs sh_cmd_test() inside the kernel via QEMU, parses serial output.
# Exit code: 0 = all passed, 1 = failures
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRB="$CYRIUS_HOME/bin/cyrius"

echo "Building AGNOS with test suite..."
MAIN_CYR="$ROOT/kernel/core/main.cyr"
MAIN_BAK="$MAIN_CYR.bak"
cp "$MAIN_CYR" "$MAIN_BAK"
TPROC_CYR="$ROOT/kernel/user/test_procs.cyr"
TPROC_BAK="$TPROC_CYR.bak"
cp "$TPROC_CYR" "$TPROC_BAK"

# Patch: run tests then halt (skip interactive shell)
sed -i 's/while (1 == 1) {/if (0 == 1) {/' "$TPROC_CYR"
sed -i 's/exec_and_wait(exec_entry, exec_rsp, exec_cr3);/# skipped/' "$MAIN_CYR"
sed -i 's/sh_cmd_bench(); arch_halt();/sh_cmd_test(); arch_halt();/' "$MAIN_CYR"

if [ -x "$CYRB" ]; then
    (cd "$ROOT/kernel" && "$CYRB" build -D ARCH_X86_64 -D TEST "$ROOT/kernel/agnos.cyr" "$ROOT/build/agnos_ktest") 2>&1
    RESULT=$?
    mv "$MAIN_BAK" "$MAIN_CYR"
    mv "$TPROC_BAK" "$TPROC_CYR"
    if [ $RESULT -ne 0 ]; then echo "Build failed"; exit 1; fi
else
    mv "$MAIN_BAK" "$MAIN_CYR"
    mv "$TPROC_BAK" "$TPROC_CYR"
    echo "ERROR: cyrius required at $CYRB" >&2; exit 1
fi

echo "Booting on QEMU (15s timeout)..."
OUTPUT=$(timeout 15 qemu-system-x86_64 -kernel "$ROOT/build/agnos_ktest" -serial stdio -display none -no-reboot 2>/dev/null | tr -d '\0' || true)

rm -f "$ROOT/build/agnos_ktest"

# Parse results
echo ""
echo "$OUTPUT" | grep -E "=== AGNOS Kernel|^\[|PASS:|FAIL:|TOTAL:|ALL TESTS"
echo ""

TOTAL_LINE=$(echo "$OUTPUT" | grep "TOTAL:" | head -1)
if [ -z "$TOTAL_LINE" ]; then
    echo "ERROR: test output not found (kernel may have crashed)"
    exit 1
fi

FAILURES=$(echo "$TOTAL_LINE" | sed 's/.*passed, //' | sed 's/ failed.*//' | tr -d '[:space:]')
if [ "$FAILURES" = "0" ]; then
    echo "RESULT: ALL TESTS PASSED"
    exit 0
else
    echo "RESULT: $FAILURES TESTS FAILED"
    exit 1
fi
