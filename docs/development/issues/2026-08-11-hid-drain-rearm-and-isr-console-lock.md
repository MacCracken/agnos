# HID input path — three defects found while explaining a log line at the shell prompt

**Found**: 2026-08-11, investigating an operator report of a "mouse notification on the shell."
**Status:** 🟠 **OPEN — #1/#2 FIXED AND MEASURED. #3's two 1.56.56 defects ARE fixed in the tree, but its
Reset-Endpoint / Set-TR-Dequeue body HAS STILL NEVER EXECUTED — and it is worse than "no stall has happened".**

⛔⛔ **NO IN-TREE BUILD CAN EVEN SET THE FLAG.** Re-derived 2026-09-02 at 1.56.59: the shipped
`HID_CC_INJECT` block forces `ccode = 2` and its own comment calls that "NOT a halting code"
(`hid.cyr:1177`), while `hid_ep_needs_reset` is set only for 4/6/8 (`hid.cyr:1189-1192`). So the
"proven reachable" evidence at `hid.cyr:1016-1017` rests on a **hand-modified build this tree does not
contain**, and that in-code comment — which reads as if `HID_CC_INJECT=1` does it — will send the next
author to run a flag that provably cannot reach the code they are testing. They will read the silence
as "no stall occurred". That is a trap, not a stale line.

⛔ **THE 1.56.58 IRON SLOT PASSED WITHOUT THE BURN.** That CHANGELOG section carries no HID entry, so
the gate is **UNSLOTTED at 1.56.59**, not scheduled. This file said "roadmapped for 1.56.58".

⭐ **THREE RESIDUALS ARE ACTIONABLE IN-TREE, AND NONE IS THE WITHDRAWN STUB SEAM:**
1. ✅ **THE SILENT EARLY-OUT — CLOSED AT 1.56.59. THE BURN NOW HAS AN ORACLE.** `hid_recover_halted`
   cleared `hid_ep_needs_reset` before the EP-state check with no else branch, so a provoked halt whose
   state read came back non-Halted left **zero trace** — and "no stall reached us" and "a stall did and
   recovery declined" were the same silence, with the second reading as a pass.
   * The EP state is now read once into a local so the branch that declines can report **what the
     controller actually answered**, and an `else` branch prints it.
   * Three counters — `hid_halt_flagged` / `_confirmed` / `_declined` — make the three outcomes
     distinguishable from the console alone. ⚠ **Counters, not a log line, at the flag-set site**: that
     runs in `hid_poll`, which the 100 Hz timer ISR calls, so `kprint` is forbidden (`console_spin_lock`
     is non-recursive) and even `klug_append` would mutate the ring head outside that lock and could
     garble a concurrent line. A plain integer add has neither problem. **The ISR counts; thread context
     reports.**
   * ⭐ **REACHABLE IN-TREE FOR THE FIRST TIME** via a new `HID_CC_INJECT_HALT=1` build flag, which
     injects **6 (Stall)** — a halting code — where the existing `HID_CC_INJECT` injects the
     deliberately non-halting 2 and therefore never set the flag at all.
   * ⛔ **THIS IS NOT THE STUB SEAM WITHDRAWN AT 1.56.57.** Nothing fabricates the controller's verdict:
     `xhci_ep_state()` still reads the real Output EP Context, QEMU's controller never halted, and so
     recovery **correctly declines** — which is exactly the branch being proven. It proves the ORACLE,
     not the Reset/Set-TR-Dequeue sequence, which has still never executed anywhere.
   * **Measured on a live boot** (`scripts/harness/hid-halt-oracle-test.py`, keystrokes driven through
     the QEMU monitor because `usb-kbd` emits no completion until a key is pressed):
     `hid: endpoint flagged HALTED but the controller reports EP state 0 -- recovery DECLINED, input
     from it stays dead (flagged/confirmed/declined 3/0/1)`
   * ⚠ **THE GATE CAUGHT ITSELF BEING VACUOUS, AND THE FIX IS RECORDED BECAUSE IT IS THE POINT.** Its
     first precondition keyed on the SAME string it asserts, so deleting the decline line made it SKIP
     instead of FAIL — the oracle derived from the artifact under test, the V5 shape, inside the gate
     written to prove an oracle. It now keys on a separate `HALT INJECTION ARMED` banner, and is
     mutation-proven: removing the decline line yields **exit 1**, not a skip.
   * ⇒ **The burn is now worth slotting.** It was not before.
