#!/bin/sh
# Version bump script — single source of truth for all version references
# Usage: ./scripts/version-bump.sh 1.22.0
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$1" ]; then
    echo "Usage: $0 <version>      # bump to <version>"
    echo "       $0 --regen        # re-derive generated sites from VERSION, no bump"
    echo "Current: $(cat "$ROOT/VERSION")"
    exit 1
fi

OLD=$(cat "$ROOT/VERSION" | tr -d '[:space:]')

# REGEN mode — re-derive every generated version site from VERSION *without*
# bumping. `--regen` is shorthand for passing the current version, which is the
# form kernel/version.cyr's own header documents. Pre-2026-07-26 that documented
# command hit an `[ "$NEW" = "$OLD" ] && exit 0` guard and did nothing, so a
# hand-edited or half-generated version.cyr had no supported way back into sync:
# agnos_version_str() and _AGNOS_VERSION sat at 1.56.17 on a 1.56.19 kernel for
# two patch releases, and uname#34 handed that stale string to every ring-3
# reader (mihi -> iam's "Kernel:" line). A no-op bump now regenerates instead of
# exiting. Release metadata (state.md date stamps, CHANGELOG section) is skipped
# in REGEN mode — regenerating derived files is not a release event.
REGEN=0
if [ "$1" = "--regen" ]; then
    REGEN=1
    NEW="$OLD"
else
    NEW="$1"
fi

# Validate semver
echo "$NEW" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$' || {
    echo "error: '$NEW' is not valid semver" >&2
    exit 1
}

if [ "$NEW" = "$OLD" ]; then
    REGEN=1
fi

if [ "$REGEN" = "1" ]; then
    echo "Regenerating version sites at $NEW (no bump)"
else
    echo "Bumping $OLD -> $NEW"
fi
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
# ⛔⛔ MEASURED 2026-08-28 (1.56.51): ALL THREE OF THE OLD state.md SEDS MATCHED NOTHING, and the
# script reported the file "Updated" anyway — the same silent-no-op class as the CHANGELOG step
# below. It looked for `| **Kernel** | **X.Y.Z** |`, `> **Last refresh**: DATE` and a
# `| **Released** | DATE |` row; the file's real shapes are `| Kernel head | **X.Y.Z — OPEN** …`,
# `**Last refresh** DATE` (no colon, mid-line) and no Released row at all. That is why state.md sat
# at **1.56.45** while VERSION already said 1.56.50 — five patch releases of drift in the one file
# whose entire job is to be current.
# ⭐ Patterns are matched against the file's ACTUAL shape and the result is ASSERTED. A version site
# that silently fails to update is worse than one that was never automated, because the "Updated:"
# line tells you it happened.
if [ -f "$ROOT/docs/development/state.md" ]; then
    ST="$ROOT/docs/development/state.md"
    sed -i -E "s#^(\\| Kernel head \\| \\*\\*)[0-9]+\\.[0-9]+\\.[0-9]+#\\1$NEW#" "$ST"
    grep -qE "^\\| Kernel head \\| \\*\\*$NEW" "$ST" || {
        echo "error: state.md's 'Kernel head' row did not update to $NEW." >&2
        echo "       The row's shape changed; fix this pattern rather than letting the bump" >&2
        echo "       silently skip it (which is what it did until 1.56.51)." >&2
        exit 1
    }
    # Date stamps are release metadata, not version-derived — a REGEN must not
    # move them (it would date-stamp a release that did not happen).
    if [ "$REGEN" = "0" ]; then
        TODAY=$(date +%Y-%m-%d)
        sed -i -E "s#(\\*\\*Last refresh\\*\\* )[0-9]{4}-[0-9]{2}-[0-9]{2}#\\1$TODAY#" "$ST"
        grep -q "\\*\\*Last refresh\\*\\* $TODAY" "$ST" || {
            echo "error: state.md's 'Last refresh' stamp did not update to $TODAY." >&2
            exit 1
        }
    fi
    updated="$updated  docs/development/state.md\n"
fi

# 3. kernel/agnos.cyr (comment). Matched by PATTERN, not by the literal OLD:
#    an OLD-anchored sed is a silent no-op the moment the site has drifted to
#    some third value (or when OLD == NEW in a REGEN), which is exactly the
#    class of staleness this script is supposed to clear.
if [ -f "$ROOT/kernel/agnos.cyr" ]; then
    sed -i -E "s/AGNOS kernel v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?/AGNOS kernel v$NEW/" "$ROOT/kernel/agnos.cyr"
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
# will overwrite. To regenerate without bumping, run either of:
#
#   sh scripts/version-bump.sh "\$(cat VERSION)"
#   sh scripts/version-bump.sh --regen
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

