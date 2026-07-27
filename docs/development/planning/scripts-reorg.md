# scripts/ reorganisation — APPROVED, scheduled after the rung-14 WRAP burn

**Status:** approved 1.56.22; execute after the next iron burn, together with the `tests/gpu/` move.
**Why deferred:** the split changes the paths in the burn instructions the operator is holding.
Same reasoning that deferred `tests/gpu/` — a reorganisation mid-flash is how a stale path reaches
iron. The 1.56.22 tidy already demonstrated the failure mode: moving `fp-test/` → `tests/fp/` broke
six smokes, and only `burn-prep`'s sweep gate stopped the flash.

## The shape

```
scripts/            build.sh check.sh test.sh sweep.sh bench.sh version-bump.sh
                    ← called constantly, by hand and by CI. Moving them buys nothing and
                      breaks the most-typed paths in the tree.
scripts/burn/       burn-prep.sh burn-verify.sh stage-tools.sh stage-agnsh.sh install-hooks.sh
scripts/smoke/      the 86 *-smoke.sh
scripts/check/      check-arena.sh check-array-sizing.sh fmt-check.sh fmt-fix.sh
                    kprint-len-check.sh shader-blob.sh
scripts/probe/      *-repro.sh *-diag.py *-probe.py lockup-driver.py
scripts/harness/    agnsh-*-test.py setu-*-test.py doom-*-test.py run37-smp4-test.py
scripts/tool/       elf-fixup.py patch_aarch64.py mk-dirty-journal-img.py fb-ansi-screendump.sh
```

137 files today: 86 smokes, 51 everything else.

## What it costs, measured not guessed

~80 live references outside CHANGELOG:

| site | count | note |
|---|---|---|
| `docs/development/build.md` | 21 | live instructions |
| `kernel/core/main.cyr` | 20 | comments pointing at the smoke that proves each path |
| `scripts/build.sh` | 13 | invokes smokes |
| `docs/development/planning/*.md` | ~14 | live plans |
| `scripts/sweep.sh` | table | the gate list |
| `.github/workflows/ci.yml` | few | |

## ⛔ CHANGELOG AND THE IRON LOG ARE NOT SWEPT

`CHANGELOG.md` carries ~146 references and `agnosticos/docs/development/iron-nuc-zen-log.md`
carries more. **These are historical records of what was true when written.** Rewriting a path in a
1.52.8 burn entry would make the log claim something that was not the case at the time — that is
falsifying the record, not tidying it. A reader who follows an old path and finds nothing has
learned the truth: it moved. A reader who follows a rewritten path and finds a file that did not
exist then has been lied to.

**Rule: sweep forward-looking docs; leave dated records alone — and make the CURRENT cycle's
CHANGELOG entry the movement record.** That is what makes the convention safe rather than merely
conservative: history keeps the paths it was written with, and anyone tracing an old path forward
lands on a table saying where it went. The 1.56.22 entry carries that table for the `tests/` move;
the `scripts/` split must add its own when it lands. Applied already at 1.56.22 — the
FP plan doc's `audio-test/naadex.cyr` was repointed (it describes work still to do), the iron log's
`agnos/audio-test/tonegen.cyr` was not (it records a burn that happened).

## ⛔ SWEEP BOTH REPOS — the 1.56.22 tidy missed one and it failed SOFT

The `tests/` move was swept across `agnos/` and looked clean. It was not:
`agnosticos/scripts/install-media.sh` — **the one command the operator runs** — still pointed at
`../agnos/fp-test/` and `../agnos/audio-test/`. It did not error; it printed
`fpex: skipped (no --agnos build at …)` and carried on, so a flash would have shipped without
`/bin/fpex` and `/bin/tonegen` while reporting success.

**A soft skip is worse than a hard failure here**, because the burn looks fine and the missing
binary only surfaces as "that test isn't on the box" hours later.

When `scripts/` and `tests/gpu/` move, grep BOTH trees before declaring the sweep done:

```sh
grep -rn --exclude-dir=.git -E "scripts/[a-z0-9-]+\.(sh|py)|tests/gpu/" \
    ~/Repos/agnos ~/Repos/agnosticos
```

and check every hit that is a *path used at runtime*, not merely mentioned. `install-media.sh`
reaches into `../agnos/` in several places and is the highest-consequence consumer.

## The three categories a path move breaks — all three bit, in order

Recorded because only the first is what "sweep the references" makes you think about:

1. **References TO a script** — `sh scripts/foo.sh` in docs, CI, other scripts.
   Found by grep. This is the easy one and it is the one everybody plans for.
2. **Paths computed INSIDE a script** — `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`. One directory
   deeper and ROOT is now `scripts/`, so every path the script derives is wrong. **123 scripts.**
   Invisible to a grep for the script's own name; caught only by `check.sh` going red.
3. **Generated artifacts OUTSIDE the tree** — `.git/hooks/pre-push` execs `scripts/fmt-check.sh`,
   and `.git/hooks/` is not version-controlled. No grep of the repo can find it. It surfaced as a
   failed `git push`. The installer source was already correct; the *installed copy* was stale.

⚠ Category 3 generalises: anything a script **writes elsewhere** — hooks, installed binaries, cached
configs, staged rootfs entries — must be **regenerated** after a move, not merely rewritten in
source. Re-run the installers.

⚠ And two soft-failure traps in category 1 that a naive pattern misses: `agnos/gpu-test` without a
trailing slash (so a `gpu-test/` pattern skips it), and consumers in a **different repo**
(`agnosticos/scripts/install-media.sh`). Both fail SOFT — a skipped stage, not an error.

## Verification

`sh scripts/sweep.sh` must be green afterwards — it exercises the moved smokes through their new
paths, so a missed reference shows up as a red gate rather than as a surprise on iron. Then
`check.sh` and one `burn-prep` dry run to confirm the burn path still resolves.
