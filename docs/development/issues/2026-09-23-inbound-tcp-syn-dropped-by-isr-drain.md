# 2026-09-23 — inbound TCP: a SYN drained in interrupt context is dropped, so ring-3 servers rarely accept

**Status:** 🟡 **OPEN** — fixed by step **S4** (the passive open served in interrupt context through an IRQ-save `tcp_slot_claim`, a boot-time per-slot pool, the TX/loopback locks that make the `-smp 4` net path gated, half-close kept until accept). Not in 1.57.6. The Path 2 foundation this step builds on — per-process syscall kernel stacks, the deferred `on_cpu` release, preempt-disabling spinlocks, region-7 guard pages (bites S3.1–S3.3) — landed in **1.57.6**; see `docs/development/planning/blocking-syscall-concurrency.md` § Path 2 plan and the roadmap's 1.57.x table.
**Filed by:** daimon (the AGNOS agent orchestrator), while mapping its agent lifecycle onto agnos
for daimon 2.4.0. daimon's HTTP API is its only control surface, so on agnos it is unreachable.
**Checked against:** agnos **1.57.5**: the prebuilt `build/agnos` of 2026-09-21, and the source in
the working tree: `kernel/core/net_tcp.cyr`, `kernel/core/net_ingress.cyr`,
`kernel/arch/x86_64/pic.cyr`, `kernel/core/syscall.cyr`. Every line cited below was opened.
**Consumer impact:** every ring-3 TCP server: daimon, anything on sandhi's server loop, and any accept
loop. Measured under QEMU (virtio-net, SLIRP host forwarding). Not tried on iron. The code path below
is NIC-independent: `nic_rx_handler` also serves the r8169.

> A ring-3 server on 1.57.5 accepts almost no inbound connections. A minimal server that waits
> between accept polls accepted **0 of 12**; one that busy-polls accepted **2 of 12**. Once a
> connection IS accepted its data is always there on the first `sock_recv`#49: established-connection
> delivery works, and only the passive open fails.
>
> The passive open returns early in interrupt context (`net_tcp.cyr:768`), and the RX ring is drained
> in interrupt context by the timer tick and by the NIC's MSI handler. A SYN that an interrupt
> dequeues is consumed and discarded, not left for a syscall-context poll, and its retransmit meets
> the same drain.

---

## 1. Measurements

Each row: 12 sequential connections from the host to `127.0.0.1:18300` (forwarded to the guest's
8090), a fresh connection each, one `GET` request, 15 s timeout.

