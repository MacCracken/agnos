# Net concurrency — the lock chain, the TCP slot lifecycle, and interrupt-context serving

Since **1.57.7 (S4)**. Code: `kernel/core/net*.cyr`, `virtio_net.cyr`, `r8169.cyr`, the lock functions in
`kernel/arch/x86_64/smp.cyr` (GLOBAL LOCK ORDER banner). Gates: `scripts/smoke/tcp-smoke.sh` (TCP_SELFTEST),
`loopback-smoke.sh`, `tcp-listen-smoke.sh`, `tcp-inbound-smoke.sh` (tests/tcpin, three variants).

## 1. Contexts

The net stack runs from: the BSP timer ISR drain and the NIC MSI handler (`net_rx_drain_isr`, the named
interrupt-context seam — it may transmit), every CPU's net syscalls (`net_poll`), the loopback drain (from any
`net_poll`; no interrupt drains the lo queue), and kmain callers (DHCP, selftests). After S3b `#43` children are
unpinned, so all of these can run at once on different CPUs.

## 2. The lock chain

`heap_lock < pmm_lock < tcp_tab_lock < net_tx_lock < lo_q_lock < sched_lock`; `udp_lock` is a sibling leaf at the
lo_q rank, never held with another net lock. `net_rx_lock` and `lo_drain_lock` are try-locks outside the order.

- **IRQ-saved.** The four spinlocks are taken only through `tcp_lock/tcp_unlock`, `net_tx_begin/end`,
  `lo_q_begin/end`, `udp_begin/end`, which `kbd_irq_save()` first — a holder always runs IF=0, so an ISR never
  spins on a lock its own CPU holds. Nobody calls the `*_spin_lock` functions directly.
- **`tcp_tab_lock` is NOT a leaf**: it is held across frame build + `net_tx`. Every conn-table mutation (the demux
  included) happens under it; arm + transmit + SND.NXT advance are one hold, so a retransmit never reads a torn
  segment.
- **Under any net lock, never**: `net_poll`/`net_rx_drain`/`net_lo_drain` (a nested demux re-takes `tcp_tab_lock`
  on the same CPU at IF=0 — a hard hang), heap/pmm/console/fs/vfs/proctab or any non-IRQ-saved lock,
  `kmalloc`/`kfree`, `kprint`. Diagnostics use the lock-free latch (`net_lk_latch`: klug + COM1).
