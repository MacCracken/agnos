# Cyrius: a module-scope `var` with a COMPUTED initializer silently becomes 0 (kmode)

> ## ✅ FIXED IN CYRIUS 6.4.74 (2026-07-24) — the preferred option (★ const-fold) shipped
>
> The cyrius changelog for 6.4.74 implements exactly the ask: a constant folder
> (`_CF_TRY`/`_CF_EXPR`/`_CF_TERM`/`_CF_FACTOR` in `parse_decl.cyr`) that widens the static-init path to any
> foldable integer expression, so `var A = 512 * 2;` in kmode now produces a **byte-identical image** to
> `var A = 1024;`. No ordering change, no risk to the multiboot invariant. Validated by a 42-expression /
> 84-probe differential (folded gvar vs runtime fn-body): **0 mismatches**. A companion codegen fix in the
> same release (`_cfo = 0` cleared before `PARSE_FACTOR`, 17 sites) removed a *separate* silent-wrong-value
> class it would otherwise have matched.
>
> ⚠ **The filing's original "included module" framing was wrong** — the fix confirms it is **x86_64-ELF
> kmode only** (six other backend forks emit gvar inits before `PARSE_PROG` and never had it). The title is
> corrected above.
>
> **agnos side:** `cyrius.cyml` bumped **6.4.2 → 6.4.74**, so the fold is now the enforced floor. The kernel
> was already being built warn-only by the installed 6.4.74 cycc, so the fix was already in the shipped
> binary; the bump ends the drift. The inline-literal workarounds (atom.cyr rc codes, modeset_latch.cyr gate
> token) are LEFT in place as belt-and-suspenders and clarity — they are correct on any pin — but are no
> longer load-bearing.

- **Filed**: 2026-07-23 · **Fixed**: 2026-07-24 (cyrius 6.4.74)
- **Reporter**: agnos (kernel), during modeset-arc bite H4
- **cycc**: 6.4.72 installed · agnos `cyrius.cyml` pins 6.4.2 (built warn-only, no `--strict-pin`)
- **Severity**: **high** — silent wrong value, no diagnostic, and it produced a *passing* test that was
  comparing 0 against 0
- **Cross-filed**: this document is committed to **both** `agnos` and `cyrius` per the cross-repo rule.

