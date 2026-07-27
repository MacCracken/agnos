# 2026-07-10 — USB-HID arrow / navigation keys not reaching ring-3 clients

**Status:** ✅ FIXED — **cut 1.53.12** (2026-07-10). Arrow + nav-cluster keys now round-trip
from a USB-HID keyboard to userland. Verified on agnos: a Down arrow moves the `crab` file
manager's selection highlight (`setu-nav-test.py` PASS).
**Cross-repo:** a copy of this doc lives in `cyrius/docs/development/issues/` — the ecosystem
input path (`bhumi` decodes what `sys_kbscan`#42 drains) depends on the kernel emitting these
scancodes, so the language/desktop side tracks it too.

## Problem

The `crab` file manager (a dhancha/setu client) navigates its file list with the arrow keys,
but on agnos the arrows produced **nothing** — the client received zero key events on an arrow
press, while regular letter keys (`a`, `j`, …) arrived fine.

Root cause: the Phase-5 USB-HID → PS/2 set-1 translation **deferred** the extended keys. In
`kernel/arch/x86_64/usb/hid_translate.cyr` the `hid_to_ps2` table left HID `0x46`–`0x52`
(PrintScreen / arrows / nav cluster) at `0` — the comment said *"deferred (extended
0xE0-prefixed PS/2 set-1; not required for MVP typeable shell)."* So `hid_usage_to_ps2`
returned 0 for an arrow, and `hid_report_keys_diff` dropped it (`if (sc != 0)`).

Two things were missing:
1. **No base scancodes** for the arrow/nav usages in the table.
2. **No 0xE0 prefix** — arrows are *extended* set-1 keys (byte stream `E0 <make>` /
   `E0 <break>`), but `hid_kb_push` pushes a single byte with no way to emit the prefix.

Meanwhile `bhumi` (the compositor's platform backend) was **already ready**: its
`_bhumi_set1_ext_to_hid` maps `E0 0x48 → Up (0x52)`, `E0 0x50 → Down (0x51)`, etc. The gap
was entirely on the kernel's emit side.

## Fix

- **`hid_translate.cyr`** — map HID `0x49`–`0x52` (Insert / Home / PageUp / Delete / End /
  PageDown / Right / Left / Down / Up) to their set-1 **base** make codes; add
  `hid_usage_is_ext(hid_code)` = 1 for `0x49`–`0x52`.
- **`hid.cyr`** — in `hid_report_keys_diff`, prefix `hid_kb_push(0xE0)` before the make and
  before the break of an extended key.

The round-trip now closes: kernel emits `E0 0x48` (Up make) → `sys_kbscan`#42 → `bhumi`
`ext(0x48)` → HID `0x52` (Up) → compositor forwards `SETU_INPUT_KEY(0x52)` → client.

## Follow-ups

- Media / keypad extended keys (`0x54`+) still deferred — add on demand.
- Left/Right GUI (Win) modifiers still `0` in the modifier table (extended `E0 0x5B/0x5C`).
- No key-repeat for held arrows (HID boot reports don't auto-repeat; a timer-driven repeat is
  a userland or kernel policy choice, unfiled).
