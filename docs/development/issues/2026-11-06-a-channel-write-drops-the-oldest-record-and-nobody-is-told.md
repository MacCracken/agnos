# 2026-11-06 — A write to a terminal channel drops the oldest record when the inbox is full, and the writer is never told

**Status:** 🟡 OPEN.
*(Filed from thoth **0.55.2**, which runs its TUI on a `#97` terminal end and paces its writes around this.)*
**Checked against:** agnos **94145d95** (1.57.17), `chan_queue` in `kernel/core/syscall.cyr`, the `write`#1 channel arm.
**Severity:** medium for any full-screen program in a terminal emulator. Output is lost with no error on either side.

## What happens

`write`#1 on a channel takes at most 64 bytes a call and hands them to `chan_queue`. The inbox holds 64 records. When it is full, `chan_queue` advances the reader's cursor over the oldest record and counts it in `chan_drops`, which ring 3 cannot read. The writer gets a full count back. It never blocks and never sees a short write.

That is right for a display channel, where the newest frame wins. It is wrong for a tty, where every byte matters: `write`#1 on a pipe has blocked since 1.57.9 for this reason.

## What was measured

All on 1.57.17, `-smp 2` under KVM, thoth `--agnos` on a PTY-mode endpoint with a ring-3 host as the emulator (`tests/agnos/tuihost.cyr` in thoth).

- **A reader that is not reading.** `thoth -p big:20000` wrote a 20 KB reply and exited 0. The host then read **4,037 bytes**. The writer saw nothing wrong.
- **A reader that is reading.** A host draining once every 16 ms, as a 60 Hz emulator does, received about **160 KB** of a scripted TUI session. With thoth waiting 17 ms after every 2 KB, the same session delivered about **310 KB**. Half the session was lost, and the host's text markers mostly still matched.
- **A frame's top rows.** Oldest-first loss takes the head of a burst, so at that rate the first frame arrived without its row 30 on every run.
- **A reader that stalls.** A paced writer loses bytes too, if the reader stops for longer than the inbox lasts. The test host's own `write`#1 to the console stalled it for 200 ms, when a line scrolled the framebuffer, and that cost a frame its head.

`pause`#14 is no back-pressure: with a CPU idle it returns at once, so a writer that yields between records can still outrun the reader.

## The ask

Back-pressure on a PTY-mode endpoint: `write`#1 on a terminal end, or on the emulator's end of one, blocks when the peer's inbox is full and `a4 == 0`, as a pipe write does, and with `a4 != 0` it takes what fits and returns the short count. `CH_SEND` and display channels keep drop-oldest.

Failing that, anything ring 3 can read: the peer's free slots, or the drop count.

## What thoth does meanwhile

It writes at most 2 KB, half an inbox, per 17 ms, a frame of a 60 Hz emulator. That is about 120 KB/s, so a repaint takes around 100 ms where a tty would take none. It is a guess at the emulator's rate, and it holds only while the emulator keeps up.
