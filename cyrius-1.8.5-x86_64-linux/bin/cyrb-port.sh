#!/bin/sh
# cyrb port — prepare a Rust project for Cyrius porting
# Moves Rust code to rust-old/, scaffolds Cyrius project structure,
# vendors stdlib, generates initial source file.
#
# Usage: cyrb port /path/to/rust-project

set -e

TARGET="$1"
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
    echo "Usage: cyrb port <path-to-rust-project>"
    echo "Moves Rust to rust-old/, creates Cyrius project structure."
    exit 1
fi

cd "$TARGET"
NAME=$(basename "$(pwd)")

if [ ! -f "Cargo.toml" ]; then
    echo "error: no Cargo.toml found in $TARGET"
    exit 1
fi

if [ -d "rust-old" ]; then
    echo "error: rust-old/ already exists — project may already be ported"
    exit 1
fi

echo "=== Porting $NAME to Cyrius ==="

# Count Rust LOC
RUST_LOC=$(find src -name "*.rs" 2>/dev/null | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
echo "  Rust source: ${RUST_LOC:-0} lines"

# Move Rust code
mkdir -p rust-old
for item in src benches examples fuzz tests supply-chain include py \
    Cargo.toml Cargo.lock rust-toolchain.toml deny.toml codecov.yml \
    Makefile bench-history.csv benchmarks.md target rust_out; do
    if [ -e "$item" ]; then
        mv "$item" rust-old/
    fi
done
echo "  Moved Rust to rust-old/"

# Record LOC
echo "${RUST_LOC:-0}" > rust-old/LINES_OF_RUST.txt

# Create Cyrius structure
mkdir -p src lib programs tests

# Vendor stdlib from installed Cyrius
CYRIUS_LIB="${CYRIUS_HOME:-$HOME/.cyrius}/versions/$(cat "${CYRIUS_HOME:-$HOME/.cyrius}/current" 2>/dev/null)/lib"
if [ -d "$CYRIUS_LIB" ]; then
    cp "$CYRIUS_LIB"/*.cyr lib/ 2>/dev/null
    echo "  Vendored stdlib ($(ls lib/*.cyr 2>/dev/null | wc -l) modules)"
else
    echo "  warn: Cyrius not installed, stdlib not vendored"
fi

# Generate initial source file
cat > src/main.cyr << CYRSRC
# $NAME — Cyrius port
# Ported from ${RUST_LOC:-0} lines of Rust

include "lib/string.cyr"
include "lib/fmt.cyr"
include "lib/alloc.cyr"
include "lib/vec.cyr"
include "lib/str.cyr"
include "lib/syscalls.cyr"

fn main() {
    alloc_init();
    println("$NAME ready");
    return 0;
}

var r = main();
syscall(SYS_EXIT, r);
CYRSRC
echo "  Created src/main.cyr"

# Generate cyrb.toml
cat > cyrb.toml << TOML
name = "$NAME"
version = "0.1.0"
license = "GPL-3.0-only"
entry = "src/main.cyr"
output = "$NAME"
description = "$NAME — Cyrius port"
TOML
echo "  Created cyrb.toml"

# Generate basic test
cat > tests/test.sh << TEST
#!/bin/sh
CC="\${1:-./build/cc2}"
echo "=== $NAME tests ==="
cat src/main.cyr | "\$CC" > /tmp/${NAME}_test && chmod +x /tmp/${NAME}_test && /tmp/${NAME}_test
echo "exit: \$?"
rm -f /tmp/${NAME}_test
TEST
chmod +x tests/test.sh
echo "  Created tests/test.sh"

echo ""
echo "=== $NAME ready for porting ==="
echo "  Rust (rust-old/): ${RUST_LOC:-0} lines"
echo "  Cyrius (src/):    skeleton created"
echo ""
echo "Next steps:"
echo "  1. Read rust-old/src/lib.rs to understand the API"
echo "  2. Port module by module into src/main.cyr"
echo "  3. Run: cat src/main.cyr | cc2 > build/$NAME"
echo "  4. Test: sh tests/test.sh"
