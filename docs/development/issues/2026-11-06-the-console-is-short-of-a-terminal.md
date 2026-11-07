# 2026-11-06 — The console draws ASCII and three sequences, so a full-screen program brings its own terminal

**Status:** 🟡 OPEN.
*(Filed from thoth **0.55.2**, whose TUI runs on the console through a filter that stands in for all of this.)*
**Checked against:** agnos **94145d95** (1.57.17), `kernel/arch/x86_64/fb_console.cyr`, `serial_putc`.
**Severity:** feature gap, low. Nothing is lost. Each full-screen program on the console has to solve it again: cyim, chakshu and thoth all have.

## What happens

`fb_ansi_dispatch` takes SGR colour, CUP and ED 2, and its comment says to extend it as tools need. thoth's TUI needed the rest. Each row below is what the console does today, read from the source and confirmed on a 128x64 grid by screendump.

| Input | The console | What thoth's filter does instead |
|---|---|---|
| A byte above 0x7E | Drops it, so a `─` draws nothing and the rest of its row slides left | One ASCII cell per glyph |
| EL (`ESC[K`) | Ignores it, so a shorter row keeps the old row's tail | Spaces in the active background |
| ED 0 and 1 | Ignored | Not used |
| An OSC, DCS or APC | Drops the introducer and prints the text | Drops it all |
| `ESC[?25h`, or any cursor at all | None is drawn, at agnsh's prompt either | Paints a cell where the cursor rests |
| SGR 7 | Ignored | Explicit colours |
| A sequence of more than 8 parameters | Keeps 8, so `38;2;r;g;b;48;2;r;g;b` loses its background | Two sequences |
| The alternate screen | Ignored | A clear on the way in and on the way out |
| A Tab | Dropped | Spaces |
| The last column | Wraps at the next glyph, and a bottom-row LF scrolls the frame | Clips, and drops that LF |

## What it costs

Every console byte is also mirrored to COM1 through `serial_putc`, and `kbscan`-driven programs repaint often. Under KVM with the serial log going to a file, the console took 3.76 MB in 92 s, about 41 KB/s, and a full 128x64 frame of about 12 KB took around 0.3 s. On a machine with a real 16550 at 115200 the same frame would take about a second. On one with no UART the bounded poll exits at once, so this has not been measured there.

A line that scrolls costs far more: **200 ms** at 2048x2048 under KVM, measured at 199,821 to 201,848 µs across three boots, with the writer held for all of it. A line REPL on the bottom row prints about five lines a second there.

thoth holds a stream's paints to a quarter of its time, which took a 20 KB reply from over 90 s to under 5 s.

## The ask

In the order thoth would retire its filter:

1. EL 0, and ED 0 and 1.
2. Bytes above 0x7E: UTF-8 decoded, with a glyph from kashi where there is one and one replacement cell where there is not, so a row keeps its width.
3. A drawn cursor, with `ESC[?25h` and `ESC[?25l`.
4. A CSI of at least 16 parameters, SGR 7, and OSC and DCS swallowed whole.
5. A cheaper scroll, and a way to keep a process's console writes off COM1, or a look at what mirroring a frame should cost.

The alternate screen is the one thoth can live without.

## What thoth does meanwhile

`src/term.cyr` carries the filter, with its rules in `docs/architecture/006-the-agnos-console-is-not-a-terminal.md`. Each row above that the kernel takes over can come out of it.
