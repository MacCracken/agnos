#!/bin/sh
# cyrb-doctest — extract and run doc examples from .cyr files
# Lines starting with "# >>> " are compiled and run. Expected exit code after "# === ".
#
# Example in a .cyr file:
#   # >>> var x = 6 * 7;
#   # === 42
#
# Multi-line examples accumulate until === (exit check) or next >>> (new example).
#
# Usage: cyrb doctest lib/*.cyr

CC="${1:-./build/cc2}"
shift 2>/dev/null || true

if [ -z "$1" ]; then
    echo "Usage: cyrb doctest <file.cyr> [file2.cyr ...]"
    exit 1
fi

pass=0
fail=0
skip=0
total=0

for file in "$@"; do
    code=""
    expected=""
    in_example=0
    line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        case "$line" in
            "# >>> "*)
                # New example line
                snippet=$(echo "$line" | sed 's/^# >>> //')
                if [ "$in_example" = "0" ]; then
                    code="$snippet"
                    in_example=1
                else
                    code="$code
$snippet"
                fi
                ;;
            "# === "*)
                # Expected exit code
                expected=$(echo "$line" | sed 's/^# === //' | tr -d '[:space:]')
                if [ "$in_example" = "1" ] && [ -n "$code" ]; then
                    total=$((total + 1))
                    # Compile and run
                    tmpbin="/tmp/cyrb_doctest_$$"
                    if echo "$code" | "$CC" > "$tmpbin" 2>/dev/null; then
                        chmod +x "$tmpbin"
                        result=$(timeout 5 "$tmpbin" 2>/dev/null; echo $?)
                        if [ "$result" = "$expected" ]; then
                            pass=$((pass + 1))
                        else
                            echo "  FAIL: $(basename $file):$line_num (expected $expected, got $result)"
                            fail=$((fail + 1))
                        fi
                    else
                        echo "  FAIL: $(basename $file):$line_num (compile error)"
                        fail=$((fail + 1))
                    fi
                    rm -f "$tmpbin"
                fi
                code=""
                in_example=0
                ;;
            "# "*)
                # Continuation line in example
                if [ "$in_example" = "1" ]; then
                    snippet=$(echo "$line" | sed 's/^# //')
                    code="$code
$snippet"
                fi
                ;;
            *)
                # Non-comment line ends any active example without running
                if [ "$in_example" = "1" ] && [ -z "$expected" ]; then
                    skip=$((skip + 1))
                fi
                code=""
                in_example=0
                ;;
        esac
    done < "$file"
done

echo ""
echo "$pass passed, $fail failed, $skip skipped ($total total doc tests)"
if [ "$fail" -gt 0 ]; then exit 1; fi
