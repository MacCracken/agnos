---
name: AGNOS Documentation Health
description: Living state of doc currency in the agnos repo — fresh / stale / archive / open-question, refreshed as docs are touched
type: state
---

# Documentation Health — agnos

> **Last refresh**: 2026-05-26 (v1.35.0 cycle-open full-tree sweep). **The ledger again aged out** — it sat at the 2026-05-18 / v1.30.7 inventory across the entire **1.31.x storage → 1.32.x networking → 1.33.x ext2/4-write → 1.34.x FAT-family** range (5 minor cycles) before this refresh, the exact systemic rot the forward-policy below warns against. This sweep brings README + state.md + roadmap + architecture/overview + syscall-additions + kybernet-bridge to current 1.35.0 state and records `development/build.md` (added at 1.31.0, previously unledgered). **roadmap.md was restructured to forward-facing** (completed arcs removed → CHANGELOG) per a 2026-05-26 user directive. | **Refresh cadence**: when a doc is touched, update its row. Full-tree sweep at minor-version closeouts.
>
> **Scope**: this repo only (`agnos`) — the `docs/` tree plus root-level files (README, CLAUDE.md, CHANGELOG, CONTRIBUTING, SECURITY, LICENSE, VERSION, cyrius.cyml). Sibling-repo docs (kybernet, agnosys, argonaut, agnostik, daimon, libro) are not audited here — each repo carries its own doc-health.md if its size justifies one. Cross-repo Cyrius pin/version drift lives in [`development/state.md`](development/state.md).
>
> **Location**: `docs/doc-health.md` (whole-tree scope) per [first-party-documentation § Development Docs](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md#development-docs-docsdevelopment). **Not** under `docs/development/` — the ledger sweeps the whole tree and the location should match the scope.

This is a **ledger**, not a one-time audit. Rewrite-in-place as docs change. Small repo (13 doc files + 7 root files), so the ledger stays narrow; if `docs/` grows past ~30 files, switch to tier roll-ups like the agnosticos repo's pattern.

---

## At a glance — 2026-05-26 inventory (v1.35.0 cycle open)

**26 tracked files**: 9 root (7 `.md` + `LICENSE` + `VERSION`) + 17 `.md` under `docs/`. Net +1 from the v1.30.7 inventory: `development/build.md` (added at 1.31.0 as part of the production-lean cycle-open; previously unledgered). The 1.31.x → 1.34.x arcs' deliverables are mostly source-side (storage drivers, r8169, ext2/FAT/exFAT modules) — those aren't doc files. Bucket counts after the 2026-05-26 sweep:

| Bucket | Count | What it means |
|---|---|---|
| ✅ **Fresh / refreshed in this sweep** | 10 | Root: README.md (full rewrite to 1.35.0 capability picture), CHANGELOG.md (1.35.0 cycle-open + docs-sweep entry), VERSION (1.35.0), CLAUDE.md (durable-only, no drift), CODE_OF_CONDUCT.md. `docs/`: state.md (body brought forward from frozen 1.31.1), roadmap.md (forward-facing restructure), architecture/overview.md (storage/net/FS + cyrius pin), build.md (flag table completed — all 13 gates), this ledger. |
| 🟡 **Header-refreshed; content confirmed current** | 2 | syscall-additions.md + kybernet-bridge.md — surface (26 syscalls) / design (kybernet 1.2.1 bridge) confirmed unchanged since v1.21.0; headers bumped off the "v1.30.7 cycle" smell. |
| 🟠 **Read-through outstanding** | 1 | `BENCHMARKS.md` (CI-generated; the standing policy decision — checked-in tagged-state reference vs CI-only — never resolved). |
| 🔵 **Probably evergreen** | 3 | `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` — standard, re-read pass annually. |
| 📦 **Archive — frozen by design** | 5 | `docs/development/issue/archive/` (3 files) + `docs/development/proposals/archive/` (2 files). Verified — nothing misclassified. |
| 🟢 **Live (non-archive)** | 2 | `proposals/2026-05-11-kaslr-scope.md` (Option B shipped v1.28.0; Option A deferred cyrius v6.1.x PIE), `issue/2026-05-15-cyrius-nonzero-gvar-init-not-honored.md` (live upstream cyrius bug; agnos `fn`-wrapper workaround durable). |
| ❓ **Open question** | 0 | No live strategic ambiguity. |
| 📄 **Dated audit** | 1 | `audit/2026-04-13-security-audit.md` — frozen dated artifact; next pass produces a new dated file. |

---

## Tier 1 — Root files

| File | Last touched | Status | Notes |
|---|---|---|---|
| `README.md` | 2026-05-26 | ✅ Fresh | **Full rewrite to 1.35.0 (this sweep)**: added a Status line (boots to typeable shell on iron; storage / networking / read+write FS landed); Subsystems table **36+ → 40+** with all storage (NVMe/AHCI/USB-MS/RAM-disk/block-layer/GPT), networking (r8169/IP-ARP-UDP/TCP/DHCP), and FS (ext2/4, FAT12/16/32, exFAT, FS-write guard) rows; fixed xHCI status (iron-validated, not "in flight") + removed the stale FAT16-read-only / VirtIO-Net-only rows; data-flow expanded with the storage/FS/networking stages; Shell 19 → 28 commands; file counts (core 26, usb 9); Size Comparison + Project Map (core/ + usb/ file lists) refreshed. |
| `CHANGELOG.md` | 2026-05-26 | ✅ Fresh | `[1.35.0]` cycle-open header (catchup-tidbits theme) + a `### Changed — full documentation sweep` entry enumerating every doc touched this sweep. Per-arc history for 1.31.x–1.34.x is the at-a-glance ledger the forward-facing roadmap now points back to. |
| `CLAUDE.md` | 2026-05-21 | ✅ Fresh | Durable-only structure; volatile state correctly deferred to state.md. SemVer cut at 0.1.0 noted; no rule drift across the 1.31.x → 1.34.x arcs. |
| `BENCHMARKS.md` | (pre-v1.30) | 🟠 Stale | CI-generated artifact, present in tree. The standing policy decision (last-released numbers as a tagged-state reference vs CI-only) is the longest-running carry-forward in this ledger — still unresolved. |
| `CONTRIBUTING.md` | (pre-v1.27) | 🔵 Evergreen | Standard contribution guide. Re-read on minor closeout. |
| `SECURITY.md` | (pre-v1.27) | 🔵 Evergreen | Reporting policy. Re-read on minor closeout. |
| `LICENSE` | (genesis) | 🔵 Evergreen | GPL-3.0-only verbatim. |
| `VERSION` | 2026-05-26 | ✅ Fresh | **`1.35.0`**. Bumped by `scripts/version-bump.sh` (2026-05-26 cycle-open); sole source of truth (cyrius.cyml resolves via `${file:VERSION}`). |
| `CODE_OF_CONDUCT.md` | 2026-05-11 | ✅ Fresh | Contributor Covenant v2.1 reference. No drift. |

## Tier 2 — `docs/architecture/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `architecture/overview.md` | 2026-05-26 | ✅ Fresh | **Refreshed this sweep**: header to 40+ subsystems + cyrius 6.0.1 + iron-validation status; boot sequence + subsystem diagram + Block-I/O and Networking prose rewritten for the storage stack (5-backend block layer + GPT), the r8169/DHCP networking stack, and read+write filesystems; "FAT16 read-only" retired; shell count 19 → 28. Memory-map table + Process Model SMAP/stac/clac notes left intact (still load-bearing). |

## Tier 3 — `docs/audit/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `audit/2026-04-13-security-audit.md` | 2026-04-13 | 🔵 Frozen (dated) | Audit report — dated artifact. Findings should be cross-referenced against current code; next audit pass produces a new `YYYY-MM-DD-*.md`, not an edit to this one. |

## Tier 4 — `docs/development/`

| File | Last touched | Status | Notes |
|---|---|---|---|
| `development/roadmap.md` | 2026-05-26 | ✅ Fresh | **Restructured to forward-facing this sweep** (per 2026-05-26 user directive): removed the completed "Shipped" arc ledger, the 1.30.x recap, all ✅-closed "Next cycle" rows, and the completed Security-Hardening / Multi-Architecture / Planned tables (history now lives in CHANGELOG). Retained: Current pointer + 1.35.x active theme, the active/near-term table, slotted-future minors (1.37–1.45), deferred items, the platform decade map, and the cyrius-PIE-gated KASLR section. |
| `development/state.md` | 2026-05-26 | ✅ Fresh | **Body brought forward from its frozen 1.31.1 shape this sweep**: Build artifacts (475,096 B → 798,936 B; cyrius 5.11.59 → 6.0.1; per-cut trajectory trimmed to a CHANGELOG pointer), source rollup (66 → 71 files, core 22 → 26, usb 8 → 9), subsystem table (added r8169 / DHCP / USB-MS / RAM-disk / ext2-4 / FAT / exFAT / FS-write-guard rows; fixed multiboot label + AHCI iron status + shell count + 5-backend block layer), In-flight + Recently-closed sections, headline to the 1.35.x catchup-tidbits theme. |
| `development/build.md` | 2026-05-26 | ✅ Fresh | **NEW since the v1.30.7 ledger** (added at 1.31.0). Flag table completed this sweep: was current through the storage arc (`AHCI_RW_DEMO` / `MSC_RW_DEMO` / `RAMDISK_ENABLE`) but missing the 7 networking/FS gates `scripts/build.sh` accreted since — added `NET_VERBOSE` (1.32.x) + `EXT2_WRITE_SELFTEST` (1.33.x) + `FATFS_SELFTEST` / `FATFS_WRITE_SELFTEST` / `EXFAT_SELFTEST` / `EXFAT_WRITE_SELFTEST` / `FAT_ALLOW_ESP_WRITE` (1.34.x), plus FS-selftest enabling examples. All 13 build.sh gates now documented. |
| `development/kybernet-bridge.md` | 2026-05-26 | ✅ Fresh | Header bumped off the "v1.30.7 cycle" smell; design confirmed unchanged since v1.21.0 (kybernet 1.2.1, 26-syscall interface). The `mkdir` "Noop (initrd read-only)" row is still accurate for the initrd-backed PID-1 bridge (disk-backed FS write is a separate kernel layer). |
| `development/security-hardening.md` | 2026-05-18 | ✅ Fresh | Status block at **13 of 13 Done (v1.28.0)**. The S7 Option-A (full PIE-binary KASLR) deferral now lives in roadmap.md § *Full-Binary KASLR* (cyrius v6.1.x PIE track) — content still accurate; no edit needed this sweep. |
| `development/syscall-additions.md` | 2026-05-26 | ✅ Fresh | Header bumped; surface confirmed **still 26** — the 1.31.x–1.34.x storage/networking/FS-write arcs reuse `open`/`write`/`mkdir`/`mount`/`sync`, no new syscalls. |

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

**Sweep status (2026-05-26 v1.35.0 cycle-open sweep)**: README (full rewrite), state.md (body un-freeze), roadmap.md (forward-facing restructure), architecture/overview.md, syscall-additions.md, kybernet-bridge.md all brought current; CHANGELOG + VERSION + this ledger refreshed. Remaining queue:

1. **`BENCHMARKS.md` policy decision** — original v1.27.1 carry-forward; still pending. Decide if last-released numbers get checked in as a tagged-state reference or stay CI-only. The longest-running carry-forward in this ledger.
2. **`development/build.md` read-through** — confirm its compile-gate flag list matches the current `scripts/build.sh` (the 1.34.x arc added `EXFAT_SELFTEST` / `EXFAT_WRITE_SELFTEST` / `FAT_ALLOW_ESP_WRITE`).
3. **`scripts/build.sh` cosmetic banner** — still prints stale `multiboot2 (ELF64): OK` + `Boot: pending shim rewrite` labels; should reference Path C (also tracked as a roadmap near-term item).

---

## Forward doc-policy commitments

- **`state.md` is bumped by `scripts/version-bump.sh`** — exercised end-to-end at v1.27.2 / v1.28.0 / v1.29.0 / v1.30.0 / v1.30.7 (Kernel row, Last-refresh date, Released date updated by the script with no manual edits). The sed regexes use `#` as delimiter to avoid the ERE-`|`-alternation bug that surfaced at v1.27.1.
- **Doc-health is refreshed at minor-closeout, AT LATEST** — the 2026-05-18 audit named this after the ledger aged out across THREE minor releases. **It happened again**: this ledger sat at v1.30.7 across the 1.31.x / 1.32.x / 1.33.x / 1.34.x arcs (FIVE minors) until the 2026-05-26 sweep. The commitment ("touch doc-health on every minor cut, even just a header bump confirming nothing moved") is sound but was not honored — the cut flow runs `version-bump.sh` (which does *not* touch this ledger) and the manual body sweep keeps getting deferred to the next cycle-open. **Practical fix**: fold a doc-health touch into the cycle-OPEN sweep (when the body sweep happens anyway), not the cycle-close, since cycle-opens reliably trigger a docs pass and closes don't.
- **Script-fresh / body-stale gap is now named**: `scripts/version-bump.sh` refreshes the cheap fields (VERSION, kernel/agnos.cyr banner comment, state.md header date + Version-table row, roadmap.md "Current" line). Body prose drifts independently. Doc-health audits at minor-cut must specifically inspect body prose against header dates, not trust matching headers.
- **Issue-doc archive on resolution** — when an issue doc closes, move it into `issue/archive/` with a prepended **Resolution (vX.Y.Z)** section. Never delete; the resolution narrative is the audit trail.
- **Proposals graduate or die** — a proposal that sits in `proposals/` for more than one minor without progress should be either accepted (promote to a roadmap item with an ADR if the decision is non-obvious) or archived with a `Status: rejected` note.