# 7. CHANGELOG.md — open the new dated release section. Skipped in REGEN mode:
#    opening a dated release section is a release act, and a regeneration must
#    not manufacture one.
#
# ⛔⛔ MEASURED 2026-08-28 (1.56.51): THIS STEP WAS A SILENT NO-OP AND HAD BEEN FOR A LONG TIME.
# It anchored on `/## \[Unreleased\]/` — a heading THIS CHANGELOG DOES NOT HAVE and, by the look
# of the file, never has. `sed` matching nothing is not an error, so the append ran, changed zero
# bytes, exited 0, and the script then unconditionally printed "Updated:   CHANGELOG.md". The bump
# REPORTED doing a thing it did not do. Nothing downstream noticed except check.sh's
# `version in changelog` gate, which fails AFTER the fact and blames the CHANGELOG rather than the
# tool that was supposed to have written it — so every release has been hand-adding the header and
# reading a false success line on the way past.
# ⚠ THE ANCHOR IS NOW DERIVED FROM THE FILE'S REAL SHAPE, not from a heading convention this
# project does not follow: insert immediately ABOVE the first `## [` release heading, which is
# where a new release belongs in a reverse-chronological changelog by definition.
# ⭐ AND THE RESULT IS ASSERTED. An anchor can rot again; a no-op that reports success cannot be
# allowed to. If the heading is not in the file after the edit, this exits non-zero.
if [ "$REGEN" = "0" ] && [ -f "$ROOT/CHANGELOG.md" ]; then
    if grep -q "^## \[$NEW\]" "$ROOT/CHANGELOG.md"; then
        updated="$updated  CHANGELOG.md (section already open)\n"
    else
        ANCHOR=$(grep -n '^## \[' "$ROOT/CHANGELOG.md" | head -1 | cut -d: -f1)
        if [ -z "$ANCHOR" ]; then
            echo "error: CHANGELOG.md has no '## [x.y.z]' release heading to insert above." >&2
            echo "       The file's shape changed; fix this anchor rather than letting the" >&2
            echo "       bump silently skip the section (which is what it did until 1.56.51)." >&2
            exit 1
        fi
        awk -v n="$ANCHOR" -v hdr="## [$NEW] — $(date +%Y-%m-%d)" \
            'NR==n { print hdr; print "" } { print }' \
            "$ROOT/CHANGELOG.md" > "$ROOT/CHANGELOG.md.tmp" \
            && mv "$ROOT/CHANGELOG.md.tmp" "$ROOT/CHANGELOG.md"
        grep -q "^## \[$NEW\]" "$ROOT/CHANGELOG.md" || {
            echo "error: CHANGELOG.md section for $NEW was not written." >&2
            exit 1
        }
        updated="$updated  CHANGELOG.md (opened section for $NEW)\n"
    fi
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

# Verify — assert every version token in the source files now EQUALS NEW.
# Pre-2026-07-26 this searched for the immediately-preceding OLD only, so a
# residual from any earlier version passed clean: version.cyr's two non-banner
# sites sat at 1.56.17 while OLD was 1.56.18, and the check reported "no stale
# references". Grepping for what should be gone can only catch one value;
# asserting what should be there catches all of them. (It also has to work when
# OLD == NEW in a REGEN, where the old form flagged every correct line.)
# kernel/version.cyr's header comment cites historical versions (v1.30.2), so
# only non-comment lines are scanned there.
echo ""
SEMVER='[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?'
STALE=""
CUR=$(tr -d '[:space:]' < "$ROOT/VERSION")
[ "$CUR" = "$NEW" ] || STALE="$STALE  VERSION: $CUR\n"
for v in $(grep -oE "AGNOS kernel v$SEMVER" "$ROOT/kernel/agnos.cyr" 2>/dev/null | sed 's/.*v//' || true); do
    [ "$v" = "$NEW" ] || STALE="$STALE  kernel/agnos.cyr: $v\n"
done
for v in $(grep -vE '^[[:space:]]*#' "$ROOT/kernel/version.cyr" 2>/dev/null | grep -oE "$SEMVER" || true); do
    [ "$v" = "$NEW" ] || STALE="$STALE  kernel/version.cyr: $v\n"
done
if [ -n "$STALE" ]; then
    echo "WARNING: version sites not at $NEW:"
    printf "$STALE"
else
    echo "Verified: every version site reads $NEW"
fi

echo ""
echo "Still manual:"
echo "  - CHANGELOG.md entries (add Added/Changed/Fixed sections)"
echo "  - README.md metrics (binary size, line count, subsystem count)"
