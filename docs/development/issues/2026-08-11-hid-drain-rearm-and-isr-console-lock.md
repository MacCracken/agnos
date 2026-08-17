# HID input path — three defects found while explaining a log line at the shell prompt

**Found**: 2026-08-11, investigating an operator report of a "mouse notification on the shell."
**Status**: **#1 and #2 FIXED and MEASURED 2026-08-11; #3 added but its reset sequence is unvalidated.**
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
