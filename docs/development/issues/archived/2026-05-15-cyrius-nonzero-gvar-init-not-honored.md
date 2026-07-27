# Issue (RESOLVED): Non-zero `var X = literal;` initializer at module scope not honored at runtime

**Status**: **RESOLVED 2026-05-18 (cyrius 5.11.64).** Cyrius fixed the root cause —
static-init for top-level `var X = INT_LITERAL` (cyrius CHANGELOG 5.11.64), so the
literal is emitted into the binary image and the first read returns the value
regardless of init-order. The cyrius-side issue is filed + archived
(`cyrius/docs/development/issues/archived/2026-05-18-gvar-init-order-zero-reads.md`).
The agnos Repair-P workaround (re-assignments in `fb_console_init`) was deleted at
agnos 1.30.11; top-level non-zero literal gvar inits now take effect correctly
(agnos pins cyrius 6.2.7, far past the fix). Audit-confirmed + archived 2026-06-18.

**Date**: 2026-05-15
**Cyrius**: 5.11.55 (`agnos/cyrius.cyml` pin)
**Agnos**: 1.30.0 → 1.30.1 candidate (Repair P)
**Affects**: `kernel/arch/x86_64/fb_console.cyr:187-189` at module scope.
            Whole kernel binary is at risk of the same class of silent
            wrong-init for *any* `var X = non_zero_literal;` at module
            scope.

## One-line symptom

`var FB_CONSOLE_Y0 = 80; var FB_FG = 0x00FFFFFF; var FB_BG = 0x00000000;`
at module scope appear to compile cleanly but read back as **`0`** when
their first reader runs.

## How it surfaced

Iron-boot Attempt 29 (NUC AMD / archaemenid). Kernel reached
`cp_fb(0x15)` (kybernet-launch checkpoint, CMOS-confirmed
`kcp=0x15`), then `kybernet()` called `kprintln(...)` ~6 times +
`shell()` painted `agnos> ` prompt. Expected visual: full cp_fb
cell sequence + readable prompt in console region (y≥80).

Observed visual: cp_fb cells **0x06..0x10 (rows 1–2, y=8..19) wiped**;
cells 0x80/0x81/0x82 (row 9, y=72..75) **preserved**; no prompt
visible anywhere on screen.

The wipe pattern decodes uniquely to two simultaneous wrong values:

1. `FB_CONSOLE_Y0 = 0` instead of `80` → `fb_putc` paints text at
   `y = 0 + fb_cur_y*8 = 0, 8, 16, …` instead of `80, 88, 96, …`.
   The ~6-line text burst covers y=0..55, overwriting cp_fb cells
   at rows 1–7. Row 9 (y=72..75) survives because the prompt sits
   idle at line ~6, never reaching that far.
2. `FB_FG = 0` and `FB_BG = 0` instead of `0x00FFFFFF` / `0x00000000`
   → every glyph paints black-on-black. The pixels *are* written
   (which is why cp_fb cells disappear: they're overpainted to
   solid black), but the resulting text is invisible against any
   background.

Both effects collapse onto a single root cause: the three non-zero
module-scope initializers aren't being honored.

## Important counter-evidence (the "smoking gun")

The same file has these vars at module scope (`fb_console.cyr:35-37`):

```cyrius
var fb_cur_x = 0;
var fb_cur_y = 0;
var fb_console_ready = 0;
```

These **work correctly** — `fb_console_init()` sets
`fb_console_ready = 1` and `fb_putc` correctly checks it
(early-returning before the repair, then advancing past the check
after `fb_console_init` runs). Cursor variables advance correctly.

So:
- `var X = 0;` at module scope → **works** (BSS zero default; no
  runtime init needed)
- `var X = <non-zero literal>;` at module scope → **silently wrong**
  (reads back as 0)

The differential pin-points the bug to the gvar-init phase emitting
non-zero initializers.

## Reproducer (minimal — pending isolation)

The kernel-side repro is the file itself; minimal standalone repro
hasn't been built yet. Sketch of what should suffice:

```cyrius
var X = 80;
fn main() {
    if (X == 80) { syscall(60, 0); }   # exit 0
    syscall(60, 1);                     # exit 1
}
var exit_code = main();
syscall(60, exit_code);
```

Expected: exit 0. Suspected actual under v5.11.55: exit 1.

