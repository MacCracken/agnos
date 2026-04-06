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

# Binary size sanity
echo ""
echo "--- Binary ---"
SZ=$(wc -c < "$ROOT/build/agnos")
test "$SZ" -gt 50000 && test "$SZ" -lt 150000
check "binary size ($SZ bytes)" $?

echo ""
echo "=========================="
echo "$pass passed, $fail failed"
test $fail -eq 0
