#!/bin/sh
# cyrb-coverage — report test coverage by file
# Checks which lib/*.cyr files are exercised by test/program files.
# Reports function-level coverage: functions defined vs functions called in tests.
#
# Usage: cyrb coverage

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

total_libs=0
covered_libs=0
total_fns=0
covered_fns=0

echo "=== Coverage Report ==="
echo ""

for lib in "$REPO_ROOT"/lib/*.cyr; do
    name=$(basename "$lib" .cyr)
    total_libs=$((total_libs + 1))

    # Count functions defined in this lib
    lib_fns=$(grep -c "^fn " "$lib" 2>/dev/null || echo 0)
    total_fns=$((total_fns + lib_fns))

    # Check if any test/program file includes this lib
    has_test=0
    called_fns=0

    # Check programs/
    for prog in "$REPO_ROOT"/programs/*.cyr "$REPO_ROOT"/benches/*.cyr; do
        if [ -f "$prog" ]; then
            if grep -q "\"lib/${name}.cyr\"" "$prog" 2>/dev/null; then
                has_test=1
                # Count how many of this lib's functions are called
                while IFS= read -r fnline; do
                    fname=$(echo "$fnline" | sed 's/^fn //;s/(.*//')
                    if grep -q "$fname" "$prog" 2>/dev/null; then
                        called_fns=$((called_fns + 1))
                    fi
                done << FNEOF
$(grep "^fn " "$lib")
FNEOF
            fi
        fi
    done

    # Check tests/ (compiler.sh references)
    if grep -q "$name" "$REPO_ROOT/tests/compiler.sh" 2>/dev/null; then
        has_test=1
    fi
    if grep -q "$name" "$REPO_ROOT/tests/programs.sh" 2>/dev/null; then
        has_test=1
    fi

    if [ "$has_test" = "1" ]; then
        covered_libs=$((covered_libs + 1))
        covered_fns=$((covered_fns + called_fns))
        if [ "$lib_fns" -gt 0 ]; then
            pct=$((called_fns * 100 / lib_fns))
        else
            pct=100
        fi
        printf "  %-20s %3d/%d fns (%d%%)\n" "$name" "$called_fns" "$lib_fns" "$pct"
    else
        printf "  %-20s NO TESTS\n" "$name"
    fi
done

echo ""
echo "--- Summary ---"
echo "  Libraries: $covered_libs/$total_libs covered"
if [ "$total_fns" -gt 0 ]; then
    fn_pct=$((covered_fns * 100 / total_fns))
    echo "  Functions: $covered_fns/$total_fns called in tests ($fn_pct%)"
fi
echo ""

# Doc test count
doc_count=0
for lib in "$REPO_ROOT"/lib/*.cyr; do
    dc=$(grep -c "^# >>> " "$lib" 2>/dev/null) || dc=0
    doc_count=$((doc_count + dc))
done
echo "  Doc examples: $doc_count across all libs"

if [ "$covered_libs" -lt "$total_libs" ]; then
    exit 1
fi