2. **The 1.56.56 locking fix moved only the WRITE side.** `hid.cyr:1045-1046` still read
   `hid_row_idx`/`hid_row_cycle` as two UNLOCKED loads from thread context, while the ISR's wrap resets
   idx to 0 and flips cycle in the same breath (`hid.cyr:148-149`, `:890-905`) — an interleaving hands
   `xhci_cmd_set_tr_dequeue` a torn (idx, cycle) pair and the endpoint stays dead.
3. **The gate covers less than this file claims.** `hid_reclaim_selftest` registers a MOUSE row
   (`hid.cyr:1303`) and asserts owed==1 (`:1332-1350`). The 1.56.56 fix owes **16** on what is in
   practice a KEYBOARD row, so neither the owed==16 loop nor the KBD branch is exercised anywhere.

✅ **FIXED 1.56.56 — both defects, by one change.** `hid_recover_halted` no longer arms inline. It bumps
`hid_ep_rearm[i]` by **16** and lets `hid_service_rearms` do the ring work under `hid_poll_lock`:
- **Depth** — it called `hid_row_arm(i)` once, and that arms a SINGLE TRB on either branch, so recovery
  restored a **1-deep** ring against this file`s own rule (*"a 1-deep interrupt-IN ring goes empty the
  moment polling pauses and the EP stalls"*). Both init paths arm 16; recovery now owes 16.
- **Locking** — it armed from THREAD context with interrupts enabled, which the reclaim banner forbids
  in the imperative (*"the waiter only bumps a counter, and hid_service_rearms does the ring work under
  hid_poll_lock"*). It was the one thread-context arm site ignoring the rule the rest of the file keeps.
  ⛔ Taking the lock inline instead was rejected: it would be held across two `xhci_cmd_wait` spins in a
  path the 100 Hz tick also takes — a new hazard, not a smaller one.
⚠ **Cost, named:** input resumes on the next `hid_poll` rather than instantly — ≤10 ms via the tick,
which is the guarantee the counter`s contract already states. The success message deliberately keeps its
wording and byte length.

