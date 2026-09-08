# agnoshi's three power builtins: no history save, no audit record, no arch guard — RESOLVED

**Status:** RESOLVED in **agnoshi 1.9.11** (2026-09-08), alongside agnos 1.57.1. Fixed **in agnoshi**,
not from the agnos tree — cross-repo means switching repos, which is what was done.

| # | Item | Outcome |
|---|------|---------|
| 1 | power builtins discard session history | **FIXED** — saved before the syscall, via one helper so the three sites cannot drift |
| 2 | no audit record for the three verbs | **FIXED** — `audit_exec_ctx(verb, "launched", …)`, ordered *before* the history save |
| 3 | "dead privilege classifier" | ⛔ **THE ITEM WAS WRONG** — see the correction below. A policy question survives; it needs a ruling |
| 4 | raw `syscall(13,…)` not arch-guarded | **FIXED** — and the banners that advertised the verbs on host builds too |
| 5 | stale "wrapper not yet widened" comment | **FIXED** — and it turned out to be pointing at a real hazard |
| 6a | verbs absent from the `-c` one-shot path | **FIXED** — `agnsh -c "poweroff"` is now a power operation |
| 6b | shutdown-smoke should assert the agnsh half | 🟠 **UNBLOCKED BUT NOT DONE** — needs a sudo mount; see below |

**VERIFIED, not asserted:** the host binary now carries **zero** of the three `syscall(13,…)` sites
(it carried three) while the agnos target keeps all three; `./build/agnsh -c "poweroff"` on the host
prints `power control is AGNOS-only`; `cyrius test` 26/26.

