# Kernel Security Hardening — invariants, findings, standing gaps

The single kernel-security doc: the trust boundary an auditor reasons under, every hardening
finding and its disposition, and what is still open.

---

## 1 · The four invariants

Every finding is judged against these. A claim that contradicts one of them is not a finding.

1. **Single-threaded, single-core, no preemption during a syscall.** SYSCALL masks IF via SFMASK.
   There is no locking and shared kernel scratch is relied upon. **"A race" is not a valid finding.**
2. **Per-process CR3 mirrors a *superset* of the kernel map** (0–4 GB + MMIO/BARs). A kernel
   dereference of a bad user pointer therefore reads real kernel/MMIO memory, or faults in ring 0
   and panics. It does not fault harmlessly.
3. **Every legitimate user address is below 1 GB.** ELF segments `p_vaddr >= 2 MB` and
   `p_memsz <= 32 MB`; per-pid stacks at `0x800000 + pid*0x400000`, under 72 MB for the 16-proc
   cap; mmap arena `[0x10000000, 0x40000000)`. MMIO/BARs (NVMe ~0xC0000000) and the 1–4 GB PDPT
   range sit **above** it. `pmm_alloc_2mb` hands out 2–14 MB.
4. **The trust boundary is `is_user_ptr` / `is_user_range` in `kernel/core/syscall.cyr`.**
   The `getdents(29)` `VFS_EXT2_DIR` tag check is the precedent every fd-type check follows.

Corollary of (2)+(3): an unbounded `is_user_ptr` lets ring 3 aim a kernel load/store at MMIO.
That was finding #4.

---

## 2 · The 1.41.5 audit — 2026-06-03, agnos 1.41.5, x86_64

6-dimension multi-agent pass: syscall ingress · FS backends · exec/proc · memory-safety sweep ·
refactor · net-ingress recheck. Each finding adversarially verified for ring-3 reachability plus a
behavior-preserving fix. Each HIGH re-derived against source by hand before code changed.

**26 findings verified · 0 refuted · 15 fixed (all 10 HIGH + 2 MED + 3 LOW) · 8 deferred.**
The HIGH cluster cross-converged from two independent dimensions.

Context: the 1.41.x shell-separation arc put a real userland shell (`agnsh`) on the far side of the
syscall boundary, and 1.41.3 added nine FS syscalls taking user pointers — ring-3 → ring-0 became a
genuine attack surface.

### The ten HIGH findings