⛔⛔ **AND IT SHIPPED WITHOUT A GATE. SAYING SO IS THE POINT.** `hid_recover_halted`s body is behind
`if (xhci_ep_state(slot, dci) == XHCI_EP_STATE_HALTED)`, and a software-fabricated completion code never
makes the controller halt — so the body early-outs and **none of this executed before the change or
after it.** What IS covered: the mechanism the fix now depends on. `hid-reclaim-smoke.sh` (in `sweep.sh`)
exercises `hid_ep_rearm` → `hid_service_rearms` → arm + doorbell and passes.
⛔ **The obvious cheap gate was considered and REJECTED as one that cannot fail**: extracting the arm
into a helper and calling it from a selftest would gate the arithmetic but not the WIRING — reverting
`hid_recover_halted` to `hid_row_arm(i)` would leave such a gate GREEN, because it never calls the real
function. That is precisely the failure mode this repo has spent three cuts removing.
⛔⛔ **AND THE FIX THIS RECORD PREVIOUSLY PROPOSED — A BUILD-GATED SEAM STUBBING THE THREE HARDWARE
CALLS — IS WITHDRAWN AS THE WRONG INSTINCT. Struck 2026-09-01 on an operator correction.** It read:
*"a real gate needs a build-gated seam stubbing `xhci_ep_state`s verdict, Reset Endpoint and Set TR
Dequeue so a selftest can drive the REAL hid_recover_halted."* ⇒ **That would have proven the stub, not
the kernel.** This repo`s first rule is that only a boot verifies kernel correctness, and the failing
path here is a REAL xHCI endpoint halt on real silicon — faking the controller to test the code that
talks to the controller inverts the whole point.
⭐ **AND THE HARDWARE IS NOT SCARCE — THE BUILD HOST *IS* THE TARGET.** archaemenid carries two AMD
Renoir/Cezanne xHCI controllers (`04:00.3`, `04:00.4`), the exact silicon this code drives. The
constraint was never "no hardware"; it was that the 2026-08-30 burn happened not to stall. An endpoint
halt is PROVOKABLE on real USB — a device pulled mid-transfer, a device that STALLs its interrupt-IN
endpoint, a port reset under load — and provoking one is a burn procedure, not a kernel change.
⇒ **The gate belongs on iron, and is roadmapped for 1.56.58.** What this code still needs is a burn
with a real device and a deliberate stall, reading the markers `hid_recover_halted` already emits.
⚠ Nothing about the 1.56.56 FIX is in doubt — it is correct code in a path that has not executed. What
was wrong was the plan for proving it.

**Earlier status (1.56.55, when the two defects were found):**

⛔ **`hid_recover_halted` RE-ARMS THE RECOVERED ENDPOINT TO DEPTH 1, against this file's own stall warning.** `hid.cyr:1046` calls `hid_row_arm(i)` exactly once, and `hid_row_arm` arms a single TRB on either arm (`hid_arm_xfer_trb()` for a keyboard row, `hid_arm_row_trb(i)` otherwise). `hid.cyr:137-138` states the rule this breaks: *"The 16-deep batch discipline the keyboard needs applies here too — a 1-deep interrupt-IN ring goes empty the moment polling pauses and the EP stalls."* ⇒ **The recovery path recovers into the condition that produces stalls** — `#2`'s defect, which this issue already fixed once on the init path, reappearing on the path that runs *after* a stall.

⛔ **AND IT ARMS FROM THREAD CONTEXT WITHOUT `hid_poll_lock`.** `hid_recover_halted` (`hid.cyr:1020-1058`) takes no lock and mutates row producer state through `hid_row_arm`. `hid.cyr:222-228` is explicit that this is what must not happen: *"Arming from the waiter would let the ISR interrupt `hid_arm_row_trb` mid-update and corrupt `hid_ep_idx`/`hid_ep_cycle` — trading a slow leak for ring corruption. So the waiter only bumps a counter, and `hid_service_rearms` does the ring work under `hid_poll_lock`."* `hid.cyr:1153` confirms the context (*"they cannot run here in ISR context — flag the row and let `hid_recover_halted()` do it"*). ⇒ Recovery should defer through `hid_service_rearms` like every other thread-context arm site, not arm inline.

⚠ **BOTH ARE UNREACHABLE TODAY FOR THE SAME REASON `#3` IS** — the body early-outs before issuing a command because no real stall has ever occurred — so neither is a live bug in any shipped boot. They are what a genuine stall will execute the first time one happens, which is why they are worth fixing *before* that rather than after.

⚠ **DOWNGRADE THE BLOCKER.** This header said `#3` needs *"a genuine hardware stall or controller-level fault injection agnos does not have."* The second half is too strong: `hid_reclaim_selftest` (`hid.cyr:1245-1381`) is an existing hermetic in-kernel harness over the same ring arithmetic, and the two defects above are **statically checkable against the source** — neither needed a stall to find. What still genuinely needs hardware is only the Reset-Endpoint / Set-TR-Dequeue **semantics**.

