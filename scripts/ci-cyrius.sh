#!/bin/sh
# ci.sh — install Cyrius from latest release for CI pipelines
# Usage: sh scripts/ci.sh [version]
# Pulls the release tarball, extracts to ~/.cyrius, adds to PATH.

set -e

VERSION="${1:-$(curl -sf https://api.github.com/repos/MacCracken/cyrius/releases/latest | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "//;s/".*//')}"

if [ -z "$VERSION" ]; then
    echo "error: could not determine version"
    exit 1
fi

CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
TARBALL="cyrius-${VERSION}-x86_64-linux.tar.gz"
URL="https://github.com/MacCracken/cyrius/releases/download/${VERSION}/${TARBALL}"

echo "=== Cyrius CI Setup ==="
echo "  version: $VERSION"
echo "  target:  $CYRIUS_HOME"

mkdir -p "$CYRIUS_HOME/bin"

echo "  fetching $TARBALL..."
curl -sfL "$URL" -o "/tmp/$TARBALL" || {
    echo "error: failed to download $URL"
    exit 1
}

tar xzf "/tmp/$TARBALL" -C "$CYRIUS_HOME"
rm -f "/tmp/$TARBALL"

# Symlink binaries
for bin in "$CYRIUS_HOME"/versions/"$VERSION"/bin/*; do
    [ -f "$bin" ] && ln -sf "$bin" "$CYRIUS_HOME/bin/$(basename "$bin")"
done
echo "$VERSION" > "$CYRIUS_HOME/current"

# Verify
if [ -x "$CYRIUS_HOME/bin/cc2" ]; then
    echo "  cc2:  ok"
else
    echo "  error: cc2 not found"
    exit 1
fi

if [ -x "$CYRIUS_HOME/bin/cyrb" ]; then
    echo "  cyrb: $("$CYRIUS_HOME/bin/cyrb" version 2>/dev/null || echo 'ok')"
else
    echo "  error: cyrb not found"
    exit 1
fi

echo ""
echo "Add to PATH:"
echo "  export PATH=\"$CYRIUS_HOME/bin:\$PATH\""
