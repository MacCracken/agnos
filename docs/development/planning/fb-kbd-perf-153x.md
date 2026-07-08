# 1.53.7 — FB console speed + keyboard input latency (1.53.x closeout burn)

> Two kernel-perf fixes cut together as **1.53.7**, riding one last iron burn to close the 1.53.x cycle.
> Grounded by the fb-kbd-perf probe (2026-07-08) against head 1.53.6. Both need iron validation
> (QEMU understates both — WC read-back is cheap under QEMU, and QEMU MSI-X ≠ AMD FCH 1022:1639).

## Bite 1 — keyboard input: interrupt-driven USB-HID (the net-RX-IRQ analog)

> **STATUS: code-complete + build-verified 2026-07-08** (build/agnos 1,380,224 B, multiboot2 OK).
> Touched: `boot_data.cyr` (`xhci_rx_isr[64]`), `pic.cyr` (`xhci_rx_handler` + `xhci_rx_isr_build` +
> `xhci_rx_irq_seen` latch + tick-fallback `hid_poll()` in `timer_handler`), `main.cyr` (build + IDT
> gate 0x51 + post-enum `pci_msix_arm_vector0(xhci_pci_idx, 0x51)`), `pci.cyr` (`pci_msix_arm_vector0`).
> `hid_poll` self-gates on `hid_kbd_slot_id==0` (safe pre-enum) + is cli-first (non-re-entrant vs the
> read-loop). REMAINING: QEMU agnsh smoke (no boot/kbd regression) → iron burn (dispositive: the
> `xhci_rx_irq_seen` LIVE line proves the MSI fires on Zen).

**Problem.** Input is **100 Hz timer-tick-paced, not event-driven** — the exact class as the pre-1.51.5
net RX floor. `hid_poll()` (usb/hid.cyr:410) drains the xHCI event ring but is called only from
`kb_has_key()` (keyboard.cyr:134) in the read loop; `kbd_read_blocking` (syscall.cyr:457) parks on `hlt`,
which on the USB-only target wakes only on the 100 Hz LAPIC timer, and `timer_handler` (pic.cyr:52) never
calls `hid_poll`. → up to ~10 ms per-key lag; worse under long syscalls.

**Fix.** Mirror the NIC RX MSI-X ISR (pic.cyr:177-245, wired main.cyr:156-157) exactly.

1. **boot_data.cyr:44** — add `var xhci_rx_isr[64];` (beside `nic_rx_isr[64]`).
2. **pic.cyr** (after `nic_rx_isr_build`) — add:
   - `var xhci_rx_irq_seen = 0;` (LIVE latch, printed once non-ISR — the dispositive "MSI fired on iron" proof, like `nic_rx_irq_seen`).
   - `fn xhci_rx_handler() { hid_poll(); xhci_rx_irq_seen = 1; apic_eoi(); return 0; }` — `hid_poll` is already ISR-safe (takes input_lock/cli-first, self-drains + re-arms; keyboard.cyr:47-50 anticipates this).
   - `fn xhci_rx_isr_build()` — byte-for-byte clone of `nic_rx_isr_build` (15-reg push → `call xhci_rx_handler` → 15-reg pop → iretq) into `&xhci_rx_isr`.
   - In `timer_handler`'s `pcpu_cpu()==0` block (after `hda_stream_service()`, pic.cyr:76): add `hid_poll();` — belt-and-suspenders fallback so a missed/masked MSI on real Zen degrades to today's tick-paced behavior, not a dead keyboard (net kept both paths too).