**Earlier status (2026-08-30):** `hid_recover_halted`'s Reset-Endpoint / Set-TR-Dequeue pair remains unexercised anywhere: an injected completion code is fabricated in software, so the controller never actually halts, `xhci_ep_state()` reports Running, and the body early-outs. ⭐ **1.56.52 CHANGED THAT CODE, so what a future stall will exercise is no longer what was reviewed here**: it was reading `hid_ep_idx`/`hid_ep_cycle` on a KEYBOARD row, which are a decoy that reads 0/1 forever, and now routes through `hid_row_idx`/`hid_row_cycle`/`hid_row_arm`. The same cut added the stolen-event reclaim on the three synchronous xHCI waiters. ⚠ The 2026-08-30 iron burn ran a real composite keyboard for a whole interactive session with **no** stall, so it did not exercise this either. Still blocked on a genuine hardware stall or controller-level fault injection agnos does not have.

**Original status:** **#1 and #2 FIXED and MEASURED 2026-08-11; #3 added but its reset sequence is unvalidated.**
**Kernel at time of finding**: 1.56.43.

> **How they were proven** — neither fix was accepted on "it compiles":
> - **#2 (re-arm)**: `HID_CC_INJECT=1` forces the first 20 completions to a non-halting Data Buffer
>   Error, more than the 16 TRBs armed at init. **With** the fix the keyboard recovers and the shell
>   answers; **with the pre-fix gating restored as a control**, input is dead for the rest of the boot.
>   The control is what makes it a measurement — `scripts/harness/hid-cc-inject-test.py`.
> - **#1 (deferred one-shots)**: `scripts/harness/hid-mouse-deferred-test.py` attaches a QEMU USB mouse
>   and asserts the one-shot arrives **without any typing**, proving the `kb_has_key` poll loop drives
>   the flush. **Mutation-tested**: disabling the flush call turns that assertion red, so the test is
>   not vacuous. `hid_poll` is now console-silent (grep-verified), and each message has exactly one
>   emitter, inside `hid_flush_oneshots()`.
> - **#3 (halt recovery)**: ⚠ **reachable, NOT validated.** An injected halting code shows the flag is
>   set, the function is called and the box survives — but the code is fabricated in software, so the
>   controller never halts, `xhci_ep_state()` reports Running, and the body early-outs before issuing a
>   single command. The Reset Endpoint / Set TR Dequeue pair has executed nowhere.

**Method**: four independent code lenses, every finding then attacked by three skeptics with distinct
refutation angles (misquote / unreachability / Cyrius-semantics). 37 raised, **24 survived, 13 refuted**.
The three below were additionally re-verified by hand against the source before filing.

---

## The original question, answered

**The line the operator saw is not a mouse message.** It is
`hid: first keyboard report dispatched via the endpoint registry` — `hid.cyr:873`, inside the keyboard
arm gated at `hid.cyr:865`. The mouse one-shot is a different string on a different latch
(`hid: first mouse report accumulated`, `hid.cyr:212`).

**Why typing triggers it**: it is a one-shot emitted by the producer at the instant the first keyboard
report is dispatched. The first report *is* the first key pressed, so it necessarily fires during the
first typing at the prompt. Latched by `hid_first_report` (`hid.cyr:63`), never reset — one line per boot.

**Why it lands mid-prompt**: `kprintln` (`kprint.cyr:37-45`) fans out to serial + framebuffer + klug with
no userland-aware branch, and `fb_println` paints at the live cursor. There is one console cursor and two
writers — the kernel, and ring 3 via `write(1)` → `devs.cyr:71` → `kprint`. So the line is appended to
`[ASSIST] > `.