| server in the guest | NIC interrupts | accepted | notes |
|---|---|---:|---|
| minimal server, `pause`#14 between `sock_accept`#57 polls | MSI-X (QEMU default) | **0 / 12** | the server never logged an accept |
| same | off (`virtio-net-pci,...,vectors=0`) | **0 / 12** | only the timer's drain is left |
| minimal server, busy-polling `sock_accept`#57 | MSI-X | **2 / 12** | each accepted after ~6 s |
| same | off | **9 / 12** | 3 within 0.3 s, 6 after ~6 s, 3 never |
| daimon 2.4.0-dev (sandhi's sync accept loop) | MSI-X | **8 / 20** | 2 of the 8 after 5.6–5.9 s |

The ~6 s delays are SLIRP retransmitting the SYN: the first SYNs meet the drain and are lost, and a
later one reaches a syscall-context `net_poll` by chance.

In every accepted case the request was already queued: the minimal server logged `polls=1`, 20 ms from
accept to data. The receive path is not the problem.

## 2. The mechanism, from the code

- `kernel/core/net_tcp.cyr:768`, `net_handle_tcp`'s passive-open branch:
  `if (net_in_isr != 0) { return 0; }`. Its comment reads: *"DROPPING THE SYN IS CORRECT TCP, not a
  degradation: the peer retransmits, and the retry is picked up by net_poll() from syscall context (a
  server in an accept loop polls) or by a later tick that does not collide with the heap."*
- `kernel/core/net_ingress.cyr:474`, `net_rx_drain_isr()` sets `net_in_isr = 1` around
  `net_rx_drain()`.
- `kernel/arch/x86_64/pic.cyr:136`: `timer_handler` calls `net_rx_drain_isr()` on every tick.
- `kernel/arch/x86_64/pic.cyr:266`: `nic_rx_handler` calls it on every RX MSI.

**The comment's premise does not hold.** The retry is drained by an interrupt too, and the drain
does not *defer* a refused SYN: `net_handle_tcp` returns, and the frame has already been taken off the
ring. With the timer at 100 Hz and the MSI firing on arrival, the interrupt nearly always gets there
first:
- a server that waits (`pause`#14, `sleep_ms`#41, `epoll_wait`) is idle with IF=1 when the SYN arrives;
- a busy-polling server spends its time in syscalls (IF=0), but the pending MSI fires at SYSRET,
  before the next `#57` polls.

The measurements follow that ordering: the less time the ring waits for an interrupt, the more
connections survive.

## 3. What would fix it (for your judgement)

- **Do not allocate in the passive open.** The conn table is 8 fixed slots, and the two buffers the
  passive open `kmalloc`s are `TCP_RX_RING` = 2048 and `TCP_RETX_BUF` = 1460 bytes
  (`net_tcp.cyr:67`, `:70`). Static per-slot buffers (8 × 3508 B, about 28 KB) would remove the heap
  lock from this path, and with it the reason to refuse the SYN in interrupt context.
- **Or defer rather than drop:** keep the SYN, or mark the slot, for the next syscall-context
  `net_poll`.

Either way, a listening server should see the connection on its next `#57`.

## 4. Reproduction

- The minimal server below, built with `cyrius build --agnos`, seeded as `/bin/agnsh` in the same image
  layout `scripts/smoke/agnsh-smoke.sh` builds.
- QEMU: agnsh-smoke's command line, plus
  `-netdev user,id=n0,hostfwd=tcp:127.0.0.1:18300-:8090 -device virtio-net-pci,netdev=n0`. Append
  `,vectors=0` to the device for the MSI-X-off rows.
- Client: 12 sequential connections to `127.0.0.1:18300`, each sending
  `GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n`, 15 s timeout.
- For the busy-polling rows, replace the `pause` branch with `if (cid < 0) { continue; }`.

```cyrius
include "lib/string.cyr"
include "lib/alloc.cyr"
include "lib/syscalls.cyr"

fn put(s) { syscall(SYS_WRITE, 1, s, strlen(s)); return 0; }
fn putn(v) {
    var b: u8[24];
    var i = 23;
    store8(&b + i, 0);
    if (v < 0) { put("-"); v = 0 - v; }
    if (v == 0) { put("0"); return 0; }
    while (v > 0) { i = i - 1; store8(&b + i, 48 + v % 10); v = v / 10; }
    put(&b + i);
    return 0;
}

alloc_init();
var lid = syscall(SYS_SOCK_LISTEN, 8090);
put("minisrv listening on 8090\n");
var buf = alloc(4096);
var resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
var n = 0;
while (1 == 1) {
    var cid = sys_sock_accept(lid);
    if (cid < 0) {
        sys_pause();
        continue;
    }
    n = n + 1;
    var t0 = sys_uptime_ms();
    put("MS acc #"); putn(n); put(" cid="); putn(cid); put(" t="); putn(t0); put("\n");
    var got = 0;
    var polls = 0;
    while (got == 0) {
        var r = syscall(SYS_SOCK_RECV, cid, buf, 4096);
        polls = polls + 1;
        if (r > 0) { got = r; }
        elif (r < 0) { got = 0 - 1; }
        elif (sys_uptime_ms() - t0 > 10000) { got = 0 - 2; }
        else { sys_pause(); }
    }
    put("MS data #"); putn(n); put(" got="); putn(got); put(" polls="); putn(polls);
    put(" dt="); putn(sys_uptime_ms() - t0); put("\n");
    if (got > 0) { syscall(SYS_SOCK_SEND, cid, resp, strlen(resp)); }
    sys_sock_close(cid);
}
```

## 5. What daimon does meanwhile

Nothing can route around this from ring 3. daimon 2.4.0 maps its agent lifecycle onto agnos and tests
it inside the guest, where no inbound TCP is needed. Its HTTP API on agnos waits on this fix.

daimon has a separate problem of its own on agnos, not counted above: sandhi's sync loop waits up to
30 s on a connection that sends nothing. daimon will fix that on its side.