- **Worst-case hold**: `tcp_tab_lock` across 8 frame builds (retx tick, a LISTEN close's RSTs) or one 2 KB ring
  copy (`tcp_recv`); another CPU's ISR spins that long at IF=0.
- **Witnesses** (best-effort, plain RMWs): `net: lock overlap` (two holders inside `tcp_lock`/`net_tx_begin`) and
  `net: lock missing` (`nic_send`/`net_lo_enqueue`/`tcp_send_pkt_seq` without their lock). Both are
  `SMOKE_INVARIANT_DENY` lines. Deterministic at -smp 1 for a frame built outside its lock; cross-CPU only when the
  counters interleave.

## 3. Slot lifecycle

- `tcp_slot_claim_locked` is the **only 0→nonzero state transition**: every field initialised, pool buffers bound,
  `tcp_conn_gen[id]` bumped, the state published LAST. `tcp_slot_claim` (the locking form) is only for callers that
  hold no net lock; inside the demux it would self-deadlock.
- Release (`tcp_slot_release_locked`): disarm → unbind the rx ring → CLOSED last, nothing after; cb+136 stays bound.
  RST / retransmit exhaustion: disarm → CLOSED, **no unbind** (a dead conn's queued bytes stay readable).
- **The generation**: a waiter snapshots `gen` and asks `tcp_conn_check(id, g0)` (both reads in one hold): −1 means
  the slot was recycled — e.g. RST'd and re-claimed, even ESTABLISHED, by an interrupt-time passive open — and is
  someone else's now. `tcp_slot_release_if(id, state, gen)` releases only a slot still in that state and generation.
- **1.57.7 (S5) — owner and held slots.** The release tail also UNSTAMPS the owner (+152/+160 = 0); the RST and
  exhaustion sites do not, so an OWNED dead conn is **held** (not reusable) until its owner's `#50` or death —
  `tcp_slot_reusable` is the one reuse predicate (allocator and passive-reserve counter both use it). Owned-path
  waiters snapshot (tag, epoch, gen) and re-check with `tcp_same_locked`. See
  [`socket-ownership-and-loopback.md`](socket-ownership-and-loopback.md).

## 4. The pool

`tcp_pool_init` (main.cyr, after heap_init + the direct map) kmallocs 8 rx rings + 8 retx hold buffers once. Slot i
↔ `tcp_pool_rx[i]`/`tcp_pool_retx[i]`; cb+136 is never 0 on a claimed slot; cb+48 is 0 on LISTEN and released
slots; nothing is ever freed, and the KVAs are direct-map (valid under every CR3). So no TCP path allocates, and a
passive open is served **in interrupt context** — the 1.56.51 ISR refusal (which dropped every SYN the drain saw,
and the retransmit met the same drain) is gone.

**1.57.7 (S5) — the UDP pool.** `udp_pool_init` (main.cyr, right after `tcp_pool_init`, before `dhcp_init`'s first
bind) kmallocs 8 × 1024 B listener buffers once; slot i ↔ `udp_pool_buf[i]`, bound by a bind and never freed, so
bind/unbind/`udp_release_pid` are heap-free and no buffer can be freed under an ISR copy.

## 5. Passive backlog

At most `TCP_SYNRCVD_MAX` = 4 SYN_RCVD slots, and a passive child never takes the last free slot
(`TCP_PASSIVE_RESERVE` = 1), so a connect/listen always has a slot. A refused SYN is dropped; the peer retransmits.
The duplicate-LISTEN check is inside the claim. A LISTEN close RST|ACKs its un-accepted ESTABLISHED/CLOSE_WAIT
children and drops SYN_RCVD ones, atomically with its own release; a state-6 claim re-checks its parent (C7).

## 6. Half-close

A FIN before accept keeps the child (CLOSE_WAIT); `tcp_accept` returns 2|4 children. CLOSE_WAIT is a SENDING state.
EOF = `{dead} ∪ {CLOSE_WAIT with an empty ring}` (`tcp_conn_eof`, `tcp_readable`, `sock_recv`#49 → −1); data always
drains before EOF. `tcp_close` from 2 or 4 sends our FIN|ACK **once** and releases in the same hold. CLOSE_WAIT has
its own demux arm: RST closes it, a re-sent FIN is re-ACKed.

## 7. The loopback drain

`net_lo_drain` demuxes each frame **in place**: the slot still counts as occupied during the demux, and is freed
after it (before 1.57.7 it was freed first, so a reply enqueued by the demux could overwrite the frame being
parsed). `lo_drain_lock` makes it the single consumer; the drain-unlock-recheck picks up a frame enqueued while it
held the try-lock. `net_poll` runs `tcp_retx_tick` before its NIC-less early return.

## 8. virtio TX slots and DMA CPU pointers

Each virtio TX descriptor owns its own 2048-byte slot buffer (16, or 32 when the TX queue has ≥ 32 entries);
reclaim is by the `used.idx` count and assumes in-order completion (true of QEMU and real devices, not guaranteed
by the spec); a full ring refuses the frame (−1) and latches `virtio-net: TX ring full - frame dropped` (not a deny
pattern). Every CPU access to a `pmm_alloc`'d NIC page goes through `net_dma_kva(phys)` (the direct map): a ring-3
PT_LOAD can shadow the identity VA under its own CR3, and the ISR drain / TX run under whatever CR3 is live.
Registers and descriptor address fields keep phys. r8169 is converted too — **iron-pending** (QEMU has no RTL8168
model: built, gated by build + regressions, NOT burned).

## 9. User memory under a net lock

Only a range that passed `is_user_range` in the same syscall (mapped): agnos has no address-space-sharing unmapper,
demand paging or CoW, so it cannot vanish mid-copy (`tcp_recv`'s copy-out and `tcp_send`'s arm copy-in).

## 10. Not modelled / residual

- TIME_WAIT (a peer whose final ACK is lost retransmits its FIN into a released slot and times out); SYN cookies.
  (FIN retransmit and FIN_WAIT/LAST_ACK ARE modelled since 1.57.7 S6 — §11.)
- The same identity-VA class in the block drivers (virtio_blk, NVMe, AHCI) and xHCI (HID rings serviced from the
  0x51 ISR, MSC buffers): audited at S4.8b, not converted — over the ~60-site stop rule (see the S4 report).

## 11. The timer-driven half, waits, graceful close (1.57.7 S6)

- **`net_tick()`** (net_ingress.cyr) runs from `timer_handler` on EVERY CPU inside the ISR preempt bracket: the
  retransmit scan (`tcp_retx_tick`, µs RTOs with the rebase rule — kernel-clocks.md), the held-FIN-slot timers and
  the loopback drain. A blocked sender cannot poll, so this is what resends for it. `net_tick_lock` is a TRY lock:
  one CPU runs the body at a time, a busy tick skips. **`net_tick_pause()/resume()`** is the selftest exclusion: after
  pause returns no body runs on any CPU (a `kbd_irq_save` bracket masks only its own CPU); TCP_SELFTEST runs inside it.
- **Waits** (blocking-waits.md § Network waits): #47/#48 block on `WK_TCP|cid`, #55/#100 on `WK_ICMP|pid`. The demux
  sets `tcp_demux_wake` under `tcp_tab_lock`; `net_handle_tcp` wakes after the unlock.
- **`icmp_lock`** is an IRQ-saved SIBLING LEAF (udp rank): the per-pid reply slots and the ICMP counters. Never held
  with a chain lock; the echo reply's `net_tx` hold ends before the counter update.
- **Graceful close:** `tcp_close_locked` turns ESTABLISHED/CLOSE_WAIT into a KERNEL-HELD FIN slot (state 3, tag 0,
  ring unbound, FIN armed); the timer scan retransmits it; the state-3 demux arm consumes and discards data, ACKs the
  peer's FIN and releases on (FIN ACKed ∧ peer FIN); RST, exhaustion and an 8 s FIN_WAIT_2 also release it.
  **Orphan reclaim:** `tcp_alloc_conn_slot` releases a state-3 tag-0 slot when nothing else is free, and
  `tcp_free_slots_locked` counts it, so the passive reserve stays true; a state-1 claim supersedes an orphan on the
  same 4-tuple.
  **Close over a held data segment** (1.57.7 ENDFIX, S6-R1): when a data segment (0x18) is still unACKed — #48's D6
  return, a lifecycle ABORT, a kill blocked in #48 — the FIN is FOLDED into it (retx flags 0x19; retx_seq, retx_len,
  SND.UNA kept; SND.NXT + 1) instead of re-arming a flag-only FIN over it, which silently dropped the bytes. The
  ACK-covers block counts the FIN's phantom byte and the partial-ACK trim accepts 0x19 (tcp-smoke arm `finfold`).
- **Send-side correctness in the demux:** the window is stored only from an ACK not older than SND.UNA (stale-window
  guard); a partial ACK trims the held segment (forward byte loop); a window-opening ACK makes the held probe due now
  (count 0) and wakes the sender; a zero-window ACK of a held data segment caps the retry count at 4 (persist: a live
  reader is never declared dead).
