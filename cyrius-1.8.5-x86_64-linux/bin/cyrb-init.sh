#!/bin/sh
# cyrb init — scaffold a new Cyrius project
# Usage: cyrb-init.sh <project-name>
#
# Creates a complete Cyrius project with vendored stdlib,
# build/test scripts, and documentation templates.

set -e

if [ -z "$1" ]; then
    echo "Usage: cyrb-init.sh <project-name>"
    echo ""
    echo "Creates a new Cyrius project with:"
    echo "  lib/          vendored stdlib"
    echo "  src/main.cyr  entry point"
    echo "  src/test.cyr  test file"
    echo "  scripts/      build + test"
    echo "  docs, CI, version files"
    exit 1
fi

NAME="$1"
CYRIUS="$(cd "$(dirname "$0")/.." && pwd)"

if [ -d "$NAME" ]; then
    echo "ERROR: directory '$NAME' already exists"
    exit 1
fi

echo "Creating Cyrius project: $NAME"

# Create structure
mkdir -p "$NAME/src" "$NAME/lib/agnosys" "$NAME/scripts" "$NAME/build" "$NAME/docs/development" "$NAME/.github/workflows"

# === VERSION ===
echo "0.1.0" > "$NAME/VERSION"

# === .gitignore ===
cat > "$NAME/.gitignore" << 'GITIGNORE'
/build/
*.core
.claude/
.idea/
.vscode/
*.swp
*.swo
*~
.DS_Store
.env
.env.*
*.pem
*.key
GITIGNORE

# === LICENSE ===
cat > "$NAME/LICENSE" << 'LICENSE'
GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, version 3 of the License only.

See https://www.gnu.org/licenses/gpl-3.0.html for full text.
LICENSE

# === README.md ===
cat > "$NAME/README.md" << EOF
# $NAME

Written in [Cyrius](https://github.com/MacCracken/cyrius).

## Build

\`\`\`sh
sh scripts/build.sh
sh scripts/test.sh
\`\`\`

## License

GPL-3.0-only
EOF

# === CHANGELOG.md ===
cat > "$NAME/CHANGELOG.md" << 'CHANGELOG'
# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0]

### Added
- Initial project scaffold
CHANGELOG

# === cyrb.toml ===
cat > "$NAME/cyrb.toml" << EOF
name = "$NAME"
version = "0.1.0"
license = "GPL-3.0-only"
entry = "src/main.cyr"
output = "$NAME"

[deps]
stdlib = { path = "lib" }
EOF

# === src/main.cyr ===
cat > "$NAME/src/main.cyr" << EOF
# $NAME — main entry point

include "lib/string.cyr"
include "lib/fmt.cyr"
include "lib/alloc.cyr"

fn main() {
    alloc_init();
    println("hello from $NAME");
    return 0;
}
var r = main();
syscall(60, r);
EOF

# === src/test.cyr ===
cat > "$NAME/src/test.cyr" << EOF
# $NAME — tests

include "lib/string.cyr"
include "lib/fmt.cyr"
include "lib/alloc.cyr"
include "lib/assert.cyr"

fn main() {
    alloc_init();
    assert(1 == 1, "sanity");
    return assert_summary();
}
var exit_code = main();
syscall(60, exit_code);
EOF

# === scripts/build.sh ===
cat > "$NAME/scripts/build.sh" << 'BUILD'
#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CYRIUS_CC:-${ROOT}/../cyrius/build/cc2}"
if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius compiler not found. Set CYRIUS_CC." >&2
    exit 1
fi
mkdir -p "$ROOT/build"
cd "$ROOT"
cat src/main.cyr | "$CC" > build/$(basename "$ROOT")
chmod +x build/$(basename "$ROOT")
echo "built: build/$(basename "$ROOT") ($(wc -c < build/$(basename "$ROOT")) bytes)"
BUILD
chmod +x "$NAME/scripts/build.sh"

# === scripts/test.sh ===
cat > "$NAME/scripts/test.sh" << 'TEST'
#!/bin/sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CYRIUS_CC:-${ROOT}/../cyrius/build/cc2}"
if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius compiler not found. Set CYRIUS_CC." >&2
    exit 1
fi
cd "$ROOT"
cat src/test.cyr | "$CC" > /tmp/cyrius_test_$$ && chmod +x /tmp/cyrius_test_$$
/tmp/cyrius_test_$$
exit_code=$?
rm -f /tmp/cyrius_test_$$
exit $exit_code
TEST
chmod +x "$NAME/scripts/test.sh"

# === CI ===
cat > "$NAME/.github/workflows/ci.yml" << 'CI'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Clone Cyrius
        run: |
          git clone --depth 1 https://github.com/MacCracken/cyrius.git ../cyrius
          cd ../cyrius && sh bootstrap/bootstrap.sh
          cat src/main.cyr | ./build/stage1f > ./build/cc2 && chmod +x ./build/cc2
      - name: Build
        run: sh scripts/build.sh
      - name: Test
        run: sh scripts/test.sh
CI

# === Vendor stdlib ===
echo "Vendoring Cyrius stdlib..."
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
CYRIUS_VER=$(cat "$CYRIUS_HOME/current" 2>/dev/null)
CYRIUS_LIB=""
if [ -n "$CYRIUS_VER" ] && [ -d "$CYRIUS_HOME/versions/$CYRIUS_VER/lib" ]; then
    CYRIUS_LIB="$CYRIUS_HOME/versions/$CYRIUS_VER/lib"
elif [ -d "$CYRIUS/lib" ]; then
    CYRIUS_LIB="$CYRIUS/lib"
fi
if [ -n "$CYRIUS_LIB" ]; then
    for f in "$CYRIUS_LIB"/*.cyr; do
        [ -f "$f" ] && cp "$f" "$NAME/lib/"
    done
else
    echo "  warn: Cyrius stdlib not found, lib/ will be empty"
fi

# === Done ===
LIB_COUNT=$(find "$NAME/lib" -name '*.cyr' | wc -l)
echo ""
echo "Created $NAME/"
echo "  $LIB_COUNT stdlib modules vendored"
echo "  src/main.cyr — entry point"
echo "  src/test.cyr — test file"
echo ""
echo "Next steps:"
echo "  cd $NAME"
echo "  sh scripts/build.sh"
echo "  sh scripts/test.sh"
