# shakti privilege-model kernel gap — what AGNOS needs for a `sudo` equivalent

**Status:** 🟠 **OPEN — AND THE ASK IS A RULING, NOT CODE.** Re-verified 2026-08-30 against 1.56.54. Both P0s are genuinely absent: `getuid`#15 is still `return 0` (root), there is no uid/gid/cred array in `proc.cyr`, and neither `spawn`#3/#43 nor `execwait`#37 takes a credential argument. ⛔ **What is missing is a DECISION, and the repo's own doctrine leans hard toward declining**: `planning/ipc.md` §Identity says *"No uid/gid anywhere"*, and `proc.cyr` carries a matching guardrail. But doctrine is not an answer to a sibling repo, and none is recorded. ⇒ **If the ruling is "single-user always-root is the end state"**, the close is a doc edit and shakti re-scopes 0.8.x to *Linux + aarch64 only; AGNOS N/A by kernel design*. **If it is "yes"**, this is a LARGE arc (per-proc credentials, a user table, credential arguments on exec) that needs slotting. Either answer unblocks shakti; silence does not. ⚠ Also carried here: the `#75-80` block band's aegis capability gate depends on this same ruling. ⚠ Sub-items have MOVED since filing: P1 caller-supplied argv+envp **shipped** (argv 1.43.x, envp 1.44.19), P2 PTY is **partial** (`#97` band with PTY endowment; no termios), and P3 `getppid` has no syscall but ppid is now readable via `proclist`#99's record.

⛔⛔ **RE-AUDITED 2026-08-31 (1.56.55): EVERY P0 CLAIM ABOVE STILL HOLDS, AND THE COST OF A LATE "YES" HAS RISEN TWICE SINCE FILING.** `getuid`#15 is still literally `if (num == 15) { return 0; }`; `struct Process` is still 22 pure-register fields with no credential and there is no `proc_uid`/`proc_gid`/`proc_cred` array anywhere; `spawn`#3, `spawn_path`#43 and `execwait`#37 still take no credential argument; and no `setuid`/`setgid`/`setgroups` arm exists in a surface that has grown 0-55 → 0-102 since this was filed — 47 syscalls minted without one credential primitive among them. The doctrine is real and matched in two places (`planning/ipc.md`: *"No uid/gid anywhere"*; `proc.cyr`: *"Capability/ownership policy — NOT Unix uid/pgid"*). **And no ruling is recorded anywhere** — a full grep of `docs/` finds only restatements of the open question, never an answer. `roadmap.md` does not carry this item at all.

⭐ **WHAT IS NEW: THE MAGIC-TOKEN PLACEHOLDER IS NOW A TREE-WIDE PATTERN, AND IT EXISTS ONLY BECAUSE THIS RULING IS MISSING.** Two sites now substitute a compile-time constant for the privilege check they would otherwise make, and both say so in their own comments:
- **`syscall.cyr` (`#75-80` block band)** — raw block WRITE is gated only by `BLK_RW_ARM_MAGIC`: *"agnos has no per-proc capability/uid yet … so this default-off + explicit-magic-arm is the boundary … the arm call is the exact seam where an aegis/shakti installer-capability check lands when agnos grows per-proc caps"*, and it concedes *"the token is a compile-time constant any ring-3 process can send. THAT is the deliberate placeholder."*
- **`power.cyr` (reboot)** — *"It is also the privilege gate, deliberately: getuid is hardcoded 0 and there is no uid model, so a uid check would be a gate that is always open … the same shape as blk_rw_armed."*
⇒ A "yes" is now a **larger** arc than this file estimated, because it has two live seams to retrofit rather than a clean slate. A "no" is correspondingly cheaper and should be **written down**, because both comments are currently promissory notes against a decision nobody has made. ⚠ Either answer unblocks shakti and closes the `#75-80` aegis question with it; silence continues to cost.

**Original status:** Filed (informational / **blocks shakti 0.8.x**, does **not** block AGNOS).
**Date**: 2026-06-16
**From**: shakti 0.7.0 (AGNOS privilege-escalation tool — the `sudo`/`doas`
equivalent; PAM auth, TOML policy, capability drop, session logging, LSM
exec contexts on Linux today). Genesis: first-party-standards.
**AGNOS surface at filing**: 1.45.10 — syscalls 0–42 (frozen base + 1.43.x
graphics/timing/input) + the 1.45.x net/entropy/clock band 45–55.
**Affects (if AGNOS chooses to act)**: `kernel/` identity/exec/cred model,
`docs/development/agnos-userland-abi.md`, `docs/development/syscall-additions.md`.
**Related**: [`2026-06-15-cyrius-stdlib-missing-syscalls.md`](2026-06-15-cyrius-stdlib-missing-syscalls.md)
(the cyrius-side POSIX gap map — overlaps the *process/exec* items below;
this doc adds the *privilege/identity* items no cyrius stdlib module needs
but shakti does). `agnos-userland-abi.md` §5 (exec note), decision O5.

