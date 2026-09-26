# 2026-09-25 — HID mouse: every interrupt TRB DMAs into one report buffer, so coalesced reports lose motion and buttons

**Status:** ✅ **RESOLVED 1.57.8 (2026-09-25)**. Step MOUSE gave the mouse rows per-TRB 16-byte report slots, as 1.57.7 S3d did for the keyboard. Both kinds share `hid_slot_buf` (arm) and `hid_row_evt_buf` (drain: the event's TRB pointer selects the slot, which is read through the direct map). Gate: `scripts/smoke/hid-mouse-deferred-smoke.sh` (`HID_MOUSE_DEFER_SELFTEST`, usb-mouse with an HMP injector; sweep row at `-smp 1` and `-smp 4`). Built, gated, NOT burned. See § Resolution.
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

## Resolution (1.57.8, 2026-09-25)

**What shipped:**
- **The arm.** `hid_arm_row_trb` writes `buf + idx*16` (`hid_slot_buf`). When mps > 16, or idx falls outside 0..254,
  it uses the page start instead.
- **The drain.** The `hid_poll` drain folds the slot that the completed event's TRB pointer names
  (`hid_row_evt_buf`: `(TRB ptr − ring phys) / 16`).
- **The keyboard.** It now uses the same helpers: `hid_kbd_slot_buf` wraps `hid_slot_buf`, and `hid_kbd_evt_buf` is
  removed. wait-kbd stays at 44/0.
- **The gate.** Four mouse reports complete while IF=0 and `hid_poll_lock` hold the drain. One drain must then see
  dx 5, dy 7, the press and the release. Three mutations each go RED: the old shared buffer gives dx 0 dy 0; drain-only
  gives dx 20; arm-only gives dx 0.

**What the change broke — checked before archiving:** nothing the reviews found. The re-run regressions were
hid-reclaim, xhci-shadow and wait-kbd 44/0, and all were green. Two limits remain, and neither is a regression:
- The wheel byte goes through the same slot, but the oracle does not inject it.
- Mouse rows with wMaxPacketSize > 16 keep the shared page start, as the keyboard does.

The iron half is the carried "mouse one-shot deferred flush" burn item. It is owed with the next burn (roadmap).

**Evidence:** `~/.claude/projects/-home-macro-Repos-agnos/handoff-1.57.8/steps/MOUSE-report.json`, `MOUSE-endreview.json`; logs under `logs/MOUSE/`.
