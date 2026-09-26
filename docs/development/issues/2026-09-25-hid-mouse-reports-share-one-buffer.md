# 2026-09-25 — HID mouse: every interrupt TRB DMAs into one report buffer, so coalesced reports lose motion and buttons

**Status:** 🟡 **OPEN** — planned for **1.57.8**. Found by 1.57.7's S3d (bite B2) while fixing the same defect on
the KEYBOARD; the mouse half was not fixed because no 1.57.7 gate exercises the mouse.
**Filed by:** agnos, from the 1.57.7 S3d step report (`open_problems`, "Found, not fixed").
**Checked against:** agnos **1.57.7**, `kernel/arch/x86_64/usb/hid.cyr` (`hid_ep_buf` ~:128, the per-row setup
~:143, the mouse dispatch ~:1404).
**Severity:** lost pointer motion and button events when the drain is late; not a memory-safety defect.

## What happens

Each HID mouse row has ONE report buffer (`hid_ep_buf` per row) and every interrupt-IN TRB on that row DMAs into
it. When two reports complete before the drain runs (a late drain: IF=0 stretches, a busy BSP tick), the event
handler processes each completion event against the same buffer, so it folds the LAST report's deltas once per
event: the first report's motion and buttons are lost, and the last one's are counted twice. The keyboard had the
identical shape (a key pressed and released inside one IF=0 stretch was lost: `abc` read `bc`); S3d gave each
keyboard TRB its own 16-byte report slot (mutation M-HID).

## The fix (1.57.8)

Per-TRB report slots for the mouse rows, as S3d did for the keyboard (a 4 KB page, slot index from the TRB, the
event's TRB pointer selects the slot). Mind the DMA identity-VA issue filed the same day: the new slots should be
addressed through the direct map.

## Gate

A mouse gate first (`hid-mouse-deferred` / a crab-pointer harness): inject two mouse reports inside one IF=0
window under QEMU (`usb-mouse` + a held-IF=0 selftest window, as wait-kbd does for keys) and require both reports'
deltas and button edges (RED on today's code). Iron: the carried "mouse one-shot deferred flush" burn item.

## Evidence (operator-local)

`~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/steps/S3d-report.json` (`open_problems`), `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.7/logs/S3d/B2/` (the keyboard trace), `logs/S3d/mutations/M-HID-*`.
