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

# 1. VERSION file (source of truth)
echo "$NEW" > "$ROOT/VERSION"
updated="$updated  VERSION\n"

# 2. cyrius.toml
if [ -f "$ROOT/cyrius.toml" ]; then
    sed -i "s/version = \"$OLD\"/version = \"$NEW\"/" "$ROOT/cyrius.toml"
    updated="$updated  cyrius.toml\n"
fi

# 3. CLAUDE.md
if [ -f "$ROOT/CLAUDE.md" ]; then
    sed -i "s/- \*\*Version\*\*: $OLD/- **Version**: $NEW/" "$ROOT/CLAUDE.md"
    updated="$updated  CLAUDE.md\n"
fi

# 4. kernel/agnos.cyr (comment)
if [ -f "$ROOT/kernel/agnos.cyr" ]; then
    sed -i "s/AGNOS kernel v$OLD/AGNOS kernel v$NEW/" "$ROOT/kernel/agnos.cyr"
    updated="$updated  kernel/agnos.cyr\n"
fi

# 5. kernel/core/main.cyr — serial_println with auto-computed length
#    "AGNOS kernel vX.Y.Z" = 15 + len(version)
if [ -f "$ROOT/kernel/core/main.cyr" ]; then
    KSTR="AGNOS kernel v$NEW"
    KLEN=${#KSTR}
    sed -i -E "s|\"AGNOS kernel v[0-9]+\.[0-9]+\.[0-9]+[^\"]*\", [0-9]+\)|\"$KSTR\", $KLEN)|" "$ROOT/kernel/core/main.cyr"
    updated="$updated  kernel/core/main.cyr ($KSTR, $KLEN)\n"
fi

# 6. kernel/arch/aarch64/main.cyr — serial_println with auto-computed length
#    "AGNOS kernel vX.Y.Z [aarch64]" = 26 + len(version)
if [ -f "$ROOT/kernel/arch/aarch64/main.cyr" ]; then
    ASTR="AGNOS kernel v$NEW [aarch64]"
    ALEN=${#ASTR}
    sed -i -E "s|\"AGNOS kernel v[0-9]+\.[0-9]+\.[0-9]+[^\"]* \[aarch64\]\", [0-9]+\)|\"$ASTR\", $ALEN)|" "$ROOT/kernel/arch/aarch64/main.cyr"
    updated="$updated  kernel/arch/aarch64/main.cyr ($ASTR, $ALEN)\n"
fi

# 7. kernel/user/shell.cyr — serial_println with auto-computed length
#    "AGNOS shell vX.Y.Z (type 'help')" = 27 + len(version)
if [ -f "$ROOT/kernel/user/shell.cyr" ]; then
    SSTR="AGNOS shell v$NEW (type 'help')"
    SLEN=${#SSTR}
    sed -i -E "s|\"AGNOS shell v[0-9]+\.[0-9]+\.[0-9]+[^\"]* \(type 'help'\)\", [0-9]+\)|\"$SSTR\", $SLEN)|" "$ROOT/kernel/user/shell.cyr"
    updated="$updated  kernel/user/shell.cyr ($SSTR, $SLEN)\n"
fi

# 8. CHANGELOG.md — add new version section after [Unreleased]
if [ -f "$ROOT/CHANGELOG.md" ]; then
    if ! grep -q "## \[$NEW\]" "$ROOT/CHANGELOG.md"; then
        sed -i "/## \[Unreleased\]/a\\
\\
## [$NEW] — $(date +%Y-%m-%d)" "$ROOT/CHANGELOG.md"
    fi
    updated="$updated  CHANGELOG.md\n"
fi

# 9. docs/development/roadmap.md — update Current header
if [ -f "$ROOT/docs/development/roadmap.md" ]; then
    sed -i -E "s|> \*\*Current\*\*: v[0-9]+\.[0-9]+\.[0-9]+|> **Current**: v$NEW|" "$ROOT/docs/development/roadmap.md"
    updated="$updated  docs/development/roadmap.md\n"
fi

echo ""
echo "Updated:"
printf "$updated"

# Verify — check for any remaining OLD version references (excluding CHANGELOG history)
echo ""
STALE=$(grep -rn "$OLD" "$ROOT/VERSION" "$ROOT/cyrius.toml" "$ROOT/CLAUDE.md" "$ROOT/kernel/agnos.cyr" "$ROOT/kernel/core/main.cyr" "$ROOT/kernel/arch/aarch64/main.cyr" "$ROOT/kernel/user/shell.cyr" 2>/dev/null || true)
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