## Summary

shakti's roadmap 0.8.x is "AGNOS kernel integration" — re-do the privilege
work-up against AGNOS interfaces. Auditing the 1.45.10 ABI, **none of the
primitives shakti is built on exist on AGNOS**, because AGNOS is by design a
**single-user, always-root** system (`getuid`#15 → `0`, documented "🔧
always root=0 — Single-user system"; there is no `setuid`/`setgid`/
`setgroups` in surface 0–55). A privilege-*de-escalation* tool has nothing
to de-escalate into.

**This does not block AGNOS** — it blocks *shakti on AGNOS*. shakti stays
fully functional on Linux (x86_64 + aarch64). The point of this doc is to
let the AGNOS side decide **if/when** a privilege model is wanted, and to
record exactly what shakti would consume so the design can be shaped with a
real first consumer in mind. If AGNOS intends to remain single-user
indefinitely, shakti-on-AGNOS is simply out of scope and 0.8.x should be
re-scoped to say so — that is a legitimate outcome and an answer to "what
else do we need" (answer: nothing, by design).

## What shakti needs, prioritised

The first two are **foundational** — without them the rest is meaningless,
and shakti-on-AGNOS cannot start. The remainder layer on top and can land
incrementally (shakti already gates each as opt-in on Linux).

| # | Need | shakti use (Linux today) | AGNOS-shaped suggestion |
|---|---|---|---|
| **P0** | **Multi-uid/gid identity model.** Real `getuid`/`getgid` (not always-0), a notion of non-root principals, and supplementary-group membership. | `identity_lookup_*`, `/etc/passwd`+`/etc/group` (ADR-005). | A kernel/userland user table + `getuid`/`getgid` returning real ids. Until this exists, *every* item below is moot. |
| **P0** | **Privilege-scoped exec** — run a target as a *lower* privilege than the caller. | `fork` → `setgroups`→`setgid`→`setuid` → `execve` (return-checked + post-verified; ADR-002). | AGNOS has no `fork`/`setuid`; it uses `spawn`#3 / `execwait`#37. The AGNOS-native shape is **credentialed exec**: `execwait`/`spawn` taking a target `(uid, gid, groups)` so the *kernel* runs the child de-privileged — cleaner than Linux's drop-then-exec and avoids a setuid race. This is the single most important ask. |
| P1 | **Caller-supplied argv + envp on exec.** | `execve(path, argv, envp)` with shakti's sanitised env (ADR-004). | `execwait`#37 today passes no caller argv and stages a fixed `HOME=/ PWD=/` envp. shakti needs to pass the target command's argv and its sanitised environment. **Overlaps the cyrius gap doc's "argv/envp on spawn/execwait" item** — the privilege use-case adds weight to it. |
| P1 | **Authentication primitive** — verify a credential for a principal. | PAM via `unix_chkpwd(8)` + `su` fallback (ADR-006). | A credential store + a verify mechanism (syscall or trusted root-owned helper). Needs P0 identity first. |
| P2 | **Least-privilege / capability model.** | Per-rule `CAP_*` bounding-set drop + ambient raise (ADR-007). | A kernel capability/permission-token model, if AGNOS wants finer-than-uid granularity. Optional; shakti degrades to full-uid drop without it. |
| P2 | **PTY / tty abstraction** — pty master/slave + termios. | Session-logging relay + TIOCSTI isolation for lateral uid moves (ADR-008, ADR-011). | AGNOS has blocking kbd stdin (`read`#5 fd 0) but no pty/termios/`TIOCSTI`. Needed for session recording + tty-injection defence. Optional; both features are opt-in. |
| P3 | **`getppid` (parent-pid).** | shakti reads the parent pid for audit/session lineage; `shakti/lib/process_agnos.cyr:80` hardcodes `getppid()` → `0` on AGNOS (no syscall). | A `getppid` syscall returning the spawning proc's pid. AGNOS already has `getpid`#2 + the parent↔child link in the proc table (`spawn`#3/`waitpid`#4), so surfacing the parent pid is small. Lowest priority — shakti degrades cleanly to `0` today. **Surfaced by the 2026-06-18 cross-repo sweep** as the one unfiled holdout of shakti's agnos asks. |
| P3 | **MAC / exec-context** — mandatory access control labels. | SELinux/AppArmor exec transition via `/proc/self/attr/exec` (ADR-009). | Only if AGNOS grows an LSM-equivalent. Lowest priority; entirely opt-in. |

## Recommendation

If a privilege model is on the AGNOS roadmap, **P0 (identity) + P0
(credentialed exec)** are the gate — shakti-on-AGNOS can begin a Linux-parity
port the moment those land, behind a kernel/ABI seam shakti would add on its
side (roadmap 0.8.x last item). If single-user-always-root is the intended
end state, please say so and shakti will re-scope 0.8.x to "Linux + aarch64
only; AGNOS N/A by kernel design" and close this.

Either answer unblocks shakti's planning — which is the ask.