| # | File | Mechanism | Fix |
|---|------|-----------|-----|
| 1/8 | syscall.cyr | `epoll_ctl(20)` never checks `ktag==VFS_EPOLL` → **arbitrary kernel WRITE** (a foreign fd's `payload[2]` is a heap pointer or inode number) | tag check |
| 2 | syscall.cyr | `epoll_wait(21)` same missing check → **arbitrary kernel READ** + an attacker-driven loop count | tag check |
| 3/10 | syscall.cyr | watched fd (`arg3`) stored unbounded, used as `&vfs_table + wfd*32` → OOB kernel read | bound at insert (epoll_ctl) **and** at deref (epoll_wait) |
| 4 | syscall.cyr | `is_user_ptr`/`is_user_range` had **no upper bound** → ring 3 aims a kernel load/store at MMIO or high memory | 1 GB ceiling |
| 5 | syscall.cyr | `sigprocmask(17)` / `signalfd(18)` validate a **bare pointer** then load/store 8 bytes | `is_user_range(p, 8)` |
| 6 | vfs.cyr / ext2.cyr | unbounded basename overflows `ext2_dir_buf[512]` (4 KB) on fresh-block dir append — mkdir / create / rename-dst / link-dst | 255-byte cap |
| 7 | vfs.cyr | `vfs_ext2_parent` didn't cap basename at ext2's 255 max | same cap at **ONE ingress**, covering every FS-mutation syscall |
| 9 | syscall.cyr / elf.cyr | `spawn(3)` passes user `elf_addr`/`elf_size` into `elf_load`'s load8/load64 with **no range check** → kernel-memory disclosure | `is_user_range` before `elf_load` |

### The MED/LOW fixes

| # | Sev | File | Issue → fix |
|---|-----|------|-------------|
| 12 | MED | proc.cyr | `sys_mmap`'s `length + 0x1FFFFF` **wraps on a near-u64 length**, defeating the arena-ceiling guard → length cap before rounding |
| 13 | MED | elf.cyr | ELF `p_vaddr` had no upper bound → a segment can land in the mmap arena and **alias a future mmap** → cap `p_vaddr + p_memsz <= 0x10000000` on **both** load paths |
| 15 | LOW | syscall.cyr | `epoll_create(19)` stored `kmalloc(128)` with no null check → allocate before claiming the slot; −1 on OOM |
| 17 | LOW | syscall.cyr | `epoll_wait` validated the events buffer with a bare pointer before writing up to ~192 B → `is_user_range(arg2, arg3*12)` |
| 18 | LOW | syscall.cyr | `timerfd_settime(23)` operated on an fd slot with no tag check → `ktag==VFS_TIMERFD` |
| 19 | LOW | net_dns.cyr | `dns_qname_encode` had no overall length cap before its 320 B `qbuf` → 255-byte hostname cap |
| 20 | LOW | fatfs.cyr | `fatfs_read` lacked the FAT-chain cycle guard `exfat_read` has (a cycle re-reads to maxlen) → iteration counter |
| 26 | LOW | syscall.cyr | `epoll_ctl` op==2 clears ALL watches, not just `arg3` → comment clarified |

### The eight deferred, each with its reason

| # | Sev | Issue | Reason deferred |
|---|-----|-------|-----------------|
| 11 | MED | A malformed on-disk ELF **leaks per-process page tables and mapped 2 MB pages** — the failure paths have no teardown | needs teardown or a pre-pass inside the iron-validated exec path; own focused bite → **fixed at 1.41.6** |
| 16 | LOW | `proc_reap` reclaims the proc-table slot **only when it is the TOP slot**; a non-top reap leaks toward the 16-proc cap | non-triggering under the current run-to-completion single-foreground model |
| 14 | LOW | `stack_canary_check` coverage inconsistent across return paths | not a vulnerability (audit: `reach=false`); folds into #23 |
| 21 | LOW | `ksyscall` if-ladder dispatches syscall numbers out of numeric order | byte-identical but a **large diff in a security-critical file**; own pure-refactor cut |
| 22 | LOW | FS syscalls duplicate validate + resolve_mount + per-backend shape | audit returned `fix_sound=false` — equivalence not provable by inspection |
| 23 | LOW | `stack_canary_check` scattered; could collapse to one tail check | `fix_sound=false` — same |
| 24 | LOW | dead `return 0` after `arch_halt()` in reboot | cosmetic; left as a defensive no-op |
| 25 | LOW | Tier-1/2/3/4 section comments no longer describe contiguous ranges | folds into the #21 reorder |

### The principle

**A hardening cut must NOT carry behavior-equivalent rewrites of the file it is hardening.**
#22 and #23 both came back `fix_sound=false` — their equivalence is not provable by inspection —
and #21 is a large diff in the exact security-critical dispatcher the cut is changing. They belong
in a **separate pure-refactor cut** validated independently, so a refactor typo can never hide
behind a security diff.

### Validation (QEMU, x86_64)

`scripts/sweep.sh` **7/7** (FAT/exFAT read+write, ext2 W1–W5, exec-from-disk) — no behavior
regression from any of the 15 fixes · `FS_SYSCALL_SELFTEST` → `fssys: ALL PASS` (mkdir /
open-O_CREAT / stat / rename / getdents / unlink / rmdir through `ksyscall` under the new ceiling
and basename cap; scratch via `pmm_alloc_2mb` at 2–14 MB, below the ceiling) ·
`scripts/smoke/agnsh-smoke.sh` **PASS** (real ring-3 `agnsh` to prompt; read(fd=0)/write/mmap user
pointers all inside `[0x200000, 0x40000000)`) · `check.sh` **11/11** ·
build **1,062,872 → 1,063,016 B**.

Full audit: agnosticos [`prior-art/kernel-1415-hardening-audit.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/prior-art/kernel-1415-hardening-audit.md).

---

## 3 · Follow-on hardening cuts

**1.41.6 — the deferred half, done as its own pass.** First a safety net:
`SYSCALL_HARDEN_SELFTEST` → `shsys: ALL PASS`, the **first** regression coverage for
epoll/timerfd/signalfd; drives the 1.41.5 rejection paths through `ksyscall` (1 GB ceiling
valid/ceiling/low, epoll type-confusion + out-of-range watched fd, timerfd type-confusion,
signalfd, the 256-byte basename rejection). Then: **#11 fixed** — both loaders now run a
**validation pre-pass over all segments before allocating the address space**, so a malformed ELF
is rejected with zero allocations to leak (chosen over adding teardown to every failure path; a
rare OOM *mid-mapping* leak remains a separate lower-priority class). **#22** partially taken as
pure factoring (`sc_path_ok(ptr,len)`; identical `FS_FAT`/`FS_EXFAT` arms collapsed) — the deeper
resolve-plus-backend dedup deliberately not done. **#21** taken: only the trailing 1.41.3 FS group
was out of order (`30, 29, 33, 31, 32` → `29, 30, 31, 32, 33`); verified every number 0–33 appears
exactly once. **#23/#14** documented, not changed: `ksyscall` has no local array buffer for a smash
to corrupt, so its canary is a *callee*-smash backstop; leaf functions that own buffers
(e.g. `elf_load`) carry their own. Build → **1,063,944 B**.

**1.41.10 — the `VFS_SEC_WFILE` write-fd, a surface the 1.41.5 sweep predated** (1.41.7 added it
after). 3-dimension adversarial audit, 4 findings, 0 refuted; the regression dimension confirmed
every 1.41.5 fix intact after the 1.41.6 refactors.
- **Pool leak → ring-3 DoS (MED).** The write-fd is backed by a finite **4-slot static pool**
  released only by `vfs_close`; process exit and `proc_reap` never walked the fd table, so ring 3
  could open four FAT/exFAT files, `exit()` without closing, and **permanently exhaust the pool
  until reboot**. `proc_reap` now sweeps fds 3–31 of the exiting proc and `vfs_close`s any open
  (idempotent, so a well-behaved program sees a no-op).
- **Write-cap spin (MED).** `vfs_sec_wfile_write` returned `0` at the 4 KB whole-file cap, so a
  conforming `while (off < total) off += write(...)` loop **spins forever** past 4 KB. Now returns
  −1 when the cap is full and bytes remain.
- **Directory overwrite → FS corruption (MED).** A write-open resolving to an existing **directory**
  flushed through `fatfs_write_file`/`exfat_write_file`, clearing the dirent and freeing the cluster
  chain. Both backends now refuse: FAT checks `attr & 0x10` at the matched dirent +11; exFAT
  re-reads the set primary's `FileAttributes` +4 (mirroring `exfat_rmdir`).
- **1.41.11 (LOW).** `vfs_close` swallowed the write-fd flush result — a failed backend write
  (ENOSPC, write-protected volume) reported **success** to `close()` while the data was dropped.
  Now returns the flush rc; the slot is still reclaimed on failure.

Build 1,070,288 → **1,070,720 B**. Gates across both cuts: sweep 7/7, `fssys`/`shsys` ALL PASS,
agnsh-smoke PASS, check.sh 11/11.

---

## 4 · The ring-3 divide-by-zero hard-lock

`kernel/arch/x86_64/idt.cyr` listed **vector 0 (#DE)** among *"deliberately NOT installed: 0-5, 7,
9, 15-31"*. The bare-`iretq` default returned straight to the faulting `idiv`, which divided by zero
again, forever, **with interrupts still enabled**.

**Any userland divide by zero froze agnos** — no fault message, no CMOS stamp, no prompt, hard power
cycle. Found by a burn: the rung-10 flash ran `/bin/gputri --bench`, which computed
`(gpu * 100) / cpu` with a cpu timing of `0`; the machine stopped mid-line.

Vector 0 now joins **both** the curated installed set **and** the `{6,13,14}` ring-3 kill set — a
faulting proc dies and `agnsh` returns, the routing `#UD`/`#GP`/`#PF` already had. `#DE` pushes no
error code, so it takes `csoff = 8` like `#UD`.

Gate `scripts/de-smoke.sh` **3/3**: a `DE_SELFTEST` hook builds a ring-3 ELF whose whole body is
`xor ecx,ecx ; div ecx`, execs it, asserts survival — `run: exit 128`, proc slot reclaimed, boot
reaches a prompt. **MUTATION-CALIBRATED: putting vector 0 back on the bare default reproduces the
freeze exactly** (opening line prints, then nothing, never reaches a prompt) — what the operator saw
on iron.

The *"installing all 32 halts boot"* caveat in idt.cyr is real but does not apply: nothing
legitimately divides by zero at boot, unlike `#NM`/7 (fires on first SSE use) or the reserved/NMI
slots.

---

## 5 · 1.50.7 — process-isolation hardening (2026-06-29)

Two findings surfaced by the kavach↔agnos compat audit. Both capability/ownership, no Linux
projection.

- **`proc_get_ppid` was a STUB returning 0 always**, so `kill#16`'s "a non-init proc may signal only
  itself or its children" gate was **INERT** — every proc's parent read as init. Fixed with a flat
  `proc_ppid[16]` (parallel to `proc_cs[16]`/`proc_ss[16]`), filled at `proc_create_user` from the
  creator pid — the single inheritance point every user proc is born through (elf_load /
  elf_load_from_file / spawn), the same source `vfs_fd_inherit` uses — reset to 0 in
  `proc_alloc_slot`. Authorization extracted into a testable `proc_may_signal(caller, target)`.
  Guardrail: signal-ownership only, deliberately **not** grown into pgid/sid.
  `PPID_SELFTEST` → `ppid: child-gate PASS`.
- **A background (`&`) proc fault HALTED THE BOX.** A CPL3 fault routes to `fault_kill_current`,
  which `kernel_resume()`s to the shell for the **foreground** exec child — but a background proc's
  `#PF`/`#GP`/`#UD` fell through to the IDT stub's canary-bar **halt**. One bg service's ring-3
  fault killed the whole machine. Fixed: the bg path (already torn down — `proc_set_state(pid,0)` +
  SIGCHLD, identical to a clean exit) now `sti; hlt`-yields until the next timer tick's
  `do_context_switch` declines to revive the dead slot and switches to the next ready proc, reusing
  the proven timer-preemption path. Foreground unchanged (`fault-kill-smoke: PASS`, `run: exit 142`
  + `SURVIVED`).

Un-blocked the deferred `waitpid#4` ownership gate, landed at **1.50.8** (`proc_may_reap`): init
reaps anyone, a non-init caller reaps only its own direct child, checked **before** the alive/dead
test so a non-child gets −1 regardless of state. Previously any proc could reap any dead proc,
stealing its exit code and collapsing the slot under the real parent's pending `waitpid`.

---

## 6 · Network-ingress hardening — see the network prior-art

The 1.35.7 forged-IP-length over-read (`ip_safe_payload_len` at the `net_poll` demux, closing the
ICMP echo-reflect info-leak plus the UDP and TCP over-reads at the root) and the two unmasked
`(seq + 1)` RCV.NXT stores (TCP sequence wrap, `net_handle_tcp` ~line 1911 SYN_SENT→ESTABLISHED and
~1994 FIN_WAIT) are recorded in full in agnosticos
[`prior-art/arc-close-hardening-1-35.md`](https://github.com/MacCracken/agnosticos/blob/main/docs/development/prior-art/arc-close-hardening-1-35.md).
Not restated here. Gate: `HARDENING_SELFTEST` → `hardening: ip-clamp PASS`.

---

## 7 · Reviewed clean — do not re-audit

Checked and judged **already adequately guarded**; re-auditing these is wasted work.

- `dns_skip_name` — per-byte `p >= len` plus a 128-iteration compression-loop cap.
- `dns_parse_answer` — `p+10` and `p+rdlen` bounds.
- `tcp_parse_mss` — `p+1 < hdr_len`, `olen < 2`, `p+4 <= hdr_len`.
- `net_handle_tcp` — `tcp_hdr_len` min/max.
- `ntp_parse_unix` — caller gates `n >= 48`.
- `tcp_rx_append` — flow-control clamp (`take > free`), power-of-two ring mask `rxw & (RING-1)`,
  both copy halves bounded to the ring; length is `ip_payload_len`-derived, hence clamped.
- `munmap` partial range — already per-region present/absent, therefore idempotent.
- DNS cache — eviction is two bounded linear scans (empty/expired, else min-exp), no loop; name
  region `slot*64 + j` with `j < host_len <= 63 < 64`; `len > 63` rejected.
- UDP length field — derived from the clamped `ip_payload_len`, capped at 1016 into
  `kmalloc(1024)` / `var[256]`; a UDP-header cross-check would be pure defense-in-depth.
- **Deliberate dead code, do not "fix":** `sys_mmap` pre-counts free 2 MB regions
  (`pmm_count_2mb_free() < npages → 0`) before the alloc loop, so a mid-loop `pmm_alloc_2mb == 0` is
  unreachable in the single-core model and the partial-rollback path is dead **today**. Left as-is,
  flagged for the SMP arc, which must make count→alloc atomic. A speculative rollback now would be
  untestable dead code.

---

## 8 · S1–S13 — the kernel memory/process model (closed at v1.28.0)

A distinct, earlier front from §2–§5: S1–S13 hardened the kernel's **own** model; the 1.41.x work
hardens the **ring-3 → ring-0 ingress**. 13 of 13 Done.

| # | Item | What shipped |
|---|------|--------------|
| S1 | User/kernel page separation | Kernel PD entries in per-process tables carry `0x83` (present+write, **no** U/S), user pages `0x87`. Ring 0 still traverses them — supervisor mode ignores U/S. |
| S2 | Per-CPU TSS + RSP0 | 4 TSS descriptors (16 B each, two GDT slots) at 0x28/0x38/0x48/0x58; RSP0 = 0x200000 (BSP) and `0x300000 + id*0x10000` for APs; `ltr` per CPU. Re-init needs the descriptor type reset to 0x9 first. |
| S3 | PMM spinlock | `xchg`-based lock around `pmm_alloc`/`pmm_free`. Constraint: no allocation from ISR context or it deadlocks. |
| S4 | Per-process exit codes | proc_table entry 168 → **176 bytes**, `exit_code` at offset 168; every `pid * 168` had to become `pid * 176`. |
| S5 | Per-connection TCP RX buffers | `kmalloc(256)` per conn at `cb + 48`, freed in `tcp_close`. |
| S6 | Stack guard pages | Stack spacing raised 0x200000 → **0x400000** (2 MB stack + 2 MB guard) — at 0x200000 spacing pid 1's guard collided with pid 0's stack. `proc_unmap_page` zeroes the guard PDE. |
| S7 | KASLR | **Data-only (Option B)**: `rdrand_u64` gated on CPUID leaf 1 ECX bit 30, `kaslr_seed` randomizes `pmm_next_free`, sign-mask hygiene in the bitmap walker, kernel data phys-move. Full PIE (Option A) needs cyrius PIE codegen — every `&fn`/`&global` is an absolute address today. |
| S8 | KPTI | Partial — PD entry 0 kept in user tables for trampoline/ISR; full isolation needs 4 KB pages. |
| S9 | Spectre v2 | IBRS (`IA32_SPEC_CTRL`, **MSR 0x48 bit 0**) set on SYSCALL entry, cleared on exit; support via CPUID leaf 7 subleaf 0 EDX bit 26. Retpoline deferred to the compiler. |
| S10 | IOMMU (VT-d) | ACPI RSDP/RSDT/DMAR parsing + root/context/IO page tables; **DMA restricted to the first 16 MB**. |
| S11 | ARP request tracking | `arp_pending_ip` set **before** send; pending table with timeout. Gratuitous ARP silently dropped — correct. |
| S12 | TCP seq/ACK validation | Window check on inbound segments; 32-bit modular compare via `& 0xFFFFFFFF`. |
| S13 | Stack canaries | RDRAND-seeded `_canary`, fallback constant `0xDEAD1337CAFE4242`; manual canaries in `ksyscall`, `elf_load`, `net_handle_tcp`, `net_handle_arp`. Ideally `gs:0x28`, not a global — needs segment setup. |

Dependency order: S1 → {S6, S8 → S9}; S2 → S3; S4/S5/S11/S12/S13 independent.
The v1.27.1 memory-isolation closeout (SMAP root cause + `stac`/`clac` brackets) is downstream of
S1+S8.

---

## 9 · Open

- **#16 — `proc_reap` reclaims the proc-table slot only when it is the top slot.** A non-top reap
  leaks toward the 16-proc cap. Non-triggering under single-foreground run-to-completion; it
  triggers the moment concurrent background procs exit out of order.
- **A rare OOM mid-ELF-mapping leak** — not covered by the 1.41.6 validation pre-pass.
- **⛔ One proc can `mmap` all machine RAM.** There is no per-process page budget. This is the
  fairest-called genuine confinement gap; the sovereign shape is a PMM-debited page budget plus a
  capability-carried scheduling grant, not a cgroup tree.
- **Refactors #21/#22/#23** — the residue belongs in a pure-refactor cut, never bundled with a
  security diff.
- **KASLR Option A** (full PIE binary randomization) — blocked on cyrius PIE codegen.
- **KPTI full isolation** — blocked on 4 KB user pages; user memory is 2 MB huge pages only.
- **SMP** invalidates invariant (1). Every finding in this document judged "not a race" must be
  re-judged when APs are scheduled.

### Falsified fixes — do not re-propose

- **1.41.11's *primary* proposed fix** (reject the write-open when `vfs_create_on` fails) was
  **UNSOUND**: `fatfs_create` returns −1 on a name collision, i.e. the normal overwrite case, so it
  would have broken overwriting any existing file. Only the sound secondary fix was taken.
- **#23's single-tail canary collapse** — rejected: a risky rewrite of ~25 early-returns in the
  security-critical dispatcher for a non-vuln cosmetic.
- **The de-smoke hook placed ~450 lines too early in boot**, where `ext2_active` is still 0, so it
  returned silently — its strings were in the binary and the code never ran. *String present is not
  code called.* Its first harness was also cloned from an ESP-only QEMU image with no ext2 for
  `/bin/divz` to live on.
