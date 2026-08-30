# `#98 ptrscan` — the pointer band: a second HID device, and a ring that is safe for RELATIVE motion

**Status:** ✅ **RESOLVED — SHIPPED 1.56.42, grown to a 20-byte wheel record at 1.56.49.** Swept 2026-08-30. The header below still read *"DESIGNED, UNBUILT"* eleven cuts after it was built: the kernel arm, all three named HID defects and the cyrius constant are all in. ⭐ Iron-confirmed 2026-08-30 — the burn enumerated a composite keyboard+mouse on one slot (`hid: mouse configured, boot protocol on, EP=130 interface=1`). Nothing carried.

**Original status:** 🔵 **DESIGNED, UNBUILT.** Filed 2026-08-08, opened the day `AE-0a` and the F4 close both came
back iron-proven and the operator asked for USB-mouse support.
**Design:** [`planning/pointer.md`](../planning/pointer.md) — read it first; this ticket is the *number*
and the *cross-repo contract*, not the design.
**Number:** **`#98`** — verified free six ways, see §1. `#96` stays with `fork`
([`2026-08-05-syscall-96-fork.md`](2026-08-05-syscall-96-fork.md)); `#97` is the channel band
([`2026-08-05-syscall-97-chan-op.md`](2026-08-05-syscall-97-chan-op.md)), whose own ticket already records
*"Next free is `#98`."*
**Cross-repo:** agnos (kernel) **+ cyrius** (`lib/syscalls_x86_64_agnos.cyr`) **+ bhumi** (the seat/input
seam) **+ aethersafha** (`AE-7`). Peer ticket filed in cyrius the same day.
**Severity:** Medium — nothing is broken today. This unblocks the desktop's last missing input class, and
it pays down three kernel defects that only a relative-motion device can expose.
**Affects:** agnos 1.56.x (unslotted).

---

## 1. The number is `#98`, verified mechanically

Not taken on trust from a survey. Six independent checks:

1. **Kernel dispatch** — a regex over every `num == N` arm in `kernel/core/syscall.cyr` yields 96 arms
   covering **0-95 and 97**. `98` has no arm. Unknown numbers fall through to `return 0 - 1`
   (`syscall.cyr:9383`).
2. ⚠ **`#44` LOOKS free to that same regex and is NOT.** `sched_yield` dispatches in the ring-3 entry stub,
   not in `ksyscall` — `kernel/arch/x86_64/syscall_hw.cyr:105` says so in as many words: *"sched_yield(#44)
   dispatches HERE, not in ksyscall"*. Anyone re-deriving free numbers by grepping `ksyscall` alone will
   wrongly conclude 44 is available.
3. ⚠ **`#96` LOOKS free and is RESERVED.** `docs/development/roadmap.md:41` reserves it for **`fork`**,
   operator-assigned 2026-08-05, and `planning/ipc.md:338` records that fork **keeps** it and that this
   "must not be re-opened as a question".
4. **cyrius side** — `lib/syscalls_x86_64_agnos.cyr` defines 97 `SYS_*` constants; the highest is
   `SYS_CHAN_OP = 97`. `96` and `98`+ are unused, so the two sides agree.
5. **No raw callers** — nothing in the tree or the sibling repos calls `syscall(98, …)`. ⚠ This check
   matters more than it sounds: `roadmap.md` tracks a whole live bug class of raw Linux syscall numbers
   compiling clean on agnos and hitting a different arm.
6. **The `#97` ticket already named it** — an independent statement from the last time this question was
   adjudicated.

⇒ **`#98 ptrscan`.** Name is plain-descriptive and parallel to `kbscan #42`, per the naming rule that
kernel-internal surfaces do not get lane names.

---

## 2. The contract

```
ptrscan(buf = arg1, max = arg2) -> count of BYTES written, 0 = none, <0 = error
```

A NON-blocking drain of merged pointer samples into a ring-3 buffer. Structure copies `kbscan #42`
verbatim: validate `is_user_range` **first**, then `preempt_disable` → sti window → bounded drain → cli →
`preempt_enable`, copy to the user buffer **outside** the window, `stack_canary_check` on every exit path.

