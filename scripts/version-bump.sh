#!/bin/sh
# Bump AGNOS version across all files
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$1" ]; then
    echo "Usage: $0 <new-version>"
    echo "Current: $(cat "$ROOT/VERSION")"
    exit 1
fi

NEW="$1"
OLD=$(cat "$ROOT/VERSION" | tr -d '[:space:]')

if [ "$NEW" = "$OLD" ]; then
    echo "Already at version $OLD"
    exit 0
fi

echo "$NEW" > "$ROOT/VERSION"
sed -i "s/AGNOS kernel v$OLD/AGNOS kernel v$NEW/g" "$ROOT/kernel/agnos.cyr"
sed -i "s/AGNOS shell v$OLD/AGNOS shell v$NEW/g" "$ROOT/kernel/agnos.cyr"

echo "Updated $OLD -> $NEW"
echo ""
echo "Next steps:"
echo "  1. Update CHANGELOG.md with new section"
echo "  2. git add -A && git commit -m 'v$NEW'"
echo "  3. git tag $NEW && git push --tags"