⛔ **ITEM 5 WAS POINTING AT A LIVE HAZARD, AND THE "FIX" IT INVITED IS THE DANGEROUS ONE.**
`sys_reboot` has **different arity per target**: `lib/syscalls_linux_common.cyr` is
`sys_reboot(cmd)` — one argument, hardcoding the REAL `LINUX_REBOOT_MAGIC1/2` — while the agnos peer
is `sys_reboot(magic1, magic2, cmd, arg)`. A 4-arg call cannot compile on host; "fixing" that by
adopting the host's 1-arg form would fire genuine `0xFEE1DEAD` at Linux `SYS_REBOOT` and **actually
reboot a developer's workstation** under `CAP_SYS_BOOT`. Today's unguarded call was inert on host
only **by accident** (Linux #13 is `rt_sigaction`). The comment now says all of this; the migration
was NOT performed.

🟠 **6b — WHY IT IS STILL OPEN, AND IT IS NOT A DEFERRAL OF CONVENIENCE.** The sequencing trap is
now half-cleared: 6a has landed, so the verbs *can* be driven non-interactively. What remains is that
asserting the two new records means reading `/var/log`-equivalent state **out of the guest image
after shutdown**, and `shutdown-smoke.sh` only ever runs `dumpe2fs`/`e2fsck` against the image — it
does not mount it. A mount needs **sudo**, which makes this the same shape as the exFAT seeded-lane
question already awaiting an operator ruling: does the release sweep acquire a sudo-capable lane, or
is a visible SKIP the accepted answer? ⛔ Until that is ruled, an assertion written here would either
require sudo in the sweep or be a silent skip — and a silent skip is the exact class this repo keeps
paying for.


**Status:** OPEN — **agnoshi-side work, filed from agnos.** Cross-repo work means switching repos,
not blurring boundaries (CLAUDE.md), so nothing here was edited from this tree.

**Discovered:** 2026-09-03, during the shutdown/reboot review that followed the archaemenid iron burn
of agnos 1.56.60 ("`halt` doesn't shutdown completely"). The kernel half of that report is fixed in
agnos 1.56.60; these are the agnoshi-side findings from the same review, which the operator asked to
cover explicitly ("review of shutdown for both emergency shell and agnoshi").

**agnoshi commit reviewed:** working tree at `/home/macro/Repos/agnoshi`, cyrius pin 6.5.36
(`cyrius.cyml:7`).

---

## What is NOT wrong — record this first

`reboot` and `poweroff` in agnsh are **correct and iron-validated**, and `halt` is **correct by
recorded decision**. All three live in `interactive_loop` at `src/agnsh.cyr:348-362` and issue a raw
`syscall(13, 0x50575231, 0x50575232, cmd, 0)`; the kernel arm is `core/syscall.cyr:8661-8667` →
`power_sys`. `halt` (cmd 1) reaching `arch_halt` with the box still powered is the DESIGN —
`src/commands.cyr:36` "Stop the machine without powering off", matching Linux
`LINUX_REBOOT_CMD_HALT` — and is not to be redefined. ⛔ Do not "fix" cmd 1 to power off.

The one operator-facing wrinkle that IS real and is **not** a code defect: unlike Linux's halt, this
one tears down USB first (`power.cyr:141` → `xhci_stop`), so the box cannot be interacted with
afterwards either. That is a naming/expectation problem, not a behavioural bug.

---

## 1. The power builtins discard the session's command history — P2

`CommandHistory_save` has exactly ONE reachable call site, `src/agnsh.cyr:521`, **after** the
interactive loop. The three power arms `continue` (`:351`, `:356`, `:361`) and the syscall does not
return on success, so the loop never exits and the save never runs. Every command typed in a session
ended by `reboot`/`poweroff`/`halt` is lost — which is the session you most want a record of.

⚠ The second call site at `src/session.cyr:99` is **DEAD**: `cyrius.cyml:11` sets
`entry = "src/agnsh.cyr"` and that file's include list (`:5-46`) contains neither `src/session.cyr`
nor `src/main.cyr`. `src/agnsh.cyr:24-26` says as much about `src/ui.cyr`. Do not "fix" this by
relying on the session.cyr path.

**Fix:** call `CommandHistory_save` before each `syscall(13, ...)`.

## 2. No audit record is written for the three verbs that end the machine — P2

There is no audit call anywhere in `src/agnsh.cyr:348-362`. Contrast `src/run_agnos.cyr:198-202`,
whose own comment says a launch record exists **precisely because** reboot/poweroff/halt take the
machine down.

⚠ `AuditLogger_log` (`src/audit.cyr:99-131`) is write-through per event, so a record emitted BEFORE
the syscall survives the shutdown. The unmatched-"launched" shape that `run_agnos.cyr` already
documents is exactly right for a call that does not return.

**Fix:** `audit_exec_ctx(..., "launched", ...)` before each `syscall(13, ...)`.

## 3. ⛔ CORRECTED 1.57.1 — THIS ITEM WAS WRONG, AND ACTING ON IT WOULD HAVE CAUSED A REGRESSION

**What this section originally said:** *"`grep -rn is_privileged_command src/ tests/` returns nothing,
yet `src/permissions.cyr:76-79` lists reboot/shutdown/poweroff/halt. It is a safety control that is
inert. Fix: wire it up **or delete it**."*

⛔ **THAT NAME NEVER EXISTED.** `is_privileged_command` has no definition and no caller anywhere in
agnoshi — the grep returned nothing because the symbol is invented, not because a control is dead.
The real classifier is **`is_admin_command`** (`src/permissions.cyr:56`), and it is **FULLY LIVE**:
called from `analyze_command_permission` (`:195`), reached from `approval.cyr` and `translate.cyr`,
and directly asserted by the test suite.

⛔ **THE DANGER THIS TEXT CREATED, which is why it is corrected in place rather than quietly edited:**
the next reader would either dismiss the whole issue as stale, or act on its authority and **delete
the power-verb entries at `permissions.cyr:76-79`** — silently downgrading `reboot`/`shutdown`/
`poweroff`/`halt` from ADMIN to the USER_WRITE fallthrough on the NL and approval paths that *do*
classify them. A genuine safety regression, invited by a mistaken issue file.

**The residual real gap, restated correctly:** the three power builtins are matched by exact `streq`
in `interactive_loop` **before** any classification runs, so a literally-typed `poweroff` never
reaches `is_admin_command` at all. Only the NL/approval paths classify it.

⚠ **That is a POLICY question, not a dead-code cleanup** — should a literally-typed power verb
require a mode confirm the way `run /bin/foo` does? Both readings are defensible (it is strictly more
destructive than launching a program; but an explicitly typed verb is already unambiguous intent, and
a reflexive confirm trains people to hit "y"). **Needs an operator ruling. Do not "fix" it either way
from a triage.**

## 4. The three raw `syscall(13, ...)` sites are not arch-guarded — P3

`src/agnsh.cyr:348-362` sits outside any `#ifdef` (the nearest guards close at `:301`/`:304`).
Disassembly of `build/agnsh` at `0x437908` / `0x437978` / `0x4379e8` shows the identical
`mov $0xd,%eax ... syscall`. **On x86-64 Linux, syscall 13 is `rt_sigaction`** — so a host build of
agnsh emits a raw Linux syscall, and because the return is discarded (`:349`/`:354`/`:359`) the
failure is invisible. `docs/development/agnos-userland-abi.md` §0 decision **O5** exists to prevent
exactly this shape.

**Fix:** wrap in `#ifdef CYRIUS_TARGET_AGNOS` with an `#ifndef` arm printing "power control is
AGNOS-only", matching the existing pattern at `src/agnsh.cyr:299-304`.

## 5. Follow-up: the stale "wrapper not yet widened" comment — P3

`src/agnsh.cyr:340-347` reads "A cyrius issue is filed to widen the wrapper; until it lands this is
the correct call shape". **The wrapper landed.** Verified 2026-09-03 against the cyrius repo itself:
`cyrius/lib/syscalls_x86_64_agnos.cyr:745-756` exports `PWR_MAGIC1`/`PWR_MAGIC2`/`PWR_HALT`/
`PWR_OFF`/`PWR_REBOOT` and `fn sys_reboot(magic1, magic2, cmd, arg): i64`, annotated
`CHANGELOG [6.4.68]`.

⚠ **Verify against cyrius, never a sibling's vendored `lib/`** — any `cyrius build` in a sibling
rewrites that sibling's vendored `lib/` to the ACTIVE toolchain, so a vendored copy proves what is
*installed*, not what cyrius *shipped*.

⛔ **Do not fold the migration into the same change as items 1-4.** The raw call shape is the
IRON-VALIDATED one; moving to `sys_reboot()` must verify the emitted register order first rather than
assuming it matches. See `docs/development/issues/archived/2026-07-19-sys-reboot-nullary-vs-agnos-4arg-abi.md`.

---

## Gate gap that goes with this

**No test exercises agnsh's `poweroff`/`reboot`/`halt` builtins at all in a default run.**
`scripts/smoke/shutdown-smoke.sh`'s default verb is `exit`, and the three builtins are absent from
the `-c` one-shot path (`src/agnsh.cyr:575-620`), so they cannot even be scripted. The agnos-side
smoke can drive them via `SHUTDOWN_SMOKE_VERB=poweroff|reboot`, but that only proves the KERNEL half.