⛔ **Do NOT copy `kbscan`'s 256-iteration spin.** That spin exists to give the CPU post-`sti` instructions
to take a pending **PS/2 IRQ1**, and `syscall.cyr:634-639` records that IRQ1 / `kb_isr` is **dead code on
archaemenid** (USB keyboard only). One `hid_poll()` already loops internally to 64 events. 256 iterations
also means 256 posted MMIO writes to `IMAN` per call (`hid.cyr:429`); copying that for a pointer would add
~512 per frame and buy nothing.

⛔ **`ptrscan` must NOT share `kbscan`'s ring.** A one-pixel-right motion is `dX = 0x01`, and `0x01` fed
through bhumi's Set-1 decoder (`_bhumi_set1_to_hid`) becomes HID `0x29` = **Escape** = `IA_QUIT`. Sharing
the pipe means **moving the mouse quits the desktop** — and that same pipe feeds `cyrius-doom`'s
`input_poll`. Separate ring, separate syscall, non-negotiable.

---

## 3. Three kernel defects this must fix, all invisible to a keyboard

Detail and line numbers in [`planning/pointer.md`](../planning/pointer.md) §2. In brief:

- **D1** `hid_poll` **silently consumes every event it does not match** (`hid.cyr:457-460`). ⇒ A separate
  `hid_mouse_poll()` after `hid_poll()` can **never** work. One drain loop dispatching on
  `(evt_slot, evt_ep)` against a bound-endpoint registry is forced by this, and it is the constraint that
  shapes the whole kernel change.
- **D2** `hid.cyr:419` — `if (hid_kbd_slot_id == 0) { return 0; }`. On a mouse-only box nothing is drained
  and **`IMAN.IP` is never re-armed**.
- **D3** All 16 armed TRBs point at ONE shared report buffer (`hid.cyr:275`), and the code documents that a
  coalescing gap *"keeps only the LAST"* report. ⚠ Idempotent for keyboard state; for **relative deltas**
  it is lossy *and amplifying* — N coalesced events apply the surviving delta N times, a systematic
  **~2-3x motion multiplier** at 8 ms reports against 16 ms frames. That would present as "the cursor is
  too fast" and get tuned with a sensitivity constant instead of fixed. ⇒ **Accumulate deltas at drain
  time** (sum dX/dY, OR the button bitmap and keep the last state so a press+release inside one gap is not
  swallowed).

---

## 4. What cyrius owes (peer ticket)

`lib/syscalls_x86_64_agnos.cyr`:
- `SYS_PTRSCAN = 98;` in the agnos `Sys` enum.
- `fn sys_ptrscan(buf, max)` wrapper alongside `sys_kbscan`.

⚠ **Ordering:** the kernel arm can land first and be exercised through a raw `syscall(SYS_PTRSCAN, …)`
only *after* cyrius defines the constant — a raw literal `98` in consumer code is exactly the bug class
`roadmap.md` tracks, so consumers must wait for the named constant rather than hard-code the number.
⚠ Cyrius is hands-off without per-edit authorisation; that repo's ticket is the request, not a patch.

---

## 5. Kill criteria

1. A USB mouse plugged into archaemenid is bound and **named in the boot log**, alongside the keyboard,
   with neither device's binding displacing the other.
2. ⭐ **Both** boot-mouse interfaces are bound on that box — the real mouse *and* the Keychron K2's
   interface 1 — because the keyboard advertises a mouse interface too (`planning/pointer.md` §0) and
   "bind the first protocol-0x02 interface" would silently bind the keyboard and see no motion.
3. The keyboard still types, in QEMU and on iron, after the drain is reworked. ⚠ This is the gate that
   matters most: it is the only input device on that box.
4. `ptrscan` returns merged samples whose summed motion equals the motion the device reported — i.e. D3 is
   fixed and provably not amplifying. Verified against a synthetic coalescing case, not by feel.
5. Moving the mouse does **not** quit the compositor, and does not appear as keystrokes anywhere.