⛔⛔ **THE RULING THAT USED TO SIT HERE WAS WRONG AND IT WAS REVERSED 2026-08-16.** It read: *"⭐ This is
working as intended and should not be 'fixed': a boot-phase mute would hide exactly the lines you need
when a session goes wrong. The defect is the locking of that print (#1), not its content or its timing."*

**That is a false dichotomy.** The choice was never *corrupt the line* vs *mute the log* — there is a
third option every line editor on every OS has used for forty years: **save the line, erase it, print the
log, replay it.** Every byte still reaches serial, klug and the screen, in order; the operator's command
survives; nothing is muted, deferred, or hidden. The argument for "as intended" defended a property
(never hide a log) that the fix does not threaten.

⚠ **The operator had already said it was a defect**, and it took two more months and an explicit *"I TOLD
YOU TO FIX IT"* to overturn a paragraph that had ruled the report closed. ⇒ A finding that contradicts the
operator's own experience of using the machine needs a much higher bar than one that agrees with it.

**Fixed at 1.56.45**: `fb_console.cyr` keeps the current row's drawn bytes (`fb_line_buf`, 512 B, tracked
at the DRAW so it matches the glass), and `fb_oob_begin`/`fb_oob_end` erase and replay around the fb write
inside `kprint` **and** `kprintln`. Framebuffer only — serial and klug are cursorless transcripts and
replaying into them would print the prompt twice. `kputc` is deliberately unwrapped: it carries the
keystroke echo, which is part of the line rather than an interruption.

**Gated by `scripts/harness/console-line-preserve-test.py`** (sweep: *console live line*), which types a
partial command, fires the mouse one-shot while it is on screen, and requires the last console row to be
pixel-identical before and after. ⛔ It is a **framebuffer** oracle because it has to be: in serial the
log and the typed line are two ordered writes and look correct — **which is how this defect was diagnosed
from a serial log and mis-ruled in the first place.** Mutation-tested: reverting the `kprintln` wrap makes
it fail with 10,296 differing bytes.

**The with-mouse / without-mouse difference**: irrelevant to the line seen (identical in both boots, and
it comes from the keyboard). It matters for one thing only, and that thing is valuable — it is a clean
**negative control proving the composite keyboard's phantom mouse interface is mute**. Boot A emitted
`first mouse report accumulated` only at line 505, after physical motion; Boot B never emitted it despite
a full typing session with that interface bound.

⛔ **A tempting wrong theory, recorded so it is not re-attempted.** The investigation opened on the
hypothesis that the phantom interface is an Apple Consumer-Control collection whose media-key reports
would be fed to `hid_process_mouse_report` as bogus dX/dY. **Refuted**: `xhci.cyr:1248-1252` binds only
on the class triple `03/01/02` — class HID, subclass **boot**, protocol **mouse**. A Consumer-Control
collection does not declare that triple and is never bound. The keyboard genuinely declares a boot-mouse
interface it never uses.

---

## 1. `kprintln` from ISR context can same-CPU deadlock the box — the mouse one-shot is the live hazard

`hid.cyr:212` and `hid.cyr:873` call `kprintln` → `console_spin_lock()` (`smp.cyr:323`), which is an
unbounded `xchg` spin with **no `cli` and no owner check** (verified by reading the inline asm).
`hid_poll` runs from two ISRs: `pic.cyr:79` (100 Hz timer, unconditional) and `pic.cyr:258`
(`xhci_rx_handler`, MSI-X 0x51).

SYSCALL entry masks IF (`syscall_hw.cyr:217-223`, SFMASK `0x40700`), so ring-3 `write(1)` holds the
console lock with interrupts off and cannot be preempted. **The one IF=1 window is the keystroke echo**:
`syscall.cyr:633` `kbd_irq_enable()` … `kputc` at `:657`/`:678`/`:683` … `kbd_irq_disable()`. An
interrupt landing inside that `kputc` re-enters `hid_poll` → `kprintln` → spins forever with IF=0.
**Consequence: hard hang, no recovery, no further log.** The window is widened enormously by a line wrap,
since `fb_scroll_up` (`fb_console.cyr:707`) runs inside the held lock (a 14.7 MB copy at 2560×1440).

⚠ The **keyboard** one-shot is near-unreachable in that window (the first key report cannot coincide with
the echo of a previous key). **The mouse one-shot is the real exposure** — it fires at an arbitrary later
instant, exactly like Boot A's line 505, and can land inside `kputc`.

