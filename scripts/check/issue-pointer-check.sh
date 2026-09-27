#!/bin/sh
# issue-pointer-check — every `docs/development/issues/<name>.md` pointer in scripts/, tests/, kernel/ and docs/
# names a file that exists. check.sh gate 36 (1.57.10, HAR2 — issue 2026-09-26-harness-backlog-after-1-57-9, item 2).
#
# ⛔ WHY. An issue is closed by MOVING its file into docs/development/issues/archived/ (CLAUDE.md "Docs Pointers"),
# and nothing moved the pointers with it. At 1.57.10, 30 comments in scripts/, tests/ and kernel/ were dangling:
# sweep smokes, the tests/* programs those smokes build, and ahci.cyr, elf.cyr, syscall.cyr, gpu.cyr, io.cyr.
# 12 more lines in archived issue docs pointed the same way. The comment that explains WHY a line exists sent the
# reader to a file that was not there, and every one of them "worked" as far as any gate could tell.
#
# ⭐ PRIOR ART (handoff-1.57.10/steps/HAR2-prior-art.md): Linux tools/docs/documentation-file-ref-check
# (`make refcheckdocs`). It `git grep`s the whole tree for `Documentation/` paths, skips URLs and a named
# false-positive table, and reports every path that does not exist. Its --fix looks up where a moved file went.
# This gate has the same shape for one directory. It is pure text, it never builds, and it only PRINTS its
# MOVED hint; it never applies it.
#
# WHAT A POINTER IS
# - The text `docs/development/issues/<name>.md` (<name> may include `archived/`) NOT preceded by a path character.
# - So `cyrius/docs/development/issues/…` and `https://…/blob/main/docs/development/issues/…` point into ANOTHER
#   repo and are not checked. Write a sibling repo's issue with the repo name as the first path component. A bare
#   one is read as agnos's own and fails here.
# - A slug without the path ("issue 2026-09-25-…") is not a pointer, and it survives an archive move by construction.
#   New comments should prefer the slug form.
#
# WHICH FILES
# - `git ls-files -co --exclude-standard`: tracked files plus untracked files that are not ignored. A new smoke that
#   has not been `git add`ed yet is covered. The gitignored tests/*/lib cyrius stdlib snapshots are not; their
#   comments point into the CYRIUS repo's issues.
# - Without git: `find`, minus tests/*/lib and tests/*/build.
#
# EXCLUDED (the %false_positives analog; each has its reason)
# - docs/doc-health.md: a dated LEDGER, like CHANGELOG.md (which lies outside these trees). Its entries record what
#   a doc was when it was touched, including "NEW docs/development/issues/<x>.md" for issues archived since then.
#   Rewriting history is not the fix.
# - scripts/check/issue-pointer-check.sh: this file.
#
# Exit 0 when every pointer resolves. Exit 1 when one does not, naming file:line, the pointer, and either
# MOVED -> <the archived/ path> or MISSING. The counts are PRINTED. A floor makes an enumeration that found
# (almost) nothing FAIL rather than pass: a git failure, or a regex that stopped matching, would otherwise read clean.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
ISSUES="docs/development/issues"
EXCL_LEDGER="docs/doc-health.md"                 # see EXCLUDED above
EXCL_SELF="scripts/check/issue-pointer-check.sh"
MIN_FILES=200     # measured 1.57.10: 557 files scanned in the four trees
MIN_POINTERS=20   # measured 1.57.10: 55 pointers resolve after the HAR2 fixes (mutation record: handoff-1.57.10 logs/HAR2)

# No temp files: everything streams through pipes. A lister that fails (git, find) or a write that fails yields an
# empty stream, which the vacuity floor below scores FAILED, never clean.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    LISTER="git ls-files -co --exclude-standard"
    list_files() { git -C "$ROOT" ls-files -z -co --exclude-standard -- scripts tests kernel docs; }
else
    LISTER="find (no git)"
    list_files() { find scripts tests kernel docs -type f ! -path 'tests/*/lib/*' ! -path 'tests/*/build/*' -print0 2>/dev/null; }
fi
# The file list minus the exclusions (-z: NUL-separated records, -x: whole path, -F: literal).
files() { list_files | grep -zvxF -e "$EXCL_LEDGER" -e "$EXCL_SELF"; }
NFILES=$(files | tr -cd '\0' | wc -c | tr -d ' ')

# file:line:<one char or nothing>docs/development/issues/<name>.md, one per pointer (-o), always with the name (-H).
# -I skips binaries, -s drops a tracked file deleted from the worktree.
HITS=$(files | xargs -0 grep -sHnIoE "(^|[^A-Za-z0-9_./-])$ISSUES/[A-Za-z0-9][A-Za-z0-9_./-]*\\.md")

# Resolve each hit (a subshell fed by a pipe, not a here-doc: no temp file). It prints one line per unresolved
# pointer, then "COUNTS <pointers> <resolved>" last.
RESULT=$(printf '%s\n' "$HITS" | {
    np=0; nok=0
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        f="${hit%%:*}"; rest="${hit#*:}"; n="${rest%%:*}"
        p="$ISSUES/${rest#*"$ISSUES/"}"
        np=$((np + 1))
        if [ -f "$p" ]; then nok=$((nok + 1)); continue; fi
        name="${p#"$ISSUES/"}"
        if [ -f "$ISSUES/archived/$name" ]; then
            echo "    $f:$n: $p — MOVED -> $ISSUES/archived/$name"
        else
            echo "    $f:$n: $p — MISSING (no such file here or in archived/; another repo's issue must be written <repo>/$ISSUES/…)"
        fi
    done
    echo "COUNTS $np $nok"
})
set -- $(printf '%s\n' "$RESULT" | sed -n 's/^COUNTS //p')
NPTR="${1:-0}"; NOK="${2:-0}"
BAD=$(printf '%s\n' "$RESULT" | grep -v '^COUNTS ')
[ -z "$BAD" ] || BAD="$BAD
"
NBAD=$((NPTR - NOK))

if [ "$NFILES" -lt "$MIN_FILES" ] || [ "$NOK" -lt "$MIN_POINTERS" ]; then
    echo "issue-pointer-check: FAILED — VACUOUS: $LISTER gave $NFILES file(s) (floor $MIN_FILES) and $NOK pointer(s) resolved (floor $MIN_POINTERS);"
    echo "  an enumeration this small says the lister or the pattern broke, not that the tree is clean."
    printf '%s' "$BAD"
    exit 1
fi
if [ "$NBAD" -ne 0 ]; then
    echo "issue-pointer-check: FAILED — $NBAD of $NPTR docs/development/issues/ pointer(s) do not resolve:"
    printf '%s' "$BAD"
    echo "  An archived issue lives in $ISSUES/archived/ — update the pointer where it is written (the MOVED path above)."
    exit 1
fi
echo "issue-pointer-check: OK — $NPTR docs/development/issues/ pointer(s) in $NFILES files resolve ($LISTER; excluded: $EXCL_LEDGER $EXCL_SELF)"
exit 0
