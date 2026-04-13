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
WORKDIR="$HOME/.cyrius/staging"

echo "=== Cyrius CI Setup ==="
echo "  version: $VERSION"
echo "  target:  $DEST"

mkdir -p "$DEST" "$WORKDIR"

echo "  fetching $TARBALL..."
curl -sfL "$URL" -o "$WORKDIR/$TARBALL" || { echo "  error: download failed"; exit 1; }

tar xzf "$WORKDIR/$TARBALL" -C "$WORKDIR/"
rm -f "$WORKDIR/$TARBALL"

# Copy binaries — handle both flat and bin/ layouts
SRC="$WORKDIR/cyrius-${VERSION}-x86_64-linux"
for f in cc3 cc3_aarch64 cc3-native-aarch64 cyrius asm ark cyrfmt cyrlint cyrdoc cyrc; do
    [ -f "$SRC/$f" ] && cp -f "$SRC/$f" "$DEST/$f" && chmod +x "$DEST/$f"
    [ -f "$SRC/bin/$f" ] && cp -f "$SRC/bin/$f" "$DEST/$f" && chmod +x "$DEST/$f"
done
[ -d "$SRC/lib" ] && cp -rf "$SRC/lib" "$HOME/.cyrius/lib"
rm -rf "$SRC" "$WORKDIR"

# Verify
[ -x "$DEST/cc3" ] && echo "  cc3:  ok" || { echo "  error: cc3 not found"; exit 1; }
[ -x "$DEST/cyrius" ] && echo "  cyrius: ok" || echo "  warn: cyrius not found"
echo "  done"
