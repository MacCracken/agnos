# Security Hardening Implementation Guide

> From the 2026-04-13 audit. See `docs/audit/2026-04-13-security-audit.md` for findings.
> See `docs/development/roadmap.md` for the tracking table (S1-S13).

---

## Implementation Phases

```
Phase 1 (independent, do in any order)
  S3  PMM spinlock
  S4  Per-process exit codes
  S5  Per-connection TCP RX buffers
  S11 ARP request tracking
  S12 TCP seq/ack validation

Phase 2 (memory isolation, sequential)
  S1  Separate user/kernel page mappings
  S2  Per-CPU TSS + RSP0
  S6  Stack guard pages

Phase 3 (advanced mitigations, depend on Phase 2)
  S13 Stack canaries
  S8  KPTI
  S9  Spectre v2

Phase 4 (deferred — requires compiler/infrastructure work)
  S7  KASLR
  S10 IOMMU (VT-d)
```

---

## S1: Separate User/Kernel Page Mappings

**Goal**: Ring-3 code must not be able to read kernel memory.

**Current problem**: `ring3.cyr:spawn_user_proc()` sets U/S bit on PD entries 0-1 (first 4MB), exposing kernel code/data to userspace.

### Files to change

**`kernel/core/proc.cyr`** — `proc_create_address_space()`:
- When copying kernel PD entries into per-process page tables, do NOT set U/S bit. Kernel identity map entries stay supervisor-only (0x83).
- Currently PML4[0] and PDPT[0] are created with flags 0x07 (user) at lines 111-112. Change to 0x03 (present+writable, no user). Ring-0 code can still traverse them; ring-3 cannot.
- Add `proc_map_page_flags(cr3, virt, phys, flags)` — parameterized version of `proc_map_page`.

**`kernel/arch/x86_64/ring3.cyr`** — `spawn_user_proc()`:
- Remove lines 78-81 (the U/S bit OR on PD entries 0-1).
- Allocate a fresh physical page via `pmm_alloc()` for user code.
- Copy the kernel function at `entry_fn` into the new page.
- Map it at a user-visible VA (e.g. `0x400000`) with user+exec flags (0x87).
- Set the process entry point to `0x400000` instead of the kernel address.

**`kernel/core/elf.cyr`** — `elf_load()`:
- Already maps user code at high VAs. Verify kernel PD entries in per-process tables don't have U/S set (they won't after the proc.cyr fix).

### How it works

```
Before:
  PD[0] = kernel 0-2MB   flags: 0x87 (user+write+present+2MB)
  PD[1] = kernel 2-4MB   flags: 0x87

After:
  PD[0] = kernel 0-2MB   flags: 0x83 (write+present+2MB, NO user)
  PD[1] = kernel 2-4MB   flags: 0x83
  PD[2] = user code 4-6MB flags: 0x87 (user+write+present+2MB)
```

Ring-0 code (SYSCALL handler, ISRs) can still access kernel mappings because they run in supervisor mode. Ring-3 code page-faults when trying to read 0x100000.

### Gotchas
- The kernel switches CR3 to user tables during ELF loading (elf.cyr:59). Kernel code must still be accessible during this window — it is, because supervisor mode ignores U/S bit.
- SYSCALL doesn't switch CR3. After SYSCALL, the CPU is ring-0 with user page tables. Kernel mappings are present (just not user-accessible), so ring-0 code works fine.

### Test
Boot in QEMU. User process does `load64(0x100000)`. Should page-fault. Verify via serial.

---

## S2: Per-CPU TSS + RSP0

**Goal**: Each CPU core has its own kernel stack for interrupt/syscall handling.

**Current problem**: Global `tss_kernel_stack = 0x200000`. SMP code sets per-CPU stacks at `0x300000 + id*0x10000` but never wires them into per-CPU TSS entries.

### Files to change

**`kernel/arch/x86_64/gdt.cyr`**:
- Expand GDT to hold 4 TSS descriptors (one per CPU). Each TSS descriptor is 16 bytes (it spans two GDT slots for 64-bit mode). Current layout: 5 segments (0x00-0x28) + 1 TSS at 0x28. New layout: 0x28 = CPU0 TSS, 0x38 = CPU1 TSS, 0x48 = CPU2 TSS, 0x58 = CPU3 TSS.
- Allocate 4 TSS structures: `var tss_array[416]` (4 x 104 bytes each).
- `tss_init_cpu(cpu_id)` — zeroes TSS, sets RSP0, writes descriptor into GDT, executes `ltr`.
- `tss_set_rsp0(rsp0)` — reads APIC ID to determine current CPU, updates correct TSS.

