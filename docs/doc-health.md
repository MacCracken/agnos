---
name: AGNOS Documentation Health
description: Living state of doc currency in the agnos repo — fresh / stale / archive / open-question, refreshed as docs are touched
type: state
---

# Documentation Health — agnos

> **Last refresh**: 2026-05-11 (v1.28.0 ship — KASLR closes S7; CI boot-test grew the two-boot-diff KASLR assertion. No doc-tree health changes from the kernel work itself; row touched purely to confirm the ledger remains current at the new tag) | **Refresh cadence**: when a doc is touched, update its row. Full-tree sweep at minor-version closeouts.
>
> **Scope**: this repo only (`agnos`) — the `docs/` tree plus root-level files (README, CLAUDE.md, CHANGELOG, CONTRIBUTING, SECURITY, LICENSE, VERSION, cyrius.cyml). Sibling-repo docs (kybernet, agnosys, argonaut, agnostik, daimon, libro) are not audited here — each repo carries its own doc-health.md if its size justifies one. Cross-repo Cyrius pin/version drift lives in [`development/state.md`](development/state.md).
>
> **Location**: `docs/doc-health.md` (whole-tree scope) per [first-party-documentation § Development Docs](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md#development-docs-docsdevelopment). **Not** under `docs/development/` — the ledger sweeps the whole tree and the location should match the scope.

This is a **ledger**, not a one-time audit. Rewrite-in-place as docs change. Small repo (13 doc files + 7 root files), so the ledger stays narrow; if `docs/` grows past ~30 files, switch to tier roll-ups like the agnosticos repo's pattern.

---

## At a glance — 2026-05-11 inventory (v1.27.2 closeout + 1.28.x arc plan)

**22 markdown files total**: 8 root (CODE_OF_CONDUCT.md added in v1.27.2) + 14 under `docs/` (KASLR scope proposal added at v1.27.2 closeout, alongside the roadmap restructure for 1.28.x). Bucket counts after the v1.27.2 closeout sweep:

| Bucket | Count | What it means |
|---|---|---|
| ✅ **Fresh / refreshed in this audit** | 15 | All root files + `architecture/overview.md` + `development/{roadmap,state,kybernet-bridge,security-hardening,syscall-additions}.md` + `development/issue/2026-04-27-serial-putc-cc5-regression.md` + this ledger. The three 🟡 docs and the 🟠 read-through were all promoted in this pass. |
| 🟡 **Stale — refresh in place** | 0 | Cleared at v1.27.2. The three 2026-04-13-vintage `development/` docs (kybernet-bridge, security-hardening, syscall-additions) each got a "Last Updated" header + status block; per-item prose preserved as implementation-history reference. |
| 🟠 **Read-through outstanding** | 0 | Cleared at v1.27.2. `architecture/overview.md` header refreshed (v1.27.x), memory-map table refined for the 0-4 GB ceiling and IOMMU window, Process Model section gained the SMAP/`stac`/`clac` note. |
| 🔵 **Probably evergreen** | 3 | `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` — standard, re-read pass annually. |
| 📦 **Archive — frozen by design** | 5 | `docs/development/issue/archive/` (3 files) + `docs/development/proposals/archive/` (2 files). Verified — nothing misclassified. |
| ❓ **Open question** | 0 | No live strategic ambiguity. |

---

## Tier 1 — Root files

| File | Last touched | Status | Notes |
|---|---|---|---|
| `README.md` | 2026-05-11 | ✅ Fresh | Refreshed in this pass: dropped fossil benchmark numbers (v1.21.0 cc3-era), pointed at `state.md` for live binary sizes, fixed stale `Cyrius 5.7.19` requirement, dropped 35-row subsystem table (now owned by `state.md`), kept reader-facing Size Comparison + Quick Start + Architecture overview + 26-syscall reference. |
| `CHANGELOG.md` | 2026-05-11 | ✅ Fresh | v1.27.1 entry. v1.27.0 and v1.27.1 both written through this pass. |
| `CLAUDE.md` | 2026-05-11 | ✅ Fresh | **Rewritten** in this pass per [first-party-documentation § CLAUDE.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md#claudemd) — durable rules only, Current State pointer to `state.md`, durable Architecture Notes section for load-bearing invariants (`-D NAME` non-propagation, `kernel/lib/` shadow by design, `proc.cyr` `#ifdef ARCH_X86_64` guards, `kernel/user/shell.cyr` fmt-skip, boot-shim include order). Previously inlined: version, sibling versions, subsystem table, syscall numbers — all moved to `state.md`. |
| `CONTRIBUTING.md` | (pre-v1.27) | 🔵 Evergreen | Standard contribution guide. Re-read on minor closeout. |
| `SECURITY.md` | (pre-v1.27) | 🔵 Evergreen | Reporting policy. Re-read on minor closeout. |
| `LICENSE` | (genesis) | 🔵 Evergreen | GPL-3.0-only verbatim. |
| `VERSION` | 2026-05-11 | ✅ Fresh | `1.27.2`. Bumped by `scripts/version-bump.sh`; sole source of truth (cyrius.cyml resolves via `${file:VERSION}`). |
| `CODE_OF_CONDUCT.md` | 2026-05-11 | ✅ Fresh | **Added v1.27.2** to match first-party required-root-files set. Contributor Covenant v2.1 reference. |

## Tier 2 — `docs/architecture/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `architecture/overview.md` | 2026-05-11 | ✅ Fresh | **Refreshed v1.27.2**: header bumped (v1.25.0 → v1.27.x, cyrius 5.7.19 → 5.10.44, dropped stale binary-size + test-count claims in favor of state.md pointer). Memory-map table refined to show the 0–4 GB ceiling (v1.25.0) and the IOMMU register window. Process Model section gained the SMAP / `US=1` / `stac` / `clac` note so future page-fault triage doesn't repeat the v1.27.1 14-day detour. |

## Tier 3 — `docs/audit/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `audit/2026-04-13-security-audit.md` | 2026-04-13 | 🔵 Frozen (dated) | Audit report — dated artifact. Findings should be cross-referenced against current code; next audit pass produces a new `YYYY-MM-DD-*.md`, not an edit to this one. |

## Tier 4 — `docs/development/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `development/roadmap.md` | 2026-05-11 | ✅ Fresh | **v1.27.2 closeout**: Active table restructured into a versioned **`## 1.28.x Arc Plan`** with .0 KASLR / .1 serial_putc / .2 VFS tagged unions / .3 struct refactor. SMP-on-hardware (#1) moved to "Carried over" as a long-horizon item. Security Hardening S7 row annotated with the v1.28.0 target + proposal pointer. Planned section gained notes per item. Header re-synced to v1.27.2 + cyrius 5.10.44. |
| `development/state.md` | 2026-05-11 | ✅ Fresh | **Created** in this pass. Live snapshot of version, binary sizes, source rollup, subsystem rollup, syscall surface, sibling pins, test surface, verification hosts. Bump-target for future `version-bump.sh` runs. |
| `development/kybernet-bridge.md` | 2026-05-11 | ✅ Fresh | **Refreshed v1.27.2**: header notes kybernet's 1.0.2 → 1.2.0 jump; AGNOS 26-syscall interface unchanged. Per-tier syscall mapping preserved as historical-evolution reference. |
| `development/security-hardening.md` | 2026-05-11 | ✅ Fresh | **Refreshed v1.27.2**: new Status (v1.27.1) block shows 12/13 items Done — only S7 (KASLR) remains open. Per-item implementation prose unchanged; this doc is now an implementation-history reference (live tracking lives in roadmap.md). |
| `development/syscall-additions.md` | 2026-05-11 | ✅ Fresh | **Refreshed v1.27.2**: header bumped; status note added. Surface unchanged since v1.21.0 — no new syscalls in the v1.27.x correctness arc. |

## Tier 5 — `docs/development/issue/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `issue/2026-04-27-serial-putc-cc5-regression.md` | 2026-04-27 | ✅ Open / fresh | Active investigation. Recommendation in doc is **defer pending matched-conditions re-measurement**. Tracked as roadmap Active item #7. |
| `issue/archive/2026-04-27-memory-isolation-deep.md` | 2026-05-11 | 📦 Archive | **Closed at v1.27.1**. Resolution section (SMAP root cause + observation-to-mechanism table + process note on the hypothesis class that misled triage) prepended to the original body. Frozen — refer back but do not edit. |
| `issue/archive/2026-04-27-cr3-load-helper.md` | 2026-05-11 | 📦 Archive | Closed alongside the memory-isolation fix at v1.27.1 — the v1.26.0 helper was a real fix, just not the whole one. |
| `issue/archive/2026-04-27-cyrius-fmt-tracks-braces-in-comments.md` | 2026-04-27 | 📦 Archive | Closed at v1.26.1 (cyrius 5.7.22 fmt fix). Frozen. |

## Tier 6 — `docs/development/proposals/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `proposals/2026-05-11-kaslr-scope.md` | 2026-05-11 | ✅ Open / fresh | **Created v1.27.2.** Full-binary-relocation vs data-only KASLR design choice for 1.28.0. Recommends data-only as the 1.28.0 scope; full relocation deferred to 1.29+. Promote to an ADR if approved before 1.28.0 implementation begins. |
| `proposals/archive/2026-04-27-acpi-identity-map-ceiling.md` | 2026-04-27 | 📦 Archive | Closed at v1.25.0 (`pt_init` extended to cover 0–4 GB). |
| `proposals/archive/2026-04-27-cc5-kernel-boot-shim-regression.md` | 2026-04-27 | 📦 Archive | Closed at v1.24.0 (cyrius 5.7.19 kmode emit-order fix). |

---

## Next sweep targets

1. **`BENCHMARKS.md`** — currently CI-generated artifact, not in repo. Decide whether to also check in the last released numbers as a tagged-state reference (matches what `release.yml` already does) or leave the CI artifact as the only source. Carried forward from v1.27.1.
2. **Eventual archive policy for `development/{kybernet-bridge,security-hardening,syscall-additions}.md`**: each is now flagged as implementation-history reference with a status block, but if any of them drifts again at v1.28.x or later, consider relocating to `archive/` rather than repeatedly bumping headers. The pattern would be: subsumed-by-roadmap → archive with a Resolution-style note. Not actionable yet — all three are still useful in their current form.
3. **Articles / narrative docs**: AGNOS doesn't currently carry `docs/articles/`. If the project earns a narrative arc (e.g., the v1.27.1 SMAP closeout story is publishable), the first-party-documentation pattern for `docs/articles/` + the "Since This Was Written" footer convention would apply. Not a 1.27.x concern.

---

## Forward doc-policy commitments

- **`state.md` is bumped by `scripts/version-bump.sh`** — exercised end-to-end at v1.27.2 (Kernel row, Last-refresh date, Released date all updated by the script with no manual edits). The sed regexes use `#` as delimiter to avoid the ERE-`|`-alternation bug that surfaced at v1.27.1 — see the comment in `scripts/version-bump.sh`.
- **Doc-health is refreshed at minor-closeout**, not on every patch. Patches refresh affected rows only.
- **Issue-doc archive on resolution** — when an issue doc closes, move it into `issue/archive/` with a prepended **Resolution (vX.Y.Z)** section. Never delete; the resolution narrative is the audit trail.
- **Proposals graduate or die** — a proposal that sits in `proposals/` for more than one minor without progress should be either accepted (promote to a roadmap item with an ADR if the decision is non-obvious) or archived with a `Status: rejected` note.
