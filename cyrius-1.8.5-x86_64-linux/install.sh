#!/bin/sh
# Cyrius installer
# Usage: curl -sSf https://install.cyrius.dev | sh
#    or: curl -sSf https://raw.githubusercontent.com/MacCracken/cyrius/main/scripts/install.sh | sh
#
# Installs the Cyrius toolchain to ~/.cyrius/
# Structure:
#   ~/.cyrius/
#     bin/              symlinks to active version (on PATH)
#     versions/0.9.0/   version-specific binaries
#     current           active version file
#
# Environment:
#   CYRIUS_VERSION   install specific version (default: latest)
#   CYRIUS_HOME      install directory (default: ~/.cyrius)

set -e

CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"
REPO="MacCracken/cyrius"
VERSION="${CYRIUS_VERSION:-}"
ARCH=$(uname -m)

# Colors (if terminal)
if [ -t 1 ]; then
    BOLD="\033[1m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    RED="\033[31m"
    DIM="\033[2m"
    RESET="\033[0m"
else
    BOLD="" GREEN="" YELLOW="" RED="" DIM="" RESET=""
fi

info() { printf "  ${GREEN}>${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
err()  { printf "  ${RED}x${RESET} %s\n" "$1" >&2; exit 1; }

# ── Detect platform ──

case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) err "unsupported architecture: $ARCH" ;;
esac

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
    linux) ;;
    *) err "unsupported OS: $OS (Cyrius targets Linux only)" ;;
esac

printf "\n${BOLD}Cyrius Installer${RESET}\n\n"

# ── Resolve version ──

if [ -z "$VERSION" ]; then
    VERSION=$(curl -sSf "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || echo "")
    if [ -z "$VERSION" ]; then
        VERSION="0.9.1"
        warn "could not fetch latest version, defaulting to ${VERSION}"
    fi
fi

info "version:  ${VERSION}"
info "arch:     ${ARCH}"
info "home:     ${CYRIUS_HOME}"
echo ""

# ── Create directory structure ──

mkdir -p "$CYRIUS_HOME/bin"
mkdir -p "$CYRIUS_HOME/lib"
mkdir -p "$CYRIUS_HOME/versions/$VERSION/bin"

# ── Download tarball or bootstrap from source ──

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}"
TARBALL="cyrius-${VERSION}-${ARCH}-linux.tar.gz"
TMPDIR=$(mktemp -d)
installed=0

