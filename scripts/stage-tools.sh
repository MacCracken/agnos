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
# 1.44.x userland coreutils delegation: agnsh 1.5.0 dropped its in-process file
# verbs and now delegates them to these two. kriya is the BusyBox-style coreutils
# dispatcher; owl is AGNOS's cat.
stage_one kriya        src/main.cyr kriya    || rc=1
stage_one owl          src/main.cyr owl      || rc=1

# 1.45.x network-tools family: the first net consumers of the ring-3 socket /
# UDP / ICMP syscalls (#45-#57, cyrius >= 6.2.5 net peer). dig = DNS resolver
# over udp_bind/send/recv/unbind (#51-54); yo = ICMP ping over icmp_echo (#55);
# whirl = curl+wget (HTTP over sock_connect/send/recv/close #47-50 + DNS via
# taar's udp path; HTTPS via tls_native composed over the sock transport with
# the time_unix#46 cert clock). All three share the taar substrate library.
stage_one dig          src/main.cyr dig      || rc=1
stage_one yo           src/main.cyr yo       || rc=1
stage_one whirl        src/main.cyr whirl    || rc=1

# kriya dispatches on basename(argv[0]), so each delegated verb needs a
# /bin/<verb> NAME resolving to the kriya binary. Create them as RELATIVE
# symlinks (-> kriya) in the rootfs: install-media.sh's `cp -a` preserves them
# into the ext2 image, and the agnos ext2 open path follows the symlink inode to
# the dispatcher (so exec'ing /bin/cp loads kriya with argv[0]="/bin/cp"). These
# 11 are exactly the verbs agnsh 1.5.0 removed; `cat` is intentionally absent
# (owl is AGNOS's cat — agnsh nudges `cat` -> owl). The rest of kriya's surface
# (head/tail/sort/stat/ln/...) stays reachable via `kriya <applet>`; add more
# names here if they earn a bareword. NB `ln` would ENOSYS until symlink#43.
if [ -f "$DEST_DIR/kriya" ]; then
    for u in cp mv rm mkdir rmdir touch echo wc find grep ls; do
        ln -sf kriya "$DEST_DIR/$u"
    done
    echo "linked: $DEST_DIR/{cp,mv,rm,mkdir,rmdir,touch,echo,wc,find,grep,ls} -> kriya"
fi
exit $rc
