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

# 2. docs/development/state.md — live state ledger; bump the Kernel row
#    of the Version table + the Last refresh + Released header lines.
#    v1.27.1 split: CLAUDE.md is durable-only (no version line); state.md
#    is the volatile snapshot bumped per release.
#    Uses `#` as the sed delimiter — the pattern contains literal `|`
#    characters that would otherwise collide with the `|` delimiter
#    AND get parsed as ERE alternation operators after delimiter
#    unescaping (causing every line to match the empty-alternative).
if [ -f "$ROOT/docs/development/state.md" ]; then
    TODAY=$(date +%Y-%m-%d)
    sed -i -E "s#^(\\| \\*\\*Kernel\\*\\* \\| )\\*\\*[0-9]+\\.[0-9]+\\.[0-9]+\\*\\*( \\|.*)#\\1**$NEW**\\2#" "$ROOT/docs/development/state.md"
    sed -i -E "s#^(> \\*\\*Last refresh\\*\\*: )[0-9]{4}-[0-9]{2}-[0-9]{2}#\\1$TODAY#" "$ROOT/docs/development/state.md"
    sed -i -E "s#^(\\| \\*\\*Released\\*\\* \\| )[0-9]{4}-[0-9]{2}-[0-9]{2}( \\|.*)#\\1$TODAY\\2#" "$ROOT/docs/development/state.md"
    updated="$updated  docs/development/state.md\n"
fi

# 3. kernel/agnos.cyr (comment)
if [ -f "$ROOT/kernel/agnos.cyr" ]; then
    sed -i "s/AGNOS kernel v$OLD/AGNOS kernel v$NEW/" "$ROOT/kernel/agnos.cyr"
    updated="$updated  kernel/agnos.cyr\n"
fi

# 4. kernel/version.cyr — AUTO-GENERATED single-source-of-truth for all
#    runtime banner strings. v1.30.2+: replaces the per-site sed regexes
#    that previously bumped main.cyr / shell.cyr / aarch64/main.cyr
#    independently and re-computed each byte length. Mirrors cyrius's
#    src/version_str.cyr pattern. New banner site → add a paired var
#    here (and reference it from the consuming .cyr); script needs no
#    changes for new banners.
if [ -f "$ROOT/kernel/version.cyr" ] || [ -f "$ROOT/kernel/agnos.cyr" ]; then
    KSTR="AGNOS kernel v$NEW"
    KLEN=${#KSTR}
    SSTR="AGNOS shell v$NEW (type 'help')"
    SLEN=${#SSTR}
    ASTR="AGNOS kernel v$NEW [aarch64]"
    ALEN=${#ASTR}
    cat > "$ROOT/kernel/version.cyr" <<EOF
# kernel/version.cyr — AUTO-GENERATED from \`VERSION\` by
# \`scripts/version-bump.sh\`. Do NOT edit by hand; the next bump
# will overwrite. To regenerate without bumping, run:
#
#   sh scripts/version-bump.sh "\$(cat VERSION)"
#
# Why this file exists: pre-v1.30.2, each boot banner had its own
# hardcoded \`"AGNOS … vX.Y.Z …"\` literal + a hardcoded byte length
# in three .cyr files (kernel/core/main.cyr, kernel/user/shell.cyr,
# kernel/arch/aarch64/main.cyr). \`version-bump.sh\` had a sed regex
# per site that re-computed the byte length each bump; any new
# banner would silently miss the bump until CI caught the mismatch.
#
# Design note (v1.30.2 second take): banners are wrapped in **functions**,
# not stored in \`var BANNER = "…"\` globals. Cyrius kmode==1 emit order
# is PARSE_PROG before EMIT_GVAR_INITS — the kernel program body runs
# BEFORE gvar initializers in execution order, so a \`kprintln(BANNER,
# LEN)\` from main.cyr's top-level body would read uninitialized memory
# (empty banner; CI's \`grep -aq "AGNOS kernel v"\` would fail). Function
# bodies bake the literal's rodata pointer into the compiled \`mov\`
# instruction at compile time, so they work regardless of init order.
# Cyrius's own \`src/version_str.cyr\` uses \`var\` globals successfully
# because cyrius is a userland program — standard ELF startup runs
# initializers before main. AGNOS kernel inverts that order.

#ifdef ARCH_X86_64
fn print_agnos_kernel_banner() {
    kprintln("$KSTR", $KLEN);
}
#endif

#ifdef ARCH_AARCH64
fn print_agnos_kernel_banner() {
    serial_println("$ASTR", $ALEN);
}
#endif

fn print_agnos_shell_banner() {
    kprintln("$SSTR", $SLEN);
}

# Program-body-safe version accessor. Returns a pointer to the NUL-terminated
# version literal; the rodata pointer is baked into the function at compile
# time (same reason the banners above are functions), so this is safe to call
# from the kernel program body — unlike the _AGNOS_VERSION gvar below. Callers
# strlen() the result. Used by e.g. the TCP_LISTEN_SMOKE HTTP banner.
fn agnos_version_str() {
    return "$NEW";
}

# Bare version string — safe to use from any consumer that runs AFTER
# gvar init has completed (kybernet, userspace, etc.). NOT safe to use
# from the kernel program body (same kmode init-order constraint above).
var _AGNOS_VERSION = "$NEW";
EOF
    updated="$updated  kernel/version.cyr (regenerated)\n"
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
STALE=$(grep -rn "$OLD" "$ROOT/VERSION" "$ROOT/kernel/agnos.cyr" "$ROOT/kernel/version.cyr" 2>/dev/null || true)
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
