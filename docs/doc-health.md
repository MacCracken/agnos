---
name: AGNOS Documentation Health
description: Living state of doc currency in the agnos repo — fresh / stale / archive / open-question, refreshed as docs are touched
type: state
---

# Documentation Health — agnos

> **Last refresh**: 2026-05-18 (v1.30.7 cycle open — full-tree sweep after the v1.28.x → v1.29.x → v1.30.x burst. 1.30.x added `kernel/version.cyr` auto-generated banner module (v1.30.2), the Path-C sovereign-struct kernel ABI (v1.30.0), Phase 4/5 USB-HID boot keyboard driver (v1.30.5), the xHCI cmd-path repair arc FF→QQ (v1.30.6 — bundled into one CHANGELOG entry per user 2026-05-18 cycle directive). Doc-tree growth: +1 live issue (`2026-05-15-cyrius-nonzero-gvar-init-not-honored.md` — upstream cyrius bug, surfaced via the v1.30.x sovereign-struct ABI), +1 root file (`BENCHMARKS.md` — closes "Next sweep target #1" carry-forward from v1.27.1). The 2026-05-11 v1.28.4 closeout sweep aged out across THREE minor releases without an intermediate refresh — surfaced as the systemic-rot example in the 2026-05-18 doc-staleness audit and is the motivating case for the new forward-policy commitment below.) | **Refresh cadence**: when a doc is touched, update its row. Full-tree sweep at minor-version closeouts.
>
> **Scope**: this repo only (`agnos`) — the `docs/` tree plus root-level files (README, CLAUDE.md, CHANGELOG, CONTRIBUTING, SECURITY, LICENSE, VERSION, cyrius.cyml). Sibling-repo docs (kybernet, agnosys, argonaut, agnostik, daimon, libro) are not audited here — each repo carries its own doc-health.md if its size justifies one. Cross-repo Cyrius pin/version drift lives in [`development/state.md`](development/state.md).
>
> **Location**: `docs/doc-health.md` (whole-tree scope) per [first-party-documentation § Development Docs](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md#development-docs-docsdevelopment). **Not** under `docs/development/` — the ledger sweeps the whole tree and the location should match the scope.

This is a **ledger**, not a one-time audit. Rewrite-in-place as docs change. Small repo (13 doc files + 7 root files), so the ledger stays narrow; if `docs/` grows past ~30 files, switch to tier roll-ups like the agnosticos repo's pattern.

---

## At a glance — 2026-05-18 inventory (v1.30.7 cycle open)

**25 markdown files total**: 9 root + 16 under `docs/`. Net +3 from the v1.28.4 inventory: +1 live issue (`development/issue/2026-05-15-cyrius-nonzero-gvar-init-not-honored.md`), +1 root file (`BENCHMARKS.md` — added in v1.28.x or v1.29.x; first-recorded here), +1 cross-ref to xhci-prior-art-audit.md (which lives in agnosticos, not agnos — referenced from state.md). The v1.30.x arcs' deliverables are mostly source-side (Path-C boot-info ABI, kernel/version.cyr banner module, xHCI cmd-path Repairs FF→QQ in `kernel/core/pci.cyr` + `arch/x86_64/usb/xhci.cyr`) — those aren't counted here. Bucket counts after the 2026-05-18 sweep:

| Bucket | Count | What it means |
|---|---|---|
| ✅ **Fresh / refreshed in this audit** | 11 | Root: CHANGELOG (just consolidated 1.30.6 + 1.30.7 placeholder), VERSION, CLAUDE.md (durable-only, no drift). `docs/`: state.md (S2 of doc-staleness audit body sync), security-hardening.md (S1: S7 flip to 13/13), this ledger (S3), proposals/2026-05-11-kaslr-scope.md (status tightened — Option B shipped at v1.28.0). |
| 🟡 **Stale — refresh in place** | 6 | README.md (kernel size ~243 KB → ~360 KB drift; CLI lib-doc precedent not applied to "Size Comparison" section), architecture/overview.md (v1.27.x framing; kernel size drift; cyrius pin 5.10.44 → 5.11.59 drift), roadmap.md (script bumped Current line + cyrius pin; body 1.30.x cycle-summary section still missing), kybernet-bridge.md (kybernet pin 1.2.0 → 1.2.1; header v1.27.2 era), syscall-additions.md (header bump only; surface still unchanged at 26), BENCHMARKS.md (CI-generated; needs read-through to confirm it carries last-released numbers as state-reference). |
| 🟠 **Read-through outstanding** | 0 | All `development/` docs have been promoted to either ✅ or 🟡 in this sweep. |
| 🔵 **Probably evergreen** | 3 | `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` — standard, re-read pass annually. |
| 📦 **Archive — frozen by design** | 5 | `docs/development/issue/archive/` (3 files) + `docs/development/proposals/archive/` (2 files). Verified — nothing misclassified. |
| 🟢 **Live (non-archive)** | 2 | `proposals/2026-05-11-kaslr-scope.md` (Option B shipped v1.28.0; Option A deferred cyrius v6.1.x — surface-on-cyrius-PIE-landing), `issue/2026-05-15-cyrius-nonzero-gvar-init-not-honored.md` (live upstream cyrius bug, surfaced via Path-C v1.30.x kernel/version.cyr design — affects choice between `var` globals and `fn` wrapper for banner strings). |
| ❓ **Open question** | 0 | No live strategic ambiguity. |

---

## Tier 1 — Root files

| File | Last touched | Status | Notes |
|---|---|---|---|
| `README.md` | 2026-05-11 | 🟡 Stale | "Size Comparison" section claims `AGNOS \| ~243 KB`; current binary is **368,968 B (~360 KB)** at v1.30.7. Cyrius pin reference may also drift. Recommended refresh: re-anchor binary-size claims to point at `state.md` (lib-doc precedent), or rewrite to current numbers. Lower priority than agnosticos README per the lib-doc-precedent gap analysis in agnosticos doc-health.md. |
| `CHANGELOG.md` | 2026-05-18 | ✅ Fresh | **Just consolidated**: the v1.30.6 entry now bundles the full xHCI cmd-path arc (Repairs FF → QQ across Attempts 56-62) into one comprehensive section; empty `[1.30.7] — 2026-05-18` placeholder added by `scripts/version-bump.sh` to accumulate next-cycle entries. |
| `CLAUDE.md` | 2026-05-14 | ✅ Fresh | Durable-only structure; volatile state correctly deferred to state.md. No drift in rules across the v1.28.x → v1.30.x arcs. |
| `BENCHMARKS.md` | (pre-v1.30) | 🟠 Stale | CI-generated artifact, present in tree. Doc-health "Next sweep target #1" from v1.27.1 — verify whether it carries the last-released numbers as a tagged-state reference or is purely CI-output. |
| `CONTRIBUTING.md` | (pre-v1.27) | 🔵 Evergreen | Standard contribution guide. Re-read on minor closeout. |
| `SECURITY.md` | (pre-v1.27) | 🔵 Evergreen | Reporting policy. Re-read on minor closeout. |
| `LICENSE` | (genesis) | 🔵 Evergreen | GPL-3.0-only verbatim. |
| `VERSION` | 2026-05-18 | ✅ Fresh | **`1.30.7`**. Bumped by `scripts/version-bump.sh` (2026-05-18, post-1.30.6 tag); sole source of truth (cyrius.cyml resolves via `${file:VERSION}`). |
| `CODE_OF_CONDUCT.md` | 2026-05-11 | ✅ Fresh | Contributor Covenant v2.1 reference. No drift. |

## Tier 2 — `docs/architecture/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `architecture/overview.md` | 2026-05-11 | 🟡 Stale | Header still says "Built with cyrius 5.10.44" + "v1.27.2 closeout"; current pin is **5.11.59**, kernel is **v1.30.7**. Body claims "Kernel code + data (~248 KB x86_64 at v1.27.1)" — actual ~360 KB. Memory-map table itself still accurate (0–4 GB ceiling + IOMMU window). Process Model section's SMAP/stac/clac note still load-bearing. Recommended: bump header + kernel-size pointer (defer to state.md); leave memory-map + SMAP notes intact. |

## Tier 3 — `docs/audit/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `audit/2026-04-13-security-audit.md` | 2026-04-13 | 🔵 Frozen (dated) | Audit report — dated artifact. Findings should be cross-referenced against current code; next audit pass produces a new `YYYY-MM-DD-*.md`, not an edit to this one. |

## Tier 4 — `docs/development/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `development/roadmap.md` | 2026-05-18 | 🟡 Stale | Header `Current: v1.30.7` + `cyrius 5.11.59` bumped fresh by `scripts/version-bump.sh`, but the body still carries the v1.27.2-era **`## 1.28.x Arc Plan`** framing and Active items like "iron Attempt 5" (actual Attempt 62 staged today). The 1.30.x arcs (sovereign-struct ABI, USB-HID Phase 4/5, xHCI cmd-path FF→QQ) need a cycle-summary insertion. The script-fresh/body-stale gap is the systemic pattern flagged in the 2026-05-18 doc-staleness audit. |
| `development/state.md` | 2026-05-18 | ✅ Fresh | **Just rewritten in S2** of the 2026-05-18 doc-staleness audit: Open Investigation section superseded (v1.30.x scheduler-under-UEFI hypothesis class resolved by 2026-05-15 iron-validation; current open investigation is xHCI Enable Slot CCE silent-absorb), Build artifacts table extended through v1.30.7 (368,968 B / 93,640 B), Cyrius pin corrected 5.11.53 → 5.11.59, ecosystem block updated for single-pin-stack retirement, In-flight + Recently closed tables updated for the v1.30.x arcs, "What changed at v1.27.1" repurposed as "What changed at v1.30.6/.7". |
| `development/kybernet-bridge.md` | 2026-05-11 | 🟡 Stale | Header "kybernet's 1.0.2 → 1.2.0 jump" — current kybernet is **1.2.1** (BOOT_MINIMAL agnoshi addition 2026-05-11 eve). AGNOS 26-syscall interface unchanged. Header bump + pin tick only. |
| `development/security-hardening.md` | 2026-05-18 | ✅ Fresh | **Just refreshed in S1** of the 2026-05-18 doc-staleness audit: Status block flipped from "12 of 13 — only S7 open" to **"13 of 13 Done as of v1.28.0"**. S7 row marked ✅ Done with the Option-B/Option-A split (data-only KASLR shipped via RDRAND-seeded `pmm_next_free` randomization; full PIE-binary KASLR deferred cyrius v6.1.x). S7 deep-dive section rewritten to reflect actual shipped surface. |
| `development/syscall-additions.md` | 2026-05-11 | 🟠 Stale | Header bump needed (v1.27.2 → v1.30.7). Surface unchanged at 26 syscalls across v1.27.x → v1.30.x — no new syscalls in the bring-up / correctness arc. Single-line edit. |

## Tier 5 — `docs/development/issue/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `issue/2026-05-15-cyrius-nonzero-gvar-init-not-honored.md` | 2026-05-15 | 🟢 Live | **NEW since v1.28.4 sweep**. Upstream cyrius bug surfaced via the v1.30.x Path-C kernel/version.cyr design — kmode `var` globals with non-zero initializers don't honor those initializers because PARSE_PROG runs before EMIT_GVAR_INITS, so the kernel program body executes before globals get their non-zero values. Worked around in agnos by wrapping banner literals in `fn` bodies (rodata pointer baked in at compile time, no runtime init dependency). Upstream fix is a cyrius v5.12.x+ concern; agnos workaround is durable. |
| `issue/archive/2026-04-27-serial-putc-cc5-regression.md` | 2026-05-11 | 📦 Archive | **Closed at v1.28.1**. Resolution section (matched-conditions re-measurement under cyrius 5.10.44 / QEMU 11.0 / Ryzen 7 5800H / TCG; bench delta table showing cc5 broadly equal-or-better than cc3; `serial_putc` outlier explained by QEMU UART-emulation latency, not codegen) prepended to the original body. Frozen. |
| `issue/archive/2026-04-27-memory-isolation-deep.md` | 2026-05-11 | 📦 Archive | **Closed at v1.27.1**. Resolution section (SMAP root cause + observation-to-mechanism table + process note on the hypothesis class that misled triage) prepended to the original body. Frozen — refer back but do not edit. |
| `issue/archive/2026-04-27-cr3-load-helper.md` | 2026-05-11 | 📦 Archive | Closed alongside the memory-isolation fix at v1.27.1 — the v1.26.0 helper was a real fix, just not the whole one. |
| `issue/archive/2026-04-27-cyrius-fmt-tracks-braces-in-comments.md` | 2026-04-27 | 📦 Archive | Closed at v1.26.1 (cyrius 5.7.22 fmt fix). Frozen. |

## Tier 6 — `docs/development/proposals/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `proposals/2026-05-11-kaslr-scope.md` | 2026-05-18 | 🟢 Live | Option B (data-only) **shipped at v1.28.0** — `pmm_next_free` randomization, RDRAND-seeded entropy, sign-mask hygiene, memory-isolation phys-move. Option A (full PIE binary KASLR) deferred to cyrius v6.1.x where PIE codegen lands. The proposal stays live (not archived) because Option A is a real future candidate; archival when full KASLR ships or is permanently retired. Status section confirmed via S1 of the 2026-05-18 doc-staleness audit (security-hardening.md S7 deep-dive section now references this proposal explicitly). |
| `proposals/archive/2026-04-27-acpi-identity-map-ceiling.md` | 2026-04-27 | 📦 Archive | Closed at v1.25.0 (`pt_init` extended to cover 0–4 GB). |
| `proposals/archive/2026-04-27-cc5-kernel-boot-shim-regression.md` | 2026-04-27 | 📦 Archive | Closed at v1.24.0 (cyrius 5.7.19 kmode emit-order fix). |

---

## Next sweep targets

1. **`development/roadmap.md` 1.30.x cycle-summary insertion** — script bumped the Current line + cyrius pin, but the body's Active table still references v1.27.2-era "1.28.x Arc Plan" and Attempt 5. Insert a `## 1.30.x Arc` section covering: Path-C sovereign-struct ABI (v1.30.0), Phase 4/5 USB-HID (v1.30.5), xHCI cmd-path arc FF→QQ (v1.30.6), and the iron-validation milestone (2026-05-15). **Highest-priority remaining stale doc post-S2/S3 sweep.**
2. **`README.md` size + cyrius-pin refresh** — lib-doc precedent application (delete embedded "~243 KB" claim, point at state.md for binary size). Mirror the agnosticos lib-doc-precedent sweep that lands in agnosticos doc-staleness audit S4.
3. **`architecture/overview.md`** — header bump (cyrius 5.10.44 → 5.11.59, v1.27.2 → v1.30.7) + kernel-size pointer. Memory-map + SMAP notes stay.
4. **`kybernet-bridge.md`** — kybernet pin 1.2.0 → 1.2.1 single-line bump.
5. **`syscall-additions.md`** — header bump only; surface unchanged across v1.27.x → v1.30.x.
6. **`BENCHMARKS.md` policy decision** — original v1.27.1 carry-forward target; still pending. Decide if state-reference numbers get checked in or stay CI-only.

---

## Forward doc-policy commitments

- **`state.md` is bumped by `scripts/version-bump.sh`** — exercised end-to-end at v1.27.2 / v1.28.0 / v1.29.0 / v1.30.0 / v1.30.7 (Kernel row, Last-refresh date, Released date updated by the script with no manual edits). The sed regexes use `#` as delimiter to avoid the ERE-`|`-alternation bug that surfaced at v1.27.1.
- **Doc-health is refreshed at minor-closeout, AT LATEST** — the 2026-05-18 audit surfaced that this ledger aged out across THREE minor releases (v1.29.x + v1.30.x) without being refreshed. **New commitment**: doc-health.md MUST be touched on every minor-version cut, even if the only change is a "Last refresh" header bump confirming nothing else moved. The next minor-cut (v1.31.0 or v1.30.8 if a same-minor patch series opens) must refresh this ledger atomically with the version bump.
- **Script-fresh / body-stale gap is now named**: `scripts/version-bump.sh` refreshes the cheap fields (VERSION, kernel/agnos.cyr banner comment, state.md header date + Version-table row, roadmap.md "Current" line). Body prose drifts independently. Doc-health audits at minor-cut must specifically inspect body prose against header dates, not trust matching headers.
- **Issue-doc archive on resolution** — when an issue doc closes, move it into `issue/archive/` with a prepended **Resolution (vX.Y.Z)** section. Never delete; the resolution narrative is the audit trail.
- **Proposals graduate or die** — a proposal that sits in `proposals/` for more than one minor without progress should be either accepted (promote to a roadmap item with an ADR if the decision is non-obvious) or archived with a `Status: rejected` note.
