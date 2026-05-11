---
name: AGNOS Documentation Health
description: Living state of doc currency in the agnos repo — fresh / stale / archive / open-question, refreshed as docs are touched
type: state
---

# Documentation Health — agnos

> **Last refresh**: 2026-05-11 (v1.27.1 cleanup pass — CLAUDE.md split into durable + state.md; README ownership of public reader content; this ledger created) | **Refresh cadence**: when a doc is touched, update its row. Full-tree sweep at minor-version closeouts.
>
> **Scope**: this repo only (`agnos`) — the `docs/` tree plus root-level files (README, CLAUDE.md, CHANGELOG, CONTRIBUTING, SECURITY, LICENSE, VERSION, cyrius.cyml). Sibling-repo docs (kybernet, agnosys, argonaut, agnostik, daimon, libro) are not audited here — each repo carries its own doc-health.md if its size justifies one. Cross-repo Cyrius pin/version drift lives in [`development/state.md`](development/state.md).
>
> **Location**: `docs/doc-health.md` (whole-tree scope) per [first-party-documentation § Development Docs](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md#development-docs-docsdevelopment). **Not** under `docs/development/` — the ledger sweeps the whole tree and the location should match the scope.

This is a **ledger**, not a one-time audit. Rewrite-in-place as docs change. Small repo (13 doc files + 7 root files), so the ledger stays narrow; if `docs/` grows past ~30 files, switch to tier roll-ups like the agnosticos repo's pattern.

---

## At a glance — 2026-05-11 inventory

**20 markdown files total**: 7 root + 13 under `docs/`. Bucket counts after this pass:

| Bucket | Count | What it means |
|---|---|---|
| ✅ **Fresh / refreshed in this audit** | 11 | Touched 2026-05-11: root files (README, CLAUDE.md, CHANGELOG, VERSION-related kernel files), `development/{roadmap,state}.md`, `development/issue/`, this ledger. |
| 🟡 **Stale — refresh in place** | 3 | `docs/development/{kybernet-bridge,security-hardening,syscall-additions}.md` — last touched 2026-04-13 (v1.21.0 cleanup). Pre-date the v1.27.x arc. Need a sweep against the current syscall surface and the kybernet 1.0.2 → 1.2.0 jump. |
| 🟠 **Read-through outstanding** | 1 | `docs/architecture/overview.md` — last touched 2026-04-27 (v1.26.0). Likely accurate but should be re-skimmed against the v1.27.x kernel surface. |
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
| `VERSION` | 2026-05-11 | ✅ Fresh | `1.27.1`. Bumped by `scripts/version-bump.sh`; sole source of truth (cyrius.cyml resolves via `${file:VERSION}`). |

Note: AGNOS doesn't carry `CODE_OF_CONDUCT.md` — should be added at the next root-files cleanup to match first-party requirements.

## Tier 2 — `docs/architecture/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `architecture/overview.md` | 2026-04-27 (v1.26.0) | 🟠 Read-through | Last refresh predates v1.27.0 toolchain bump and v1.27.1 memory-isolation closeout. Skim needed: confirm SMAP/SMEP/KPTI/IOMMU section reflects current state, page-table machinery section reflects per-process PD-copy `i<511` + PDPT[1..3] mirror, mention that `proc_*` fns are x86-only (#ifdef-guarded). |

## Tier 3 — `docs/audit/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `audit/2026-04-13-security-audit.md` | 2026-04-13 | 🔵 Frozen (dated) | Audit report — dated artifact. Findings should be cross-referenced against current code; next audit pass produces a new `YYYY-MM-DD-*.md`, not an edit to this one. |

## Tier 4 — `docs/development/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `development/roadmap.md` | 2026-05-11 | ✅ Fresh | v1.27.1 closeout added `## Completed (v1.27.1)` section; Active table reduced to 4 items (#1 SMP-on-hardware, #2 tagged unions, #3 struct refactor, #7 serial_putc methodology). Header re-synced to `v1.27.1` + `cyrius 5.10.44` via `scripts/version-bump.sh`. |
| `development/state.md` | 2026-05-11 | ✅ Fresh | **Created** in this pass. Live snapshot of version, binary sizes, source rollup, subsystem rollup, syscall surface, sibling pins, test surface, verification hosts. Bump-target for future `version-bump.sh` runs. |
| `development/kybernet-bridge.md` | 2026-04-13 (v1.21.0) | 🟡 Stale | Pre-dates kybernet's 1.0.2 → 1.2.0 jump + the v1.27.x kernel surface. Likely has stale syscall-number references; needs a sweep against the current 26-syscall list. |
| `development/security-hardening.md` | 2026-04-13 (v1.21.0) | 🟡 Stale | The S1–S13 security-hardening track in roadmap.md is mostly Done (only S7 KASLR open). This doc may not reflect that. Needs a sweep — or relocate / archive if roadmap.md has subsumed it. |
| `development/syscall-additions.md` | 2026-04-13 (v1.21.0) | 🟡 Stale | At v1.21.0 the syscall surface was smaller; v1.27.x has 26. Either refresh as the canonical "next syscalls to add" doc, or archive if obsoleted by roadmap.md. |

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
| `proposals/archive/2026-04-27-acpi-identity-map-ceiling.md` | 2026-04-27 | 📦 Archive | Closed at v1.25.0 (`pt_init` extended to cover 0–4 GB). |
| `proposals/archive/2026-04-27-cc5-kernel-boot-shim-regression.md` | 2026-04-27 | 📦 Archive | Closed at v1.24.0 (cyrius 5.7.19 kmode emit-order fix). |

Live `proposals/` directory is empty — no in-flight design drafts.

---

## Next sweep targets

1. **🟡 `development/{kybernet-bridge,security-hardening,syscall-additions}.md`** — date all three to a single refresh pass against the v1.27.x surface. Either bring current or archive into `development/` parent if the content has been subsumed by `roadmap.md`.
2. **🟠 `architecture/overview.md`** — quick read-through, surface drift. Should pick up the v1.27.1 SMAP / `Memory isolation: PASS` note and the per-process page-table v1.25.1 fix details.
3. **Root files gap**: add `CODE_OF_CONDUCT.md` to match first-party-required root files.
4. **`BENCHMARKS.md`** — currently CI-generated artifact, not in repo. Decide whether to also check in the last released numbers as a tagged-state reference (matches what `release.yml` already does) or leave the CI artifact as the only source.

---

## Forward doc-policy commitments

- **`state.md` is bumped by `scripts/version-bump.sh`** going forward. v1.27.2's release post-hook should touch it; if it doesn't, fix the script.
- **Doc-health is refreshed at minor-closeout**, not on every patch. Patches refresh affected rows only.
- **Issue-doc archive on resolution** — when an issue doc closes, move it into `issue/archive/` with a prepended **Resolution (vX.Y.Z)** section. Never delete; the resolution narrative is the audit trail.
- **Proposals graduate or die** — a proposal that sits in `proposals/` for more than one minor without progress should be either accepted (promote to a roadmap item with an ADR if the decision is non-obvious) or archived with a `Status: rejected` note.
