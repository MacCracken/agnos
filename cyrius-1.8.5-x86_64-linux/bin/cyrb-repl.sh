#!/bin/sh
# cyrb-repl — interactive Cyrius expression evaluator
# Type expressions, see results. Uses exit code for simple values.
# Multi-line: end with ;; to execute.
#
# Usage: cyrb repl

CC="${1:-./build/cc2}"

echo "Cyrius REPL ($(cat VERSION 2>/dev/null || echo '?'))"
echo "Type expressions. Result = exit code (0-255). Use syscall(1,1,...) for output."
echo "End multi-line with ;;   Ctrl+D to exit."
echo ""

# Preamble includes
PREAMBLE='include "lib/string.cyr"
include "lib/fmt.cyr"
include "lib/alloc.cyr"
include "lib/vec.cyr"
include "lib/hashmap.cyr"
include "lib/tagged.cyr"
include "lib/str.cyr"
fn _print(n) { fmt_int(n); syscall(1, 1, "\n", 1); return 0; }
fn main() { alloc_init();
'
EPILOGUE='
}
var _r = main();
syscall(60, _r);'

buffer=""
prompt="> "

while true; do
    printf "%s" "$prompt"
    if ! IFS= read -r line; then
        echo ""
        echo "bye"
        break
    fi

    # Check for special commands
    case "$line" in
        ":q"|":quit"|"exit") echo "bye"; break ;;
        ":help"|":h")
            echo "  :q          quit"
            echo "  :type expr  show value as decimal"
            echo "  ;;          execute multi-line buffer"
            echo "  expr;       evaluate expression (exit code = result mod 256)"
            continue
            ;;
        ":type "*)
            expr=$(echo "$line" | sed 's/^:type //')
            src="${PREAMBLE}_print(${expr});return 0;${EPILOGUE}"
            echo "$src" | "$CC" > /tmp/cyrb_repl_$$ 2>/dev/null && chmod +x /tmp/cyrb_repl_$$ && /tmp/cyrb_repl_$$ 2>/dev/null
            rm -f /tmp/cyrb_repl_$$
            continue
            ;;
    esac

    # Accumulate multi-line
    buffer="${buffer}${line}
"

    # Check for ;; (execute) or single-line with ;
    case "$line" in
        *";;")
            # Strip trailing ;;
            buffer=$(echo "$buffer" | sed 's/;;$//')
            ;;
        *";")
            # Single statement — execute immediately
            ;;
        *)
            # Incomplete — wait for more
            prompt="... "
            continue
            ;;
    esac

    # Execute
    # Wrap in main, last expression becomes return value
    src="${PREAMBLE}${buffer}${EPILOGUE}"
    tmpbin="/tmp/cyrb_repl_$$"
    if echo "$src" | "$CC" > "$tmpbin" 2>/tmp/cyrb_repl_err_$$; then
        chmod +x "$tmpbin"
        result=$("$tmpbin" 2>/dev/null; echo $?)
        echo "= $result"
    else
        # Show error
        cat /tmp/cyrb_repl_err_$$ 2>/dev/null
        echo "(compile error)"
    fi
    rm -f "$tmpbin" /tmp/cyrb_repl_err_$$

    buffer=""
    prompt="> "
done