info "downloading Cyrius ${VERSION}..."
if curl -sSfL "${DOWNLOAD_URL}/${TARBALL}" -o "$TMPDIR/$TARBALL" 2>/dev/null; then
    # Verify checksum if available
    if curl -sSfL "${DOWNLOAD_URL}/${TARBALL}.sha256" -o "$TMPDIR/checksum" 2>/dev/null; then
        cd "$TMPDIR"
        if sha256sum -c checksum > /dev/null 2>&1; then
            info "checksum verified"
        else
            warn "checksum mismatch — continuing anyway"
        fi
        cd - > /dev/null
    fi

    # Untar into version directory
    tar xzf "$TMPDIR/$TARBALL" -C "$TMPDIR"
    EXTRACTED="$TMPDIR/cyrius-${VERSION}-${ARCH}-linux"

    if [ -d "$EXTRACTED/bin" ]; then
        cp -r "$EXTRACTED/bin"/* "$CYRIUS_HOME/versions/$VERSION/bin/"
        chmod +x "$CYRIUS_HOME/versions/$VERSION/bin"/*
        info "binaries installed"
    fi

    if [ -d "$EXTRACTED/lib" ]; then
        cp -r "$EXTRACTED/lib" "$CYRIUS_HOME/versions/$VERSION/"
        info "standard library installed"
    fi

    installed=1
fi

if [ "$installed" -eq 0 ]; then
    # No tarball — bootstrap from source
    warn "no prebuilt release found, bootstrapping from source..."
    cd "$TMPDIR"
    git clone --depth 1 --branch "$VERSION" "https://github.com/${REPO}.git" cyrius 2>/dev/null || \
        git clone --depth 1 "https://github.com/${REPO}.git" cyrius
    cd cyrius

    sh bootstrap/bootstrap.sh
    chmod +x build/cc2

    # Verify self-hosting
    cat src/main.cyr | ./build/cc2 > /tmp/cc2_verify
    chmod +x /tmp/cc2_verify
    cat src/main.cyr | /tmp/cc2_verify > /tmp/cc2_verify2
    if cmp -s /tmp/cc2_verify /tmp/cc2_verify2; then
        info "self-hosting verified"
    else
        warn "self-hosting check failed, using committed cc2"
    fi

    # Build tools
    for tool in cyrfmt cyrlint cyrdoc cyrc ark; do
        if [ -f "programs/${tool}.cyr" ]; then
            cat "programs/${tool}.cyr" | ./build/cc2 > "./build/${tool}" 2>/dev/null && \
                chmod +x "./build/${tool}" || true
        fi
    done

    # Cross-compiler
    if [ -f src/main_aarch64.cyr ]; then
        cat src/main_aarch64.cyr | ./build/cc2 > ./build/cc2_aarch64 2>/dev/null && \
            chmod +x ./build/cc2_aarch64 || true
    fi

    # Copy binaries
    for bin in cc2 cc2_aarch64 cyrfmt cyrlint cyrdoc cyrc ark; do
        if [ -x "./build/$bin" ]; then
            cp "./build/$bin" "$CYRIUS_HOME/versions/$VERSION/bin/"
        fi
    done
    cp bootstrap/asm "$CYRIUS_HOME/versions/$VERSION/bin/"
    cp scripts/cyrb "$CYRIUS_HOME/versions/$VERSION/bin/"
    chmod +x "$CYRIUS_HOME/versions/$VERSION/bin/cyrb"
    if [ -f scripts/cyrb-init.sh ]; then
        cp scripts/cyrb-init.sh "$CYRIUS_HOME/versions/$VERSION/bin/"
        chmod +x "$CYRIUS_HOME/versions/$VERSION/bin/cyrb-init.sh"
    fi

    # Copy stdlib
    if [ -d lib ]; then
        cp -r lib "$CYRIUS_HOME/versions/$VERSION/"
    fi

    cd /
    rm -f /tmp/cc2_verify /tmp/cc2_verify2
    info "bootstrapped from source"
fi

rm -rf "$TMPDIR"

# ── Set active version ──

echo "$VERSION" > "$CYRIUS_HOME/current"

# ── Create symlinks ──

info "linking binaries..."
ALL_BINS="cc2 cc2_aarch64 cyrb cyrfmt cyrlint cyrdoc cyrc ark asm cyrb-init.sh"
for bin in $ALL_BINS; do
    src="$CYRIUS_HOME/versions/$VERSION/bin/$bin"
    dst="$CYRIUS_HOME/bin/$bin"
    if [ -x "$src" ] || [ -f "$src" ]; then
        ln -sf "$src" "$dst"
    fi
done

# Convenience alias: cyrb-init (without .sh)
if [ -x "$CYRIUS_HOME/bin/cyrb-init.sh" ]; then
    ln -sf "$CYRIUS_HOME/bin/cyrb-init.sh" "$CYRIUS_HOME/bin/cyrb-init"
fi

# ── Install version manager ──

cat > "$CYRIUS_HOME/bin/cyrius" << 'MANAGER'
#!/bin/sh
# cyrius — Cyrius version manager
# Like rustup, pyenv, rbenv — manages installed Cyrius versions.
CYRIUS_HOME="${CYRIUS_HOME:-$HOME/.cyrius}"

current() { cat "$CYRIUS_HOME/current" 2>/dev/null || echo "none"; }

link_version() {
    local ver="$1"
    local bins="cc2 cc2_aarch64 cyrb cyrfmt cyrlint cyrdoc cyrc ark asm cyrb-init.sh"
    for bin in $bins; do
        local src="$CYRIUS_HOME/versions/$ver/bin/$bin"
        local dst="$CYRIUS_HOME/bin/$bin"
        if [ -x "$src" ] || [ -f "$src" ]; then
            ln -sf "$src" "$dst"
        fi
    done
}

case "${1:-help}" in
    version|--version|-v)
        echo "cyrius $(current)"
        ;;

    list|ls)
        echo "Installed versions:"
        local cur=$(current)
        for d in "$CYRIUS_HOME/versions"/*/; do
            [ -d "$d" ] || continue
            local v=$(basename "$d")
            if [ "$v" = "$cur" ]; then
                echo "  * $v (active)"
            else
                echo "    $v"
            fi
        done
        ;;

    use)
        [ -z "$2" ] && echo "Usage: cyrius use <version>" && exit 1
        [ ! -d "$CYRIUS_HOME/versions/$2" ] && echo "Version $2 not installed." && exit 1
        echo "$2" > "$CYRIUS_HOME/current"
        link_version "$2"
        echo "Now using Cyrius $2"
        ;;

    install)
        [ -z "$2" ] && echo "Usage: cyrius install <version>" && exit 1
        echo "Installing Cyrius $2..."
        CYRIUS_VERSION="$2" curl -sSf "https://raw.githubusercontent.com/MacCracken/cyrius/main/scripts/install.sh" | sh
        ;;

    uninstall)
        [ -z "$2" ] && echo "Usage: cyrius uninstall <version>" && exit 1
        local cur=$(current)
        if [ "$2" = "$cur" ]; then
            echo "Cannot uninstall active version. Switch first: cyrius use <other>"
            exit 1
        fi
        if [ -d "$CYRIUS_HOME/versions/$2" ]; then
            rm -rf "$CYRIUS_HOME/versions/$2"
            echo "Uninstalled Cyrius $2"
        else
            echo "Version $2 not installed."
        fi
        ;;

    which)
        echo "$CYRIUS_HOME/versions/$(current)/bin/cc2"
        ;;

    home)
        echo "$CYRIUS_HOME"
        ;;

    update)
        echo "Checking for updates..."
        LATEST=$(curl -sSf "https://api.github.com/repos/MacCracken/cyrius/releases/latest" 2>/dev/null | \
            grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || echo "")
        CUR=$(current)
        if [ -z "$LATEST" ]; then
            echo "Could not check for updates."
        elif [ "$LATEST" = "$CUR" ]; then
            echo "Already up to date: $CUR"
        else
            echo "Update available: $CUR -> $LATEST"
            echo "Run: cyrius install $LATEST && cyrius use $LATEST"
        fi
        ;;

    help|--help|-h)
        echo "cyrius - Cyrius version manager"
        echo ""
        echo "USAGE:"
        echo "    cyrius <command> [args]"
        echo ""
        echo "COMMANDS:"
        echo "    version             Show active version"
        echo "    list                List installed versions"
        echo "    use <version>       Switch to a version"
        echo "    install <version>   Download and install a version"
        echo "    uninstall <version> Remove a version"
        echo "    update              Check for new versions"
        echo "    which               Show path to active compiler"
        echo "    home                Show install directory"
        echo "    help                Show this help"
        echo ""
        echo "EXAMPLES:"
        echo "    cyrius install 0.9.0"
        echo "    cyrius use 0.9.0"
        echo "    cyrius list"
        ;;

    *)
        echo "Unknown command: $1"
        echo "Run 'cyrius help' for usage."
        exit 1
        ;;