⭐ The invariant this breaks is already written down in two places and was true when written:
`kprint.cyr:14-17` and `smp.cyr:286-289` ("no ISR calls kprint"). `net_icmp.cyr:56-64` shows the correct
deferred-flush pattern.

**Fix**: do *not* switch to `serial_println` — archaemenid has no serial cable, so that deletes the
instrument on the only machine that matters. Set a pending flag in `hid_poll` (keep the existing latches
so it stays one-shot) and flush from thread context — the non-ISR `hid_poll` call sites at
`keyboard.cyr:97`, `syscall.cyr:8797`, `syscall.cyr:8836`. Leave a note at `hid.cyr:866` saying why the
print cannot be inline, so a later author does not undo it.

## 2. A rejected completion code silently kills the endpoint — and the comment promises the opposite

```
hid.cyr:864:  if (cc_ok == 0) { bi = 0 - 1; }   # not a usable report: re-arm below, fold nothing
```

**There is no re-arm below.** `hid_ep_kind_at(-1)` returns `HID_KIND_NONE` (`hid.cyr:155`), so both
kind-gated blocks are skipped — and those blocks contain the *only* `hid_arm_xfer_trb()` /
`hid_arm_row_trb(bi)` calls and the *only* doorbell writes (`hid.cyr:878-880`, `887-889`). Meanwhile the
event is consumed unconditionally at `hid.cyr:895`.

Rings are 16 deep (`hid.cyr:625` keyboard, `hid.cyr:348` mouse). **16 cumulative non-halting errors empty
the ring**, and this file already documents the outcome at `hid.cyr:600-613`: "the controller hits the
empty ring at the next service interval and STALLS the endpoint." Presents as *input froze, CPU still
alive*, with no log line.

**Fix**: keep two variables instead of overloading one — `row` for maintenance, and gate only the
**fold + one-shot** on `cc_ok`. Leave the re-arm + doorbell unconditional inside their kind arms, keyed
on `row`. Then delete the "re-arm below" clause and replace it with what the code actually does.

## 3. No halted-endpoint recovery on the HID path

`xhci_cmd_reset_endpoint` (`xhci_cmd.cyr:331`) and `xhci_cmd_set_tr_dequeue` (`xhci_cmd.cyr:366`) exist
and are used by mass-storage (`msc.cyr:929`, `:981`). A repo-wide grep returns **zero** hits in `hid.cyr`.

This is the necessary complement to #2, not a duplicate. For the *halting* codes (Stall 6, Transaction
Error 4, Babble 8) the endpoint is Halted with its dequeue pointer pinned, and a bare re-arm is inert —
`hid.cyr:606-607` says exactly this. **Fixing #2 alone recovers only the non-halting codes.** One marginal
cable or hub glitch kills that keyboard until reboot, silently.

**Fix**: these commands block on a Command Completion Event and must not run in an ISR. Flag a per-row
`hid_ep_needs_reset[row]` in `hid_poll` on ccode 4/6/8, and add `hid_recover_halted()` that resets the
endpoint, sets the TR dequeue pointer, re-arms to depth 16, rings the doorbell and logs one line naming
the device — called from the same thread-context sites as #1, mirroring `msc.cyr:924-987`.

---

## Lower-priority, same investigation