3. **main.cyr** (near line 157, beside the nic_rx wiring): `xhci_rx_isr_build(); idt_set_gate(&idt + 81 * 16, &xhci_rx_isr, 0x08, 0x8E);` (vector **0x51** = 81, next to net's 0x50).
4. **MSI-X arm — POST-ENUMERATION only.** `pci_enable_msix_unmasked` (pci.cyr:212) already programs the table but with **Message Data 0x40 + per-vector Mask = 1** (tbl+8=0x40, tbl+12=1 → no delivery). Add a helper `pci_msix_arm_vector0(idx, vec)` that recomputes the table addr (`pci_bar_64(idx,bir)+tbl_off`, as in pci_enable_msix_unmasked) and writes `tbl+8 = vec` (0x51), `tbl+12 = 0` (unmask). **Call it AFTER `hid_kbd_configure` succeeds (main.cyr:495)** — NOT during enumeration: `hid_poll` in the ISR would otherwise steal EP0 Transfer Events from the synchronous `xhci_wait_transfer_event` EP0 consumer used during control transfers (hid.cyr:405-409). Keep IMOD=250 µs (xhci.cyr:627) — it's the anti-storm de-bounce once the vector is live.

**Safeguards.** Single event-ring consumer → the residual timer-tick `hid_poll` + the ISR must not double-drain; `hid_poll`'s input_lock/cli already serializes (verify it no-ops re-entrantly like net_rx_lock trylock). SMM USB-legacy (syscall.cyr:481-486): `hlt` must still be reached between keys.

**Result.** Keystroke wakes `hlt` on DMA completion → 0-10 ms floor collapses to IRQ latency + 250 µs.

## Bite 2 — FB console: RAM shadow buffer (kill the WC read-back on scroll)

> **STATUS: code-complete + build-verified 2026-07-08** (build/agnos 1,383,328 B, multiboot2 OK — both bites).
> Touched: `pmm.cyr` (`pmm_alloc_2mb_run(n)` — top-down contiguous n-region alloc, capped at the 256 MB
> per-proc identity ceiling), `fb_console.cyr` (`fb_shadow`/`fb_shadow_size` globals; `fb_shadow_init` — size→
> alloc→one-time FB read-back sync; mirror stores in `fb_putc`/`fb_fill_cell`/`fb_console_clear`; `fb_scroll_up`
> shadow path = RAM memmove + write-only flush, original read-back kept as fallback), `main.cyr` (`fb_shadow_init()`
> after `fb_verify_wc`), `syscall.cyr` + `fb_console.cyr` (blit#39 + `fb_dbg_beacon` documented SHADOW EXEMPT).
> **Key finding**: the whole 0-256 MB pmm pool is identity-mapped WB in BOTH the kernel boot CR3 (0-1 GB via
> PD@0x3000 / 0-4 GB via 0x1000) AND every per-proc CR3 (proc.cyr:549 PD[0..127]) — so a shadow from that pool
> is `phys==VA` in kernel AND syscall-path `fb_putc`, no `vmm_map` needed. Fallback to direct-paint if the FB is
> absent or the run alloc fails (headless/low-RAM/fragmented). REMAINING: QEMU boot smoke (shadow inits + scroll
> correct + no crash) → iron burn (scroll feel on 1080p Zen; QEMU understates the WC-read win).

**Problem.** `fb_scroll_up` (fb_console.cyr:527-559) **reads the WC-mapped framebuffer back** every scroll
(`load64(src+x*8)` at :546) — ~1M uncacheable WC reads per newline at 1080p. The code already flags the fix
(fb_console.cyr:534-537: "we need a RAM-side shadow buffer"). Secondary: `fb_putc` (:721-817) paints glyphs
per-pixel to WC FB; `fb_print`/kprint issue one `fb_putc` per byte under `console_spin_lock`.

**Fix (medium).** Kernel-private **WB RAM shadow buffer** (pmm-allocated, pitch×height) — Linux simpledrm /
BSD rasops CPU-shadow model. Render (fb_putc / fill / clear / blit#39) into the shadow first, flush only the
touched rectangle to the WC FB store-only. Scroll = pure RAM memmove in the shadow (zero FB reads) + one
write-only flush. **Interim (smaller):** a per-scanline WB staging buffer for the scroll path alone (reuse
the `fb_scale_rowbuf` pattern at syscall.cyr:1593) — replaces the FB read-back without a full shadow.

**Gates.** ~8 MB @1080p / ~33 MB @4K → `pmm_alloc` with **fallback to direct-paint** if it fails (headless /
low-RAM). Allocate **post-pmm** (like the WC retry at main.cyr:288), NOT at the line-17 early paint. Early-boot
fault-bar (idt.cyr `fb_dbg_phys`) + `cp_fb` diagnostics keep writing FB directly (bypass the shadow). Shadow +
flush inside `console_spin_lock` (SMP). **Audit every FB writer** (fb_putc, fb_fill_cell, fb_scroll_up,
fb_console_clear, blit#39, fb_dbg_beacon) → shadow or explicitly exempt. `fb_phys` stays unexposed (hardened
posture preserved). Keep blit#39's store-only no-read-back discipline (syscall.cyr:1626).

## Validation
- QEMU build + smoke each bite (keyboard: agnsh live-key smoke; FB: scroll a full screen).
- **Iron burn (archaemenid) closes 1.53.x** — the DISPOSITIVE checks: `xhci_rx_irq_seen` LIVE line prints
  (MSI fired on real Zen, à la the `nic_rx: RX MSI LIVE` proof) + felt keystroke latency; scroll feel on 1080p
  Zen (QEMU understates the shadow win). Flash `--update-all` (kernel arc).
- Cut **1.53.7** on green (VERSION + CHANGELOG; user tags).