esac
MANAGER
chmod +x "$CYRIUS_HOME/bin/cyrius"

# ── Setup PATH ──

add_to_path() {
    local profile="$1"
    if [ -f "$profile" ]; then
        if ! grep -q "\.cyrius/bin" "$profile" 2>/dev/null; then
            printf '\n# Cyrius\nexport PATH="$HOME/.cyrius/bin:$PATH"\n' >> "$profile"
            return 0
        fi
    fi
    return 1
}

path_added=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$rc" ]; then
        add_to_path "$rc" && path_added=1 && info "PATH added to $(basename $rc)"
    fi
done
if [ "$path_added" -eq 0 ]; then
    add_to_path "$HOME/.profile" && info "PATH added to .profile" || true
fi

# ── Summary ──

printf "\n${BOLD}Cyrius ${VERSION} installed successfully!${RESET}\n\n"

# Show what was installed
echo "  Toolchain:"
for bin in cc2 cyrb cyrfmt cyrlint cyrdoc cyrc ark; do
    if [ -x "$CYRIUS_HOME/bin/$bin" ]; then
        printf "    ${GREEN}+${RESET} %s\n" "$bin"
    fi
done
if [ -x "$CYRIUS_HOME/bin/cc2_aarch64" ]; then
    printf "    ${GREEN}+${RESET} %s\n" "cc2_aarch64 (cross-compiler)"
fi
echo ""
echo "  To get started:"
echo "    ${DIM}# restart your shell, or:${RESET}"
echo "    export PATH=\"\$HOME/.cyrius/bin:\$PATH\""
echo ""
echo "    ${DIM}# create a new project:${RESET}"
echo "    cyrb init myproject"
echo "    cd myproject"
echo "    cyrb build src/main.cyr -o build/main"
echo ""
echo "    ${DIM}# manage versions:${RESET}"
echo "    cyrius list"
echo "    cyrius update"
echo ""
