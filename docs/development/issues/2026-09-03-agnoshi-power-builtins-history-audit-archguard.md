# agnoshi's three power builtins: no history save, no audit record, no arch guard, and a dead privilege classifier — OPEN

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

## 3. The privilege classifier for these verbs is dead code — P2

`grep -rn is_privileged_command src/ tests/` returns **nothing**, yet `src/permissions.cyr:76-79`
lists `reboot`/`shutdown`/`poweroff`/`halt`. It is a safety control that is inert. `cur_mode` is read
at `:322` and passed to every other launcher, and is not consulted by the power arms.

**Fix:** wire it up **or delete it**. An inert safety control is worse than an absent one, because it
reads as coverage.

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
