# Issue: `cyrius fmt` tracks `{` / `}` inside `#` comment lines, producing false-positive indentation requests

**Status**: **resolved** — cyrius v5.7.22 ships the fix (programs/cyrfmt.cyr brace counter now skips `#` comments + `"..."` strings). agnos can revert the local prose-rewrite workaround once toolchain pin bumps to v5.7.22; gate 4ae in cyrius `scripts/check.sh` locks the invariant.
**Date**: 2026-04-27
**Affects**: any `.cyr` file whose top-level comments contain literal
            `{` or `}` characters (e.g. quoting an `asm { … }` block
            in a doc comment, or describing a Cyrius function body).
**Repo**: cyrius (`scripts/cyrfmt` / `cyrius fmt` codepath — likely in
          the `cyrius/src/` formatter)
**Reporter**: Robert MacCracken (surfaced during agnos v1.26.0 CI)

## Summary

`cyrius fmt --check` treats `{` and `}` characters inside `#` comments
as block-open / block-close tokens, just like in code. When a top-level
comment quotes Cyrius source (e.g. `# the asm { mov cr3, rax; } pattern`),
the formatter:

1. Sees the `{` on one comment line — increments its block-depth counter.
2. The next comment line is now treated as "inside a block" and the
   formatter emits it indented one level.
3. The `}` on a later line decrements the counter back.

This causes the in-place comment to be re-indented relative to the rest
of the comment block, which makes `cyrius fmt --check` report
`NEEDS FORMAT` even though the source is well-formed prose.

agnos CI tripped on this in v1.26.0:

```
Run FAIL=0
  NEEDS FORMAT: kernel/core/proc.cyr
  NEEDS FORMAT: kernel/core/main.cyr
Error: Process completed with exit code 1.
```

## Reproducer

Minimal `.cyr` file that triggers `NEEDS FORMAT` under
`cyrius fmt --check` (this is real code from agnos before the
workaround):

```cyrius
# Load cr3_val (first param at [rbp-8] per Cyrius calling convention)
# into RAX, then write to CR3. Replaces the `var x = y; asm { mov cr3,
# rax; }` pattern — that pattern relied on cc3-era codegen leaving the
# assigned value in RAX, which cc5's regalloc breaks. Function-shaped
# helpers using `[rbp-N]` param loads are robust across compiler
# versions (same approach as kernel/arch/x86_64/io.cyr's outb/inb).
fn cr3_load(cr3_val) {
    asm {
        0x48; 0x8B; 0x45; 0xF8;
        0x0F; 0x22; 0xD8;
    }
    return 0;
}
```

`cyrius fmt --check` against that file emits a one-line diff:

```
115c115
<     # rax; }` pattern — that pattern relied on cc3-era codegen leaving the
---
> # rax; }` pattern — that pattern relied on cc3-era codegen leaving the
```

The formatter wants the comment line indented 4 spaces because — per
its tracking — line 114's `{` opened a block and line 115's `}` is
still inside that block.

Same shape on `kernel/core/main.cyr` line 319.

## Diagnosis

cyrius's formatter likely walks the source character-by-character (or
token-by-token) and increments/decrements a block-depth counter on
every `{` and `}` regardless of whether they're inside a comment, a
string literal, or actual code. The CI hint in agnos's
`.github/workflows/ci.yml` already calls this out:

```
# Files with `#ifdef` inside function bodies can't satisfy both
# the formatter (wants indentation) and the preprocessor
# (needs column 0). Skip those with the SKIP list.
```

…which suggests the formatter has the same blind-spot for `#ifdef`
preprocessor lines. The `kernel/user/shell.cyr` file is on the SKIP
list precisely because of this pattern. Comments containing `{` /
`}` are a different surface of the same root cause.

## Fix path (upstream — cyrius)

The formatter's brace tracker should ignore characters that fall
inside:

1. **`#` comments** (everything from `#` to end-of-line).
2. **String literals** (already handled? worth verifying — agnos's
   doc-string heavy code hasn't tripped it, but a string literal
   like `"asm { mov cr3, rax; }"` would be the same shape).
3. **Backtick-delimited markdown spans inside comments**, if cyrius
   wants to be tidy. Lower priority.

Single-line fix in the formatter pass: when iterating tokens, skip
brace-counter updates if the current scan position is past a `#` on
the same line.

The existing `# braces inside `#ifdef`/`#endif` lines` SKIP-list
workaround in agnos and other consumers becomes unnecessary once this
lands.

## agnos local workaround (until upstream lands)

Rewrote the offending comments to describe the pattern in prose
without literal `{` / `}` characters. e.g.:

```diff
-# Load cr3_val …. Replaces the `var x = y; asm { mov cr3,
-# rax; }` pattern — that pattern relied on cc3-era codegen leaving the
-# assigned value in RAX, …
+# Load cr3_val …. Replaces the older "assign-then-asm" pattern
+# (assign as1 to a var, then inline asm reads RAX to write
+# to CR3) which relied on cc3-era codegen leaving the assigned
+# value in RAX. cc5's regalloc breaks that.
```

Same meaning, no formatter confusion.

This is *agnos-side* and shouldn't block cyrius work; it just keeps
agnos CI green until the upstream fix ships. When upstream lands,
agnos can revert to the more readable comment phrasing if desired
(low priority — current prose is fine).

## Related

- The "SKIP" entry for `kernel/user/shell.cyr` in
  `.github/workflows/ci.yml` is the same family of issue — `#ifdef`
  preprocessor directives in function bodies confuse the formatter's
  brace/indent tracking. A general fix to ignore `#…\n` for
  brace-counter purposes addresses both.
- Other consumers (kybernet, argonaut, agnostik, etc.) don't appear
  to hit this — most of their docstrings are markdown-style without
  raw braces. agnos hits it because the kernel routinely quotes
  inline-asm syntax in its docstrings.

## Out of scope

- Whether the formatter should *render* such comment-quoted code
  blocks specially (syntax-highlight in `cyrius doc`, etc.). Pure
  formatter correctness fix is enough; presentation is later.
