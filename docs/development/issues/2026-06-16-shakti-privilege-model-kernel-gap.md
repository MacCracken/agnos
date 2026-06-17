# shakti privilege-model kernel gap — what AGNOS needs for a `sudo` equivalent

**Status**: Filed (informational / **blocks shakti 0.8.x**, does **not** block AGNOS).
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
| P3 | **MAC / exec-context** — mandatory access control labels. | SELinux/AppArmor exec transition via `/proc/self/attr/exec` (ADR-009). | Only if AGNOS grows an LSM-equivalent. Lowest priority; entirely opt-in. |

## Recommendation

If a privilege model is on the AGNOS roadmap, **P0 (identity) + P0
(credentialed exec)** are the gate — shakti-on-AGNOS can begin a Linux-parity
port the moment those land, behind a kernel/ABI seam shakti would add on its
side (roadmap 0.8.x last item). If single-user-always-root is the intended
end state, please say so and shakti will re-scope 0.8.x to "Linux + aarch64
only; AGNOS N/A by kernel design" and close this.

Either answer unblocks shakti's planning — which is the ask.
