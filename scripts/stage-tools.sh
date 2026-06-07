#!/bin/sh
# stage-tools.sh — build + stage the AGNOS-tic userland tools onto the agnos-fs
# rootfs as /bin/<name>, alongside agnsh (stage-agnsh.sh).
#
# These are the first sovereign userland tools that build + run NATIVELY on agnos
# (CYRIUS_TARGET_AGNOS). Today the in-kernel recovery shell's `run /bin/<name>`
# exec-from-disk path (1.40.x) runs them; agnsh execs them once 1.43.x execwait
# lands. Each staged binary MUST be a static x86_64 ELF64 — agnos exec-from-disk
# (elf_load_from_file) loads static ELF64 only.
#
# Usage:
#   scripts/stage-tools.sh            stage the existing <repo>/build/<name>_agnos
#   scripts/stage-tools.sh --build    rebuild each first (cyrius build --agnos)
#
# Tools live in sibling repos at $ROOT/../<repo> (override with SIBLINGS_ROOT).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIBLINGS="${SIBLINGS_ROOT:-$ROOT/..}"
DEST_DIR="$ROOT/build/rootfs/bin"
mkdir -p "$DEST_DIR"

BUILD=0
[ "${1:-}" = "--build" ] && BUILD=1

# Tool table: <repo> <src-entry> <name>. `name` matches the tool's cyrius.cyml
# [build] output; the agnos binary is staged at <repo>/build/<name>_agnos. Add a
# row here as each tool gains an agnos build (mihi/iam/chakshu ride 1.43.x).
stage_one() {
    repo="$1"; src="$2"; name="$3"
    rdir="$SIBLINGS/$repo"
    [ -d "$rdir" ] || { echo "ERROR: $repo not found at $rdir (set SIBLINGS_ROOT)"; return 1; }
    bin="$rdir/build/${name}_agnos"
    if [ "$BUILD" = "1" ]; then
        echo "Building $name (agnos target) in $repo ..."
        ( cd "$rdir" && cyrius build --agnos "$src" "build/${name}_agnos" ) \
            || { echo "ERROR: $name (agnos) build failed"; return 1; }
    fi
    [ -f "$bin" ] || { echo "ERROR: $bin not present — run with --build (or 'cyrius build --agnos $src build/${name}_agnos' in $repo)"; return 1; }
    DESC="$(file -b "$bin" 2>/dev/null)"
    case "$DESC" in
        *"ELF 64-bit"*"x86-64"*"statically linked"*) : ;;
        *) echo "ERROR: $bin is not a static x86-64 ELF64 ($DESC)"; return 1 ;;
    esac
    cp "$bin" "$DEST_DIR/$name"
    chmod +x "$DEST_DIR/$name"
    echo "staged: $DEST_DIR/$name ($(stat -c%s "$DEST_DIR/$name") bytes) <- $repo"
}

rc=0
stage_one bannermanor src/main.cyr bnrmr    || rc=1
stage_one commandress  src/main.cyr cmdrs    || rc=1
stage_one klug         src/main.cyr klug     || rc=1
stage_one anuenue      src/main.cyr anuenue  || rc=1
exit $rc
