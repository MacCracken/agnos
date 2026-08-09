---
name: AGNOS Pointer Input — design
description: AE-7 pointer input, kernel to cursor — what already works, the four defects that only a relative-motion device exposes, and the bite order
type: planning
---

# Pointer input (`AE-7`) — design

**Status** P0 + P1 DONE (2026-08-08); P2-P4 unbuilt. ⭐ PS/2 deleted from the kernel along the way. Opened 2026-08-08 after `AE-0a` and the F4 close both came back iron-proven.
**Owner of the compositor half** aethersafha [`planning/desktop.md`](https://github.com/MacCracken/aethersafha/blob/main/docs/development/planning/desktop.md) `AE-7` row — point it here, do not duplicate.

⭐ **The headline: far less new code than the ladder assumed, and the risk is nearly all in four
pre-existing defects that a keyboard cannot expose.** Enumeration already addresses the mouse. The setu
protocol already carries pointer messages. The compositor already has hit-testing, z-ordered
point-to-window lookup, and a clamped move. What does *not* exist is a drain that can serve two HID
devices, a transport that is safe for relative deltas, and a cursor.

---

## 0. The hardware, measured — and the trap in it

Read from sysfs on archaemenid with the mouse plugged in (2026-08-08):

| device | VID | interface | class/sub/proto | EP | bInterval |
|---|---|---|---|---|---|
| `1-1` | `1bcf` | 0 | 03 / 01 / **02 — boot mouse** | `0x81` | **10 ms** |
| `1-2` Keychron K2 | `05ac` | 0 | 03 / 01 / 01 — boot keyboard | `0x81` | 1 ms |
| `1-2` Keychron K2 | `05ac` | **1** | 03 / 01 / **02 — boot mouse** | `0x82` | 1 ms |

⛔⛔ **THE KEYBOARD ALSO ADVERTISES A BOOT-MOUSE INTERFACE.** A "find the first interface with protocol
0x02" search binds to the **Keychron**, which never reports motion — presenting as *"mouse enumerated,
cursor dead"*, a silent dead end that costs a burn to diagnose.

⇒ **Bind EVERY boot-mouse interface found and merge their motion into one pointer.** That is also what
Linux's `usbhid` does — all mice are one seat — so it is the ported answer, not a workaround. There is no
heuristic for picking "the real mouse" and we should not invent one. The Keychron's mouse interface will
simply sit silent.

⚠ Two consequences: the two interfaces differ in `bInterval` (1 vs 10 ms), and **interface 1's endpoint
`0x82` lives in the same slot as the keyboard's `0x81`** — so per-slot state is not enough. Endpoint is
the unit, not device.

---

## 1. What already works — do not rebuild any of this

**Kernel / xhci**
- ⭐ **Enumeration already visits every root-hub port with no early exit** (`xhci.cyr:1453`). A plugged-in
  mouse is already reset, Enable-Slot'd, given an Input+Device Context and a DCBAA entry, Address-Device'd,
  MPS-reconciled and descriptor-read **on the current binary**, and already prints its own
  `xhci: port N connected, …` line.
- ⭐ **Every per-device field is already per-slot** — 8 parallel 65-entry tables in one PMM page
  (`xhci_ctx.cyr:92`): input ctx, dev ctx, EP0 ring/cycle/idx, port, speed, MPS.
- ⭐ **`xhci_dci_for_ep`, `xhci_interrupt_interval` and `xhci_input_ctx_add_interrupt_in` are already
  class-agnostic** and serve a mouse endpoint unchanged. `0x82` → DCI 5; `bInterval=10` → Interval 6 = 8 ms
  via the Linux `fls(8*bInterval)-1` convention already implemented. **Do not write mouse variants.**
- ⭐ **Class dispatch is already interface-descriptor-based**, as two independent probe passes over all
  slots (`hid_kbd_configure`, then `msc_enumerate` at `msc.cyr:406`). `msc` is the established prior art
  for two USB classes coexisting, with per-slot rows. ⚠ The device-descriptor class is *print-only*
  (`xhci.cyr:1392`) — correct, since a composite device reports class 0.
- ⭐ **Completion is already three-way redundant** and all three funnel into one `hid_poll`: the MSI-X ISR
  (`pic.cyr:255`), the 100 Hz timer tick, and the blocking-read loop. A mouse inherits all three free.
- ⭐ `hid_kbd_kick` already exists as the anti-stall re-kick after an IF=0 gap.

**Transport**
- ⭐ **`BHUMI_DEV_POINTER = 4` is already reserved** (`bhumi/src/seat.cyr:31`), and every capability minted
  anywhere in the tree is `OUTPUT|INPUT` = 3. ⇒ Capability-gating the pointer drain makes pointer events
  **opt-in**, and makes it structurally impossible to break a consumer that has not been updated.
- ⭐ **The button-edge algorithm already exists and is tested**: `bhumi_kbd_diff`'s 8-bit modifier-bitmap
  diff (`bhumi/src/input.cyr:104-117`) is byte-for-byte what a HID mouse button byte needs — both are
  state bitmaps, and press/release is the same edge detection.
- ⭐ The `max_ev - w` shared-budget append pattern already exists (`bhumi/src/kbscan.cyr:59`).

**Compositor**
- ⭐⭐ **THE ENTIRE POINTER HALF OF setu ALREADY EXISTS**: `SETU_INPUT_PTR_MOVE` (kind 9) and
  `SETU_INPUT_PTR_BTN` (kind 10), with constructors, argc table, name lookup, **and two live call sites
  already sending them** using Linux evdev button 272. ⇒ **No protocol change. No client change required
  to make a window clickable** beyond the client choosing to act on messages it can already receive.
- ⭐ `comp_window_at(c, px, py)` — z-ordered back-to-front, skips minimized. Written, never called.
- ⭐ The full **9-region `deco_hit`** with its button-geometry helpers, and it is unit-tested.
- ⭐ `input_move(win, dx, dy, bound_w, bound_h)` with the GPU-safe clamp and the re-clamp for oversized
  windows, freshly iron-proven by F7-F10. **A titlebar drag is a move by a delta ⇒ it reuses this
  directly**, and its `1 = actually moved` return is exactly the signal a drag needs.
- ⚠ `gestures.cyr` is **TOUCH, not pointer** — constructed but never fed. Not relevant to `AE-7`.

---

## 2. The four defects a keyboard cannot expose

These are the actual work. Each is invisible today and each breaks a pointer specifically.

### D1 ✅ FIXED 2026-08-08 — `hid_poll` silently ate every event it did not match

`hid.cyr:457-460`. One drain loop, matched against the keyboard's slot+endpoint, and unmatched Transfer
Events are consumed and dropped. ⇒ **A separate `hid_mouse_poll()` called after `hid_poll()` can never
work** — `hid_poll` will already have eaten the mouse's completions. This is the single constraint that
shapes the whole kernel design.

**Fix** one drain loop that dispatches on `(evt_slot, evt_ep)` against a small registry of bound HID
endpoints. Not two pollers.

### D2 ✅ FIXED 2026-08-08 — `hid_poll` no-op'd entirely when no *keyboard* was configured

`hid.cyr:419` — `if (hid_kbd_slot_id == 0) { return 0; }`. On a mouse-only box nothing is drained **and
`IMAN.IP` is never re-armed**, so the controller goes quiet. Must widen to "no HID device at all".

### D3 ⛔⛔ All 16 armed TRBs point at ONE shared report buffer — lossy *and amplifying* for deltas

`hid.cyr:275` arms 16 TRBs all pointing at the same `report_buf`; `hid_poll` re-reads that buffer per
Transfer Event (`hid.cyr:449`). The code documents the consequence and calls it acceptable: *"a gap that
coalesces >1 report keeps only the LAST"*.

⚠ **That is true for a keyboard and false for a mouse.** A keyboard report is idempotent state — the
differ sees `curr == prev` and nothing happens. A mouse report is a **relative delta**: N coalesced events
apply the *surviving* delta N times. At 8 ms reports against 16 ms frames that is a systematic **~2-3x
motion multiplier**, and it would present as "the cursor is too fast / jumpy", which is exactly the sort of
symptom that gets tuned with a sensitivity constant instead of fixed.

**Fix** accumulate deltas in the kernel at drain time (sum dX/dY across all Transfer Events, OR the button
bitmaps, emit one merged sample). Preferred over 16 per-TRB buffers: it is less memory, it is lossless for
deltas by construction, and merging is what the consumer wants anyway. ⚠ Buttons must OR *and* keep the
last state, so a press+release inside one gap is not swallowed.

### D4 ✅ FIXED 2026-08-08 — chrome-inside vs chrome-outside window rects disagreed

`deco_hit` and `comp_window_at` treat the window rect as `y .. y+h` (chrome **inside**), while the damage
model, `ae_gpu_window_admissible` and the client blit all use `TITLEBAR_H + h` (chrome **outside**). Today
nothing calls the first pair, so the disagreement is inert. ⇒ **The first pointer click exposes it**: hits
land 30 px out on a live setu window and the bottom resize strip falls inside the client surface.

**Fixed** as P0, before any pointer code, with its own tests. ⚠ It was worse than described here:
`render_window`'s **theme body fill** used `h - TITLEBAR_H` while its **client blit** 50 lines below used
`h` at the same origin — two conventions inside one function. The convention now has a single definition
(`win_total_h` / `win_body_y` / `win_bottom_y` / `win_prev_total_h` in aethersafha's `src/window.cyr`) and
all nine consumers go through it. ⚠ `TITLEBAR_H` had to move out of the renderer's button enum first:
that was the mechanical cause, since `compositor.cyr` is included earlier and could not reach it.

---

## 3. Transport design

### 3.1 ⛔ The mouse must NOT share `kbscan #42`'s ring — moving it would QUIT the compositor

A one-pixel-right motion is `dX = 0x01`. Fed through the Set-1 decoder `_bhumi_set1_to_hid`, `0x01`
decodes to HID `0x29` = **Escape** = `IA_QUIT`. ⇒ Sharing the scancode pipe means **moving the mouse quits
the desktop**, and that same pipe feeds `cyrius-doom`'s `input_poll`. Separate ring, separate syscall,
non-negotiable.

### 3.2 Syscall `#98`

⚠ **`#98` is the next free number and the only one available.** `#44` and `#96` *look* free to a
`grep 'num == N'` of `syscall.cyr` and are not: `#44` (`sched_yield`) dispatches in the ring-3 entry stub
rather than in `ksyscall`, and `#96` is reserved for `fork` by an operator ruling of 2026-08-05 — the same
ruling that names `#98` as next-free. Every number 0-95 and 97 has a live arm. Unknown numbers fall
through to `return 0 - 1` (`syscall.cyr:9383`).

**Contract** copy `kbscan #42`'s *structure* verbatim — validate `is_user_range` first, then
`preempt_disable` → sti window → bounded drain → cli → `preempt_enable`, copy to the user buffer **outside**
the window, `stack_canary_check` on every exit.

⛔ **Do NOT copy its 256-iteration spin.** That spin exists to give the CPU post-`sti` instructions to take
a pending **PS/2 IRQ1**, and `syscall.cyr:634-639` records that IRQ1/`kb_isr` is **dead code on
archaemenid** (USB keyboard only). One `hid_poll()` already loops internally to 64 events. 256 iterations
also means 256 posted MMIO writes to `IMAN` per call — copying it for a pointer would add ~512 per frame
for nothing.

### 3.3 Event encoding — one batch, kind nibble at bits 56-59

Pointer events ride the **same** `bhumi_backend_poll` batch as keys. A second poll would double the
syscall count per frame and let the two streams desynchronise.

⛔ **A TYPE TAG IS MANDATORY AND IS THE MOST DANGEROUS OMISSION IN THIS DESIGN.** Today a pointer event
placed in the `events[]` array would be read as a **key** by six call sites, because `bhumi_key_usage` is
just `ev & 0xFF`. A `dY` of 41 is `0x29` — Escape — so **an untagged pointer event quits the compositor on
vertical motion.** Same failure as §3.1, one layer up.

Layout: kind nibble at bits **56-59**, chosen so **every existing key event is kind 0 bit-for-bit** and no
legacy producer changes. Kinds: `MOTION` (dX, dY, both sign-extended), `BUTTON` (bitmap + edge), `AXIS`
(wheel). Zero-suppressed — a report with no motion emits no MOTION event.

⚠ Consumers must gate on kind **before** reading a usage. Auditing all six call sites is part of the bite,
not a follow-up.

---

## 4. The cursor

⛔ **The cursor cannot be drawn with `fill_rect` or `draw_char` on an agnos GPU frame.** The chrome rect
queue is emitted **before** the client surfaces, and the `#39` blit is skipped entirely when
`chrome_rc > 0` — so anything drawn that way lands *under* the client windows or not at all.

⭐ **It can go through `draw_text`'s queue, which is drained AFTER the client blits** — that ordering exists
for exactly this reason. So a glyph-based cursor composites last, on top, on the GPU path, with no new GPU
code. First cut: a cursor **glyph**.

⚠ **The cursor damages every frame it moves**, which interacts with `AE-0a` directly: its rect must be in
the band, and — exactly like the closed window whose rect left the live window list — **the previous
position must be too**, or the cursor smears. That is the same `union(cur, prev)` requirement, and the same
trap, in a third place. Treat the cursor as a one-window damage source with a retired rect.

---

## 5. Bite order

Each bite is independently verifiable, and only two need iron.

| # | bite | verify |
|---|---|---|
| **P0** | ✅ **DONE 2026-08-08** (aethersafha, unreleased). The convention now has ONE definition in `src/window.cyr` — `win_total_h` / `win_body_y` / `win_bottom_y` / `win_prev_total_h` — and `TITLEBAR_H` moved there from render.cyr's button enum, which was the mechanical cause (compositor.cyr is included earlier and could not reach it). All nine consumers routed through the accessors. ⚠ It was worse than D4 described: `render_window`'s theme body fill contradicted its own client blit 50 lines below. `render.tcyr` 160 → **179**; two pre-existing asserts were CHANGED because they encoded the wrong convention and passed. | ✅ unit tests, mutation-verified both halves (7 asserts / 1 assert) |
| **P1** | ✅ **DONE 2026-08-08.** Bound-endpoint registry keyed on `(slot, DCI, kind)`, one dispatching drain, guard widened off `hid_kbd_slot_id`. ⭐ **PS/2 was DELETED in the same bite** (operator ruling) — it had to be: q35's i8042 kept delivering keys in QEMU and masked the xHCI path entirely, so no mutation test of this dispatch could bite. Also: `kbscan #42`'s 256-iteration IRQ1 spin → one `hid_poll()`. | ✅ arc sweep **17/17**; clean build prints `hid: first keyboard report dispatched via the endpoint registry` and types, mutant prints neither. ⚠ Requires `build.sh` → `agnsh-smoke.sh` → harness — the harness builds no image |
| **P2** | **Kernel: bind every boot-mouse interface**, per-endpoint ring, SET_PROTOCOL boot, Configure Endpoint. Fix D3 by accumulating deltas at drain. Log the bound set. | QEMU with `-device usb-mouse`; the log must name **both** Keychron-mouse and real-mouse bindings on iron |
| **P3** | **`#98` + the bhumi seam**: ring, syscall, kind-tagged events, capability gate, and an audit of all six consumer call sites. | host unit tests for the encode/decode and the button differ; QEMU end-to-end |
| **P4** | **Compositor `AE-7`**: cursor glyph with retired-rect damage, click-to-focus via `comp_window_at`, titlebar drag via `input_move`, buttons forwarded to clients over the setu messages that already exist. | QEMU screendumps; then **one** iron burn |

⚠ **P1 is the bite that can break what works.** The keyboard is the only input device on this box; a drain
regression is a box you cannot type on. It ships alone, with the keyboard as the gate.

⛔ **No iron burn before P4.** P1-P3 are all reachable in QEMU (`-device usb-mouse` on the existing
`qemu-xhci`, which is the same producer as iron), and the harness already injects input. The one thing QEMU
cannot show is the **composite-device** case from §0 — the Keychron's second interface — so that is what
the P4 burn is *for*, and its log must name the bound set rather than merely moving a cursor.
