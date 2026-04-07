#!/bin/sh
# Install Cyrius toolchain for CI
# Usage: sh scripts/ci-cyrius.sh [version]
set -e

VERSION="${1:-latest}"
if [ "$VERSION" = "latest" ]; then
    VERSION=$(curl -sf https://api.github.com/repos/MacCracken/cyrius/releases/latest | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "//;s/".*//')
fi

TARBALL="cyrius-${VERSION}-x86_64-linux.tar.gz"
URL="https://github.com/MacCracken/cyrius/releases/download/${VERSION}/${TARBALL}"
DEST="$HOME/.cyrius/bin"

echo "=== Cyrius CI Setup ==="
echo "  version: $VERSION"
echo "  target:  $DEST"

mkdir -p "$DEST"

echo "  fetching $TARBALL..."
curl -sfL "$URL" -o "/tmp/$TARBALL" || { echo "  error: download failed"; exit 1; }

tar xzf "/tmp/$TARBALL" -C /tmp/
rm -f "/tmp/$TARBALL"

# Copy binaries — handle both flat and bin/ layouts
SRC="/tmp/cyrius-${VERSION}-x86_64-linux"
for f in cc2 cc2_aarch64 cc2-native-aarch64 cyrb asm ark cyrfmt cyrlint cyrdoc cyrc; do
    [ -f "$SRC/$f" ] && cp -f "$SRC/$f" "$DEST/$f" && chmod +x "$DEST/$f"
    [ -f "$SRC/bin/$f" ] && cp -f "$SRC/bin/$f" "$DEST/$f" && chmod +x "$DEST/$f"
done
[ -d "$SRC/lib" ] && cp -rf "$SRC/lib" "$HOME/.cyrius/lib"
rm -rf "$SRC"

# Verify
[ -x "$DEST/cc2" ] && echo "  cc2:  ok" || { echo "  error: cc2 not found"; exit 1; }
[ -x "$DEST/cyrb" ] && echo "  cyrb: ok" || echo "  warn: cyrb not in release"
echo "  done"