Variations to test (probably distinguishing):
- Module-scope vs function-scope (the latter likely works — Cyrius
  programs use this pattern all over: `cyrius/programs/ark.cyr:22-25`
  has `var ARK_VERSION = "0.9.0";` etc., and ark works).
- Kernel-mode vs userspace emit. Agnos uses `kernel;` at top of
  `kernel/agnos.cyr` (line 4). The agnos.cyr comment at lines
  73-78 says: "cyrius v5.7.19 enforces this via kmode==1 emit
  order (PARSE_PROG before EMIT_GVAR_INITS); regression locked in
  by cyrius check.sh gate 4ab." So **gvar inits do exist in
  kmode emit order** — the question is whether they actually emit
  the store instruction for non-zero literals.
- Earlier-included file vs later-included. `fb_console.cyr` is
  included at line 11 of `agnos.cyr`, before `boot_shim.cyr` at
  line 79. Per the v5.7.19 enforcement, gvar inits from
  earlier-included files run *after* `boot_shim.cyr`. If the bug
  is "kmode gvar-init phase emits stores for zero values but
  omits them for non-zero values," the repro is the kernel itself.

## Workaround (landed in agnos as Repair P)

Explicit re-assignment inside a function that runs early
(`fb_console_init()` is called from `kernel/core/main.cyr:6`):

```cyrius
fn fb_console_init() {
    FB_CONSOLE_Y0 = 80;
    FB_FG = 0x00FFFFFF;
    FB_BG = 0x00000000;
    fset(0x20, ...);  # font table init follows
    ...
}
```

The module-scope `var X = 80;` declarations stay (correct intent;
canonical once the cyrius bug is fixed). The explicit assigns in
`fb_console_init()` are belt-and-suspenders.

Kernel size delta: 253,768 → 266,712 B (+12,944, dominated by DCE/link
state, not the 3-line assign — the assigns add ~30 bytes).

## What we know is NOT the cause

- Not a boot-shim / long-mode transition issue. `agnos.cyr:73-78`
  documents that gvar inits run AFTER boot_shim.cyr for exactly
  this reason. cyrius v5.7.19 emit order already addresses
  pre/post-long-mode init separation. Repair P confirms (the
  in-function assigns work) that 64-bit gvar stores function
  correctly post-shim.
- Not a `FB_CONSOLE_Y0`-specific issue. All three (different
  magnitudes: 80, 0xFFFFFF, 0) exhibit the same wrong-result.
- Not a shadowing issue. There's no other `FB_CONSOLE_Y0` /
  `FB_FG` / `FB_BG` in the kernel; grep is clean.
- Not a "zero-init works" red herring. `var fb_console_ready = 0;`
  works *because BSS defaults to zero* — that case never needs
  an init store. Non-zero literals do.

## Suggested cyrius-side investigation

Look at the codegen path for module-scope `var X = <non_zero_literal>;`
in kmode. Question to answer: when `EMIT_GVAR_INITS` runs (after
`PARSE_PROG`), does it emit a `mov [X], <literal>` for each non-zero
gvar?

Possibilities to consider:
- The store IS emitted but never reached (gvar-init basic-block is
  unreachable in some kmode-specific control flow).
- The store is NOT emitted (codegen treats `= literal` as
  metadata-only, expects loader to fill BSS — which only works
  for zero).
- The store is emitted to the wrong address (clobbering some other
  unrelated location).

A repro outside the kernel context (userspace `cyrius build`)
would distinguish kmode-specific from a universal bug.

## Severity

**Medium — silent wrong-result.** No crash, no compile error, no
diagnostic. The only signal is that something in the consumer
behaves wrong. agnos burned one iron attempt (Attempt 29) on the
debug. The pattern "non-zero module-scope init silently zero" is
a class of bug that could land anywhere a consumer uses the
pattern — common enough that we should expect more reports.

## Verification gate

Filing this issue is gated on **Attempt 29 burn showing the full
cp_fb cell sequence AND a visible `agnos> ` prompt**. If the burn
shows that, hypothesis confirmed, surface this writeup to cyrius
verbatim (or as updated by the user). If the burn shows something
different, this writeup is wrong — re-investigate.

## Out of scope

- Whether to ship a cyrius compile-time warning for "non-zero
  module-scope `var X = literal;`" if the codegen-fix is non-trivial.
- Whether to add a kernel-mode `check.sh` gate for this regression
  class.
- Whether the same bug affects userspace (Cyrius programs like ark
  appear to use this pattern fine — likely kmode-specific, but
  worth a userspace repro).
