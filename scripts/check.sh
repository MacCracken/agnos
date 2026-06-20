#!/bin/sh
# AGNOS project check — run all validations
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0

check() {
    if [ "$2" = "0" ]; then
        echo "  PASS: $1"
        pass=$((pass + 1))
    else
        echo "  FAIL: $1"
        fail=$((fail + 1))
    fi
}

echo "=== AGNOS Check ==="
echo ""

# Build
echo "--- Build ---"
sh "$ROOT/scripts/build.sh" > /dev/null 2>&1
check "x86_64 build" $?

# Tests
echo ""
echo "--- Tests ---"
sh "$ROOT/scripts/test.sh" > /dev/null 2>&1
check "test suite" $?

# Required docs
echo ""
echo "--- Documentation ---"
for doc in README.md CHANGELOG.md VERSION CONTRIBUTING.md SECURITY.md LICENSE; do
    test -f "$ROOT/$doc"
    check "doc: $doc" $?
done

# Version consistency
echo ""
echo "--- Version Consistency ---"
VERSION=$(cat "$ROOT/VERSION" | tr -d '[:space:]')
echo "  VERSION file: $VERSION"
grep -q "$VERSION" "$ROOT/kernel/agnos.cyr" 2>/dev/null
check "version in kernel" $?
grep -q "$VERSION" "$ROOT/CHANGELOG.md" 2>/dev/null
check "version in changelog" $?

# Binary size sanity. The 350KB bound dated to the v1.22.0 / ~250KB era and
# went stale across the storage (1.31.x), networking (1.32.x), ext2/4-write
# (1.33.x), FAT-family (1.34.x), and DNS (1.35.x) arcs — the kernel is ~806KB.
# Ceiling moved to 1.2M, then 1.4M: the 1.44.x scheduler + 1.45.x net arcs closed
# on 1.2M and the 1.46.x lseek/flock syscalls crossed it (~1,203,984 B), so the
# bound moved 1.2M → 1.4M — still catching a runaway-bloat regression. Matches
# scripts/test.sh (bumped in lockstep).
echo ""
echo "--- Binary ---"
SZ=$(wc -c < "$ROOT/build/agnos")
test "$SZ" -gt 50000 && test "$SZ" -lt 1400000
check "binary size ($SZ bytes)" $?

echo ""
echo "=========================="
echo "$pass passed, $fail failed"
test $fail -eq 0