```
CPU 0: RSP0 = 0x200000        (BSP kernel stack)
CPU 1: RSP0 = 0x310000        (0x300000 + 1*0x10000)
CPU 2: RSP0 = 0x320000
CPU 3: RSP0 = 0x330000
```

**`kernel/arch/x86_64/smp.cyr`** — `ap_entry()`:
- After setting per-CPU stack, call `tss_init_cpu(my_id)`.
- The AP trampoline already reloads GDT, so new TSS descriptors are visible.

**`kernel/arch/x86_64/ring3.cyr`** — `enter_ring3()`:
- Change `tss_set_rsp0(tss_kernel_stack)` to use current CPU's stack.

### Gotchas
- `ltr` can only be called once per TSS selector. Re-init requires marking the TSS descriptor type back to 0x9 (available) before calling `ltr` again.
- STAR MSR references selectors 0x08/0x10 for kernel and 0x10 for user base — these don't change since TSS entries come after.
- GDT limit must be updated to cover the new entries.

### Test
Boot with SMP. Print each CPU's RSP0 value via serial. Trigger ring-3 processes on multiple CPUs. Verify each uses its own kernel stack.

---

## S3: PMM Spinlock

**Goal**: Prevent two CPUs from allocating the same physical page.

### Files to change

**`kernel/core/pmm.cyr`**:
- Add `var pmm_lock = 0;`
- Add lock/unlock wrappers using the same `xchg` pattern as smp.cyr:

```cyrius
fn pmm_spin_lock() {
    var old = 1;
    while (old == 1) {
        var addr = &pmm_lock;
        asm {
            0x48; 0x8B; 0x45; 0xF0;  # mov rax, [rbp-0x10] (addr)
            0x48; 0xC7; 0xC1; 0x01; 0x00; 0x00; 0x00;  # mov rcx, 1
            0x48; 0x87; 0x08;          # xchg [rax], rcx
            0x48; 0x89; 0x4D; 0xF8;   # mov [rbp-0x08], rcx (old)
        }
    }
    return 0;
}

fn pmm_spin_unlock() {
    var addr = &pmm_lock;
    asm {
        0x48; 0x8B; 0x45; 0xF8;  # mov rax, [rbp-0x08] (addr)
        0x48; 0x31; 0xC9;         # xor rcx, rcx
        0x48; 0x87; 0x08;         # xchg [rax], rcx
    }
    return 0;
}
```

- Wrap `pmm_alloc()` and `pmm_free()`:

```cyrius
fn pmm_alloc() {
    pmm_spin_lock();
    # ... existing alloc logic ...
    pmm_spin_unlock();
    return result;
}
```