- **MSI-X armed before the last EP0 control transfers.** `main.cyr:542-543` arms vector 0x51, then
  `main.cyr:553` calls `msc_enumerate()`, whose control transfers route to `xhci_wait_transfer_event`
  (`xhci.cyr:1146`), which consumes and discards non-matching events with no dispatch and no re-arm. A
  keystroke in that window is dropped *and* costs a TRB permanently (compounding #2). The comment at
  `main.cyr:537-540` justifies the deferral as protecting "the control transfers above" — but
  `msc_enumerate` is *below*. ✅ **Exposure bounded to the boot-probe window**: the 2026-08-11 capture
  shows `nvme: registered as block_dev` (line 76) and AHCI as secondary (line 103), so `blk_active`
  resolves to NVMe and `msc_blk_read` is not on the runtime path. **Fix**: move the arm past
  `msc_enumerate()` and correct the comment.
- **`klug.cyr:19-21` states a falsehood that costs log forensics.** It claims "the kernel stops feeding
  the ring at the kybernet userland handoff." It does not — `devs.cyr:71` routes every ring-3
  `write(1)/write(2)` byte through `kprint`, which taps `klug_append` (`kprint.cyr:32`). ⇒ A verbose
  session ages the boot log out of the 64 KB ring, and **printing the log to the console re-appends it to
  itself**. Redirecting to a file avoids it (`vfs.cyr:970` takes the ext2 arm, no `kprint`), which is why
  `run /bin/klug > /f.txt` is *required*, not merely convenient.
- **`hid_mouse_seq` advertises a ring-3 capability that does not exist.** `hid.cyr:176` claims "ring 3 can
  tell 'no motion' from 'no poll'". Repo-wide grep finds exactly two lines: the declaration and the
  increment. It is in no syscall and not in the 16-byte ptrscan record. Delete the clause or the counter.

## Confirmed working-as-intended — do not "fix" these

Binding **every** boot-mouse interface across all slots (`xhci.cyr:1250-1252`) — a pointer is a *seat*,
not a device; first-match would bind the phantom and miss the real mouse, so Boot B's `bound: 1` is the
binder being correct. · `hid_ep_find` keyed on **(slot, DCI)** (`hid.cyr:144-153`) — Boot A (two devices
both on EP 0x81 → same DCI 3, different slots) and Boot B (one slot, DCI 3 vs 5) are both disambiguated.
· Doorbell slot and target taken from the **event**, never a global (`hid.cyr:879-880`, `888-889`).
· Buttons as a persistent **level**, unioned across mouse rows (`hid.cyr:196-207`) — clearing on drain
would synthesise a release the user never made and kill every drag; `hid.cyr:67-72` records that exact
regression. · `#98` returning 0 for both "no pointer device" and "pointer idle" — a still mouse and no
mouse are the same answer to "what moved since last call".

## Open — needs a hardware measurement

1. **Does the keyboard's interface 1 honour SET_PROTOCOL(Boot)?** The kernel issues it (`hid.cyr:310`)
   and aborts the bind on failure, but never issues GET_PROTOCOL and deliberately never parses the report
   descriptor (`hid.cyr:501-503`). Two boots of silence are consistent with "boot protocol honoured,
   interface mute" — but **neither boot pressed a media key**; the operator typed ordinary text.
   **Measure**: at the agnos prompt press Volume-Up or any Fn-row media key. **If
   `hid: first mouse report accumulated` appears** → the interface emits in *report* protocol, byte 0 is a
   Report ID, and `hid.cyr:190-192` is decoding a usage code as buttons/dX/dY ⇒ the phantom is not mute
   and needs a per-row filter. **If nothing appears** after a full media-key sweep → boot protocol is
   honoured, the phantom costs only two pages and a registry row, and the negative control stands.
2. **Is #1's deadlock window actually entered?** Structural argument only; no burn can prove absence.
   **Measure**: a counter in `hid_poll` incremented when entered with `console_lock != 0`, emitted via
   `klug_append` **only** — never `console_lock` (`proc.cyr:1346` already does exactly this from the timer
   ISR). Read back with `run /bin/klug > /f.txt` after a long typing session. Nonzero ⇒ the window is
   entered routinely and both one-shots have survived on luck.
3. **What is the real completion-code distribution?** No completion code is ever logged (`hid.cyr:859-864`
   reads it and discards it), so there is zero evidence about how often #2 and #3 fire. **Measure**:
   per-code counters, `klug_append`-only, over a session including a cable jiggle. Any 4/6/8 ⇒ #2 and #3
   are live, not latent, and the count against the ring depth of 16 says how close the keyboard came to
   going dead.
