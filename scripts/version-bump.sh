#!/bin/sh
# Version bump script — single source of truth for all version references
# Usage: ./scripts/version-bump.sh 1.22.0
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$1" ]; then
    echo "Usage: $0 <version>"
    echo "Current: $(cat "$ROOT/VERSION")"
    exit 1
fi

NEW="$1"
OLD=$(cat "$ROOT/VERSION" | tr -d '[:space:]')

# Validate semver
echo "$NEW" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$' || {
    echo "error: '$NEW' is not valid semver" >&2
    exit 1
}

if [ "$NEW" = "$OLD" ]; then
    echo "Already at $OLD"
    exit 0
fi

echo "Bumping $OLD -> $NEW"
updated=""

# 1. VERSION file (source of truth — cyrius.cyml reads this via ${file:VERSION})
echo "$NEW" > "$ROOT/VERSION"
updated="$updated  VERSION\n"

# 2. CLAUDE.md
if [ -f "$ROOT/CLAUDE.md" ]; then
    sed -i "s/- \*\*Version\*\*: $OLD/- **Version**: $NEW/" "$ROOT/CLAUDE.md"
    updated="$updated  CLAUDE.md\n"
fi

# 3. kernel/agnos.cyr (comment)
if [ -f "$ROOT/kernel/agnos.cyr" ]; then
    sed -i "s/AGNOS kernel v$OLD/AGNOS kernel v$NEW/" "$ROOT/kernel/agnos.cyr"
    updated="$updated  kernel/agnos.cyr\n"
fi

# 4. kernel/core/main.cyr — serial_println with auto-computed length
#    "AGNOS kernel vX.Y.Z" = 15 + len(version)
if [ -f "$ROOT/kernel/core/main.cyr" ]; then
    KSTR="AGNOS kernel v$NEW"
    KLEN=${#KSTR}
    sed -i -E "s|\"AGNOS kernel v[0-9]+\.[0-9]+\.[0-9]+[^\"]*\", [0-9]+\)|\"$KSTR\", $KLEN)|" "$ROOT/kernel/core/main.cyr"
    updated="$updated  kernel/core/main.cyr ($KSTR, $KLEN)\n"
fi

# 5. kernel/arch/aarch64/main.cyr — serial_println with auto-computed length
#    "AGNOS kernel vX.Y.Z [aarch64]" = 26 + len(version)
if [ -f "$ROOT/kernel/arch/aarch64/main.cyr" ]; then
    ASTR="AGNOS kernel v$NEW [aarch64]"
    ALEN=${#ASTR}
    sed -i -E "s|\"AGNOS kernel v[0-9]+\.[0-9]+\.[0-9]+[^\"]* \[aarch64\]\", [0-9]+\)|\"$ASTR\", $ALEN)|" "$ROOT/kernel/arch/aarch64/main.cyr"
    updated="$updated  kernel/arch/aarch64/main.cyr ($ASTR, $ALEN)\n"
fi

# 6. kernel/user/shell.cyr — serial_println with auto-computed length
#    "AGNOS shell vX.Y.Z (type 'help')" = 27 + len(version)
if [ -f "$ROOT/kernel/user/shell.cyr" ]; then
    SSTR="AGNOS shell v$NEW (type 'help')"
    SLEN=${#SSTR}
    sed -i -E "s|\"AGNOS shell v[0-9]+\.[0-9]+\.[0-9]+[^\"]* \(type 'help'\)\", [0-9]+\)|\"$SSTR\", $SLEN)|" "$ROOT/kernel/user/shell.cyr"
    updated="$updated  kernel/user/shell.cyr ($SSTR, $SLEN)\n"
fi

# 7. CHANGELOG.md — add new version section after [Unreleased]
if [ -f "$ROOT/CHANGELOG.md" ]; then
    if ! grep -q "## \[$NEW\]" "$ROOT/CHANGELOG.md"; then
        sed -i "/## \[Unreleased\]/a\\
\\
## [$NEW] — $(date +%Y-%m-%d)" "$ROOT/CHANGELOG.md"
    fi
    updated="$updated  CHANGELOG.md\n"
fi

# 8. docs/development/roadmap.md — update Current header version AND
#    re-sync the trailing "Built with cyrius X.Y.Z" string from
#    cyrius.cyml so the roadmap doesn't drift after a pin bump.
#    Pre-v1.27.1, version-bump.sh only touched the version number and
#    left the trailing toolchain string stale.
if [ -f "$ROOT/docs/development/roadmap.md" ]; then
    sed -i -E "s|> \*\*Current\*\*: v[0-9]+\.[0-9]+\.[0-9]+|> **Current**: v$NEW|" "$ROOT/docs/development/roadmap.md"
    CYRIUS_PIN=$(grep -oE '^cyrius = "[^"]+"' "$ROOT/cyrius.cyml" | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -n "$CYRIUS_PIN" ]; then
        sed -i -E "s|Built with cyrius [0-9]+\.[0-9]+\.[0-9]+|Built with cyrius $CYRIUS_PIN|" "$ROOT/docs/development/roadmap.md"
    fi
    updated="$updated  docs/development/roadmap.md\n"
fi

echo ""
echo "Updated:"
printf "$updated"

# Verify — check for any remaining OLD version references (excluding CHANGELOG history)
echo ""
STALE=$(grep -rn "$OLD" "$ROOT/VERSION" "$ROOT/CLAUDE.md" "$ROOT/kernel/agnos.cyr" "$ROOT/kernel/core/main.cyr" "$ROOT/kernel/arch/aarch64/main.cyr" "$ROOT/kernel/user/shell.cyr" 2>/dev/null || true)
if [ -n "$STALE" ]; then
    echo "WARNING: stale $OLD references found:"
    echo "$STALE"
else
    echo "Verified: no stale $OLD references in source files"
fi

echo ""
echo "Still manual:"
echo "  - CHANGELOG.md entries (add Added/Changed/Fixed sections)"
echo "  - README.md metrics (binary size, line count, subsystem count)"
