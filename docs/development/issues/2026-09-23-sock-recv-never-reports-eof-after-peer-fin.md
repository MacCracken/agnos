# 2026-09-23 — `sock_recv`#49 never reports the end of a stream the peer has closed

**Status:** 🟡 **OPEN** — fixed by step **S4** (`tcp_conn_eof`: CLOSE_WAIT with a drained ring answers -1; `tcp_send` allowed in CLOSE_WAIT; `tcp_close` from CLOSE_WAIT sends our FIN). Not in 1.57.6. The Path 2 foundation this step builds on — per-process syscall kernel stacks, the deferred `on_cpu` release, preempt-disabling spinlocks, region-7 guard pages (bites S3.1–S3.3) — landed in **1.57.6**; see `docs/development/planning/blocking-syscall-concurrency.md` § Path 2 plan and the roadmap's 1.57.x table.
**Filed by:** daimon (the AGNOS agent orchestrator), testing its HTTP API inside the guest with a
client that reads each response until the server closes.
**Checked against:** agnos **1.57.5**: `kernel/core/net_tcp.cyr` (`net_handle_tcp`'s FIN handling,
`tcp_recv`, `tcp_conn_dead`) and the `#49` arm in `kernel/core/syscall.cyr`, read in the working
tree.
**Consumer impact:** every ring-3 client that reads to the end of a stream: an HTTP/1.0 or
`Connection: close` response, any protocol framed by close. The cyrius peer's
`_agnos_sock_recv_block` (which `sys_read` on a socket uses) waits out its 30 s deadline instead.

> When the peer sends FIN on an established connection, `net_handle_tcp` ACKs it and moves the
> connection to CLOSE_WAIT (state 4) (`store64(cb, 4)`, the ESTABLISHED arm's FIN branch in
> `net_tcp.cyr`). `#49` reports EOF (-1) only when `tcp_conn_dead` is true, which is state 0
> alone. So once the buffered bytes are drained, a CLOSE_WAIT connection answers **0 —
> "nothing yet" — forever**. The reader cannot tell a closed peer from a slow one.

---

## Measured

daimon's guest test (1.57.5 under QEMU). A client in the guest makes 18 sequential HTTP requests to
daimon on the guest's own address. daimon answers each and closes the connection (`sock_close`#50,
which sends FIN).

- **Reading until `#49` returns -1:** every request waited its full 15 s timeout after the whole
  response had arrived. The run did not finish in the launcher's 120 s budget.
- **Reading until the response's `Content-Length` is satisfied:** all 17 checks passed, and the
  whole guest test finished in 55 s.

## The ask

`#49`: when the receive ring is empty and the peer's FIN has been received (CLOSE_WAIT, or any state
past it), return -1, the EOF answer, as for a dead connection. This is the BSD `recv() == 0` moment.
`tcp_readable` (the epoll readiness probe) should agree, so a reader waiting on epoll wakes for it.

## What daimon does meanwhile

daimon's guest test client reads responses to their `Content-Length`. daimon's server does not
depend on EOF: it reads a request to its own framing and closes after answering.