> **This is the language-side companion to agnos
> [`2026-07-23-kernel-expression-gvar-initialisers-never-run.md`](2026-07-23-kernel-expression-gvar-initialisers-never-run.md)**,
> which found the same class while retiring the 1.56.x D lane and named this filing as its follow-up #3
> ("a cyrius ask, not a cyrius change … not filed yet, because the language question deserves its own
> framing rather than being a footnote to a display bug"). That issue owns the **agnos-side** remediation
> (sentinel audit, `gpu_sentinels_init()`, the eight remaining globals); this one owns the **language**
> question. Read that one for the root-cause mechanism, restated below.

## Summary

A module-scope `var` whose initializer is a **computed expression** reads as **0** for the entire life of the
agnos kernel, instead of the expression's value. A plain integer literal is unaffected. No warning, no error.

## Mechanism (from the agnos-side issue — credit there, restated so this stands alone)

In kernel mode (`kmode == 1`) cycc emits module-global initialisers in **`EMIT_GVAR_INITS`, which runs after
`PARSE_PROG`** — an ordering agnos *depends on*, because the boot shim must be the first top-level statement
emitted so 64-bit gvar initialisers run after the switch to long mode.

But for this kernel **`PARSE_PROG` is the entire boot**: `core/main.cyr`, `core/selftests.cyr` and
`core/boot_finish.cyr` are all top-level program body, and `boot_finish.cyr` ends in `arch_halt()`. So
`EMIT_GVAR_INITS` **is never reached while the machine is doing anything**.

A plain literal (`var X = 3000;`) is const-folded into the data section and is correct from the first
instruction. `0 - 61` is **not** const-folded, so it becomes an assignment in the deferred init block that
never runs. The two declarations look identical at the call site.

⚠ **Earlier framing in this document was wrong and is corrected here:** this is not about *included modules
vs the top-level program*. It is about **kmode emit ordering plus a program body that never returns.**

## Measured

All four in one build, printed from a function at runtime (agnos `kernel/core/atom.cyr`, inside
`#ifdef HDMI_ATOM`, an included module):

| Declaration | Expected | Observed |
|---|---|---|
| `var ATOM_WS_SLOT = 1024;` | 1024 | **1024** ✅ |
| `var ATOM_T_POSEXPR = 512 * 2;` | 1024 | **0** ❌ |
| `var ATOM_T_NEGSMALL = -5;` | −5 | **0** ❌ |
| `var ATOM_RC_RESERVED = 0 - 61;` | −61 | **0** ❌ |

So it is **not** negative-specific — `512 * 2` fails too. Negative values are affected because unary minus
is itself an expression. The discriminator is *literal vs computed*.

Note that an inline literal in a **statement** is fine: `ret = -22;` inside a function body has always
worked in this same file, which is why the defect stayed hidden — the older code used inline literals.

## Why it matters (what it actually cost)

agnos's ATOM interpreter added distinct return codes so that a table stopping on a reserved opcode could be
told apart from a clean EOT. They were written as:

```cyrius
var ATOM_RC_OK        = 0;
var ATOM_RC_RESERVED  = 0 - 61;
var ATOM_RC_OUTOFRANGE = 0 - 62;
```

Every non-zero one silently became **0**. Therefore:

- `ret = ATOM_RC_RESERVED;` assigned **0**
- the reporter `if (ret != ATOM_RC_OK)` compared `0 != 0` and never fired
- the selftest asserted `got == ATOM_RC_RESERVED`, i.e. `0 == 0`, and **reported 4/4 PASS**

A green test, in the very bite whose stated purpose was to eliminate silent false passes. It was caught only
because the QEMU smoke *also* asserted on the reporter's printed output rather than the pass count alone.

## Reproducer

```cyrius
# in an INCLUDED module (declared in cyrius.cyml [lib] modules, not the top-level program)
var LIT  = 1024;
var EXPR = 512 * 2;
var NEG  = -5;

fn show() {
    kprint("LIT=",  4); kprint_num(LIT);
    kprint(" EXPR=", 6); kprint_num(EXPR);
    kprint(" NEG=",  5); kprint_num(NEG); kprintln("", 0);
    return 0;
}
# prints: LIT=1024 EXPR=0 NEG=0
```

## The ask (one of these, language side's call)

1. **★ Const-fold foldable expressions into the data section, like plain literals.** `0 - 61`, `-5`,
   `1 << 4`, `A * B` over literals — all are compile-time constants. Folding them makes this entire class
   disappear with no ordering change and no risk to the `PARSE_PROG`-before-`EMIT_GVAR_INITS` contract agnos
   depends on. **This is the preferred fix**, and it is what the agnos-side issue recommends.
2. **Failing that, reject or warn** on a non-foldable module-scope initializer in `kmode == 1`. A silent 0 is
   the worst available outcome: it builds clean, it `cyrius fmt`s clean, it survives every gate agnos has,
   and — see below — it can make a **test pass**.

Not asked for: changing the emit order. agnos depends on it.

## Related, possibly same root cause

`var X[N]` allocates `N × u64` in an included module but `N` **bytes** in a top-level program (agnos
`kernel/core/ext2.cyr:28-44`, memory [[feedback_cyrius_var_array_u64_units]]). If both come from how module
globals are emitted, they may be worth looking at together.

## Workaround in use

agnos writes these rc codes as **inline literals at every site** and documents the values in a comment block
above, with an explicit "do not tidy these into named `var`s" warning plus a pointer to this issue.