### Gotchas
- If `pmm_alloc` is called from interrupt context while holding the lock, deadlock. This kernel doesn't allocate from ISRs currently — document this constraint.
- Duplicating the xchg pattern in pmm.cyr (instead of parameterizing smp.cyr's lock) is simpler and avoids changing the asm stack offsets.

### Test
Launch 4 APs. Each allocates 100 pages in a loop. Verify `pmm_used` count matches total allocated. No two CPUs should get the same address.

---

## S4: Per-Process Exit Codes

**Goal**: `waitpid(pid)` returns the correct exit code for that specific process.

### Files to change

**`kernel/core/proc.cyr`**:
- Extend process table from 168 to 176 bytes per entry (add `exit_code` at offset 168).
- Update `proc_table` array: `var proc_table[2816]` (16 x 176).
- **Critical**: Find-and-replace ALL `* 168` with `* 176` across proc.cyr. Also check sched.cyr for any references.
- Add accessors:

```cyrius
fn proc_set_exit_code(pid, code) {
    store64(&proc_table + pid * 176 + 168, code);
    return 0;
}

fn proc_get_exit_code(pid) {
    return load64(&proc_table + pid * 176 + 168);
}
```

**`kernel/core/syscall.cyr`**:
- Syscall 0 (exit): `proc_set_exit_code(proc_current, arg1)` instead of `sys_exit_code = arg1`.
- Syscall 4 (waitpid): `return proc_get_exit_code(arg1)` instead of `return sys_exit_code`.

### Gotchas
- Every `pid * 168` in the codebase must become `pid * 176`. Miss one and you get silent memory corruption. Grep thoroughly.
- The `proc_signals` and `proc_sigmask` arrays are separate (not in proc_table), so they're unaffected.

### Test
Spawn process A (exits with code 42) and process B (exits with code 99). `waitpid(A)` returns 42, `waitpid(B)` returns 99.

---

## S5: Per-Connection TCP RX Buffers

**Goal**: Concurrent TCP connections don't corrupt each other's received data.

### Files to change

**`kernel/core/net.cyr`**:

In `tcp_connect()` — allocate per-connection buffer:
```cyrius
var rx_buf = kmalloc(256);
if (rx_buf == 0) { tcp_conn_count = tcp_conn_count - 1; return 0 - 1; }
store64(cb + 48, rx_buf);
```

In `net_handle_tcp()` ESTABLISHED handler — use per-connection buffer:
```cyrius
# Replace:
#   net_copy_buf(&tcp_rx_tmpbuf, tcp + tcp_hdr_len, data_len);
#   store64(cb + 48, &tcp_rx_tmpbuf);
# With:
var rx_buf = load64(cb + 48);
if (rx_buf != 0) {
    net_copy_buf(rx_buf, tcp + tcp_hdr_len, data_len);
}
```

In `tcp_close()` — free buffer:
```cyrius
var rx_buf = load64(cb + 48);
if (rx_buf != 0) { kfree_sized(rx_buf, 256); store64(cb + 48, 0); }
```

Remove or keep `tcp_rx_tmpbuf` as unused.

### Gotchas
- `kmalloc(256)` failure must fail the connection gracefully.
- `tcp_conn_count` never decreases (slots not recycled). Buffer still freed on close.

### Test
Open 3 TCP connections. Send distinct data to each. Read from each. Verify no cross-contamination.

---

## S6: Stack Guard Pages

**Goal**: Stack overflow traps instead of silently corrupting adjacent memory.

### Approach

Currently only 2MB pages. The simple approach: leave the 2MB page directly below each stack unmapped. This wastes 2MB per process but works without 4KB page support.

**Problem**: Stack spacing is currently `0x200000` (2MB) per process. Stack at `0x800000 + pid * 0x200000`. For pid=1, guard at `0x800000` = pid=0's stack. **Collision.**

**Fix**: Increase spacing to `0x400000` (4MB) — one 2MB slot for stack, one for guard.

### Files to change

**`kernel/core/proc.cyr`**:
- Add `proc_unmap_page(cr3, virt)` — traverses PML4->PDPT->PD and zeroes the PD entry for the given 2MB virtual address.

**`kernel/arch/x86_64/ring3.cyr`** — `spawn_user_proc()`:
```cyrius
# Change:  var stack_base = 0x800000 + pid * 0x200000;
# To:      var stack_base = 0x800000 + pid * 0x400000;
# Then:    proc_unmap_page(new_cr3, stack_base - 0x200000);
```

**`kernel/core/elf.cyr`** — `elf_load()`:
- Same spacing change: `0x800000 + pid * 0x400000`.
- Unmap guard page below stack.

### Test
User process recurses deeply. Triggers page fault on guard page. Verify serial output shows the fault address.

---

## S7: KASLR (Kernel Address Space Layout Randomization)

**Goal**: Kernel load address is randomized per boot.

### Why this is hard

Every `&function_name` and `&global_var` in Cyrius produces an absolute address baked into the binary. Without relocation tables or PIC (position-independent code) support in the Cyrius compiler, every address reference would need manual patching at boot.

### What's needed

1. **Entropy source** — RDRAND (check CPUID leaf 1, ECX bit 30):
```cyrius
fn rdrand64() {
    var val = 0;
    asm {
        0x48; 0x0F; 0xC7; 0xF0;  # rdrand rax
        0x48; 0x89; 0x45; 0xF8;  # mov [rbp-0x08], rax
    }
    return val;
}
```

2. **Relocatable binary** — requires Cyrius compiler to emit relocation entries or generate PIC. This is a **compiler-level feature request**.

3. **Boot shim changes** — page tables map randomized VA to physical 0x100000. Apply relocations.

### Recommendation

**Defer until Cyrius compiler supports relocations or PIC.** File a feature request in `../cyrius/`. In the meantime, the other mitigations (S1, S2, S8) significantly reduce the attack surface even without KASLR.

### Interim alternative

Randomize the user-visible portions (stack base, ELF load address) which are already per-process. This gives partial ASLR without compiler changes.

---

## S8: KPTI (Kernel Page Table Isolation)

**Goal**: Separate page tables for user mode and kernel mode. Mitigates Meltdown.

**Depends on**: S1 (user/kernel page separation) + S2 (per-CPU TSS with IST)

### Design

Two CR3 values per process:
- **Kernel CR3**: Full mappings (kernel + user). Used in ring 0.
- **User CR3**: Only user mappings + one trampoline page containing the SYSCALL entry stub. Used in ring 3.

### Files to change

**`kernel/core/proc.cyr`**:
- `proc_create_address_space()` creates TWO page table hierarchies per process.
- Store both in process table. Add `user_cr3` field at next available offset.

**`kernel/arch/x86_64/syscall_hw.cyr`** — SYSCALL entry:
- First instruction after SYSCALL must switch CR3 from user to kernel.
- The trampoline page is mapped in both user and kernel page tables at a fixed address (e.g. `0x5000`).
- Trampoline stores kernel CR3 at a known location in the trampoline page.
- Entry sequence:
```
; Trampoline code (mapped in user page tables, supervisor-only)
mov rax, [TRAMPOLINE_PAGE + kernel_cr3_offset]
mov cr3, rax
; Now running with full kernel mappings
jmp actual_syscall_handler
```

**`kernel/arch/x86_64/syscall_hw.cyr`** — SYSRET exit:
- Before `sysretq`, switch CR3 back to user CR3.

**`kernel/arch/x86_64/idt.cyr`**:
- Interrupt entry must also switch CR3. Use IST (Interrupt Stack Table) in TSS to guarantee a valid kernel stack before the CR3 switch.

### Gotchas
- The trampoline page must be supervisor-only in user page tables (present, no U/S bit). Ring-0 code after SYSCALL can access it. Ring-3 code cannot read the kernel CR3 value stored there.
- CR3 switch flushes TLB. Performance cost on every syscall/interrupt. This is the known KPTI overhead (~5-30% on syscall-heavy workloads).
- Triple-fault risk is high during development. Add extensive serial debugging.

### Test
Verify syscalls still work. Verify timer interrupts still fire. User process attempts kernel memory read — should fault.

---

## S9: Spectre v2 Mitigations

**Goal**: Prevent indirect branch prediction attacks.

**Depends on**: S8 (KPTI in place)

### Files to change

**`kernel/arch/x86_64/syscall_hw.cyr`** — SYSCALL entry:
```
; Set IA32_SPEC_CTRL.IBRS (MSR 0x48, bit 0)
mov ecx, 0x48
rdmsr
or eax, 1
wrmsr
```

Asm bytes:
```
0xB9; 0x48; 0x00; 0x00; 0x00;  # mov ecx, 0x48
0x0F; 0x32;                      # rdmsr
0x0C; 0x01;                      # or al, 1
0x0F; 0x30;                      # wrmsr
```

Before SYSRET, optionally clear IBRS to avoid user-mode performance hit.

### Gotchas
- Check CPUID for IBRS support first (leaf 7, subleaf 0, EDX bit 26).
- RDMSR/WRMSR are serializing — adds latency to every syscall.
- Not all QEMU CPU models expose IBRS. Use `-cpu host` or a model that supports it.
- **Retpoline** (for indirect calls) requires compiler support. File as Cyrius feature request.

### Test
Check `rdmsr 0x48` returns bit 0 set after syscall entry. Benchmark syscall latency before/after.

---

## S10: IOMMU (VT-d)

**Goal**: Restrict DMA so VirtIO devices can only access their allocated buffers.

### Why this is hard

Requires:
1. ACPI RSDP scanning (0xE0000-0xFFFFF for "RSD PTR " signature)
2. RSDT/XSDT parsing
3. DMAR table parsing (DMA Remapping Reporting Structure)
4. IOMMU MMIO register programming
5. DMA remapping page tables (context tables + second-level paging)

This is a multi-week effort and QEMU requires `-device intel-iommu` flag.

### Recommendation

**Defer.** The VirtIO devices run in a trusted QEMU environment. When moving to real hardware or untrusted device passthrough, implement this.

### Interim mitigation

The VirtIO-blk driver already uses a static DMA buffer (`vblk_dma_buf`) and copies to/from caller buffers. This limits the DMA surface area to known static addresses.

---

## S11: ARP Request Tracking

**Goal**: Only accept ARP replies matching our pending requests.

### Files to change

**`kernel/core/net.cyr`**:

```cyrius
var arp_pending_ip = 0;

fn arp_request(target_ip) {
    # ... existing code ...
    arp_pending_ip = target_ip;  # Set BEFORE sending
    return virtio_net_send(p, off + 28);
}

fn net_handle_arp(pkt, len) {
    if (len < 42) { return 0; }
    var oper = load8(pkt + 20) * 256 + load8(pkt + 21);
    if (oper == 2) {
        var sender_ip = (load8(pkt + 28) << 24) | (load8(pkt + 29) << 16) |
                        (load8(pkt + 30) << 8) | load8(pkt + 31);
        # Security: only accept replies matching our pending request
        if (sender_ip != arp_pending_ip) { return 0; }
        arp_cache_ip = sender_ip;
        net_copy_buf(&arp_cache_mac, pkt + 22, 6);
        arp_pending_ip = 0;  # Request fulfilled
    }
    return 0;
}
```

### Gotchas
- Set `arp_pending_ip` BEFORE sending the request packet (race with fast reply).
- Gratuitous ARP will be silently dropped. This is correct for security.

---

## S12: TCP Sequence/ACK Validation

**Goal**: Drop TCP packets with sequence numbers outside the expected window.

### Files to change

**`kernel/core/net.cyr`** — `net_handle_tcp()` ESTABLISHED handler:

```cyrius
if (state == 2) {
    # ... RST check ...
    if (data_len > 0) {
        # Security: validate sequence number within receive window
        var expected_seq = load64(cb + 40);
        var window = 8192;
        # Use 32-bit modular arithmetic for seq number wraparound
        var seq_diff = (seq - expected_seq) & 0xFFFFFFFF;
        if (seq_diff >= window) { return 0; }  # Outside window, drop
        # ... rest of data handling ...
    }
}
```

For SYN_SENT state, validate the ACK in SYN-ACK:
```cyrius
if (state == 1) {
    if ((flags & 0x12) == 0x12) {
        # Validate ACK matches our SYN seq + 1
        var our_seq = load64(cb + 32);
        if (ack != our_seq) { return 0; }  # Bad ACK
        # ... rest of SYN-ACK handling ...
    }
}
```

### Gotchas
- TCP seq numbers are 32-bit and wrap at 2^32. Use `& 0xFFFFFFFF` mask for comparisons.
- Out-of-order packets will be dropped (no reassembly). Acceptable for minimal stack.
- Initial seq is hardcoded as 1000. Randomize for better security: `var init_seq = timer_ticks & 0xFFFFFFFF;`

---

## S13: Stack Canaries

**Goal**: Detect stack buffer overflows in critical kernel functions.

### Approach

Without compiler support, manually insert canary checks in security-critical functions.

### Files to change

**`kernel/core/main.cyr`** — early boot:
```cyrius
var stack_canary_secret = 0;

fn init_stack_canary() {
    var val = 0;
    asm {
        0x48; 0x0F; 0xC7; 0xF0;  # rdrand rax
        0x48; 0x89; 0x45; 0xF8;  # mov [rbp-0x08], rax
    }
    if (val == 0) { val = 0xDEAD1337CAFE4242; }
    stack_canary_secret = val;
    return 0;
}
```

**Pattern for protected functions** (e.g. `ksyscall`):
```cyrius
fn ksyscall(num, arg1, arg2, arg3) {
    var canary = stack_canary_secret;
    # ... function body ...
    if (canary != stack_canary_secret) {
        serial_println("PANIC: stack smash", 18);
        arch_halt();
    }
    return result;
}
```

### Which functions to protect
- `ksyscall()` — processes all user input
- `net_handle_tcp()` — processes network packets
- `net_handle_arp()` — processes network packets
- `elf_load()` — processes untrusted ELF binaries

### Gotchas
- Manual canaries are tedious. Long-term solution is Cyrius compiler support (`-fstack-protector` equivalent).
- If canary secret leaks (info leak vuln), attacker can bypass. Ideally stored in a per-CPU segment register (`gs:0x28`) not a global, but that requires segment setup.
- RDRAND may not be available. Check CPUID first. Fallback to constant + timer XOR.

---

## Quick Reference: What Blocks What

```
S1 ─┬─> S6  (guard pages need the new page mapping model)
    └─> S8  (KPTI needs clean user/kernel separation)
            └─> S9  (Spectre mitigations complement KPTI)

S2 ─> S3  (per-CPU TSS needed before PMM lock is safe in ISR context)

S4, S5, S11, S12, S13 are independent — start anytime

S7  requires Cyrius compiler changes (defer)
S10 requires ACPI parsing infrastructure (defer)
```
