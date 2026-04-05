# AGNOS Kernel Architecture

## Boot Sequence

```
BIOS/UEFI → GRUB/QEMU multiboot1 loader
  → 32-bit entry (ELF32, base 0x100000)
    → Identity page tables (4 levels, 2MB huge pages)
    → Enable PAE → set CR3 → enable LME in EFER → enable paging
    → Load 64-bit GDT → far jump to 64-bit code
      → Cyrius kernel main()
```

## Memory Map

```
0x000000 - 0x001000  Real-mode IVT (unused)
0x001000 - 0x005000  Page tables (PML4, PDPT, PD, PT)
0x100000 - 0x110000  Kernel code + data (~62KB)
0x200000 - 0x1000000 Available physical memory (2MB - 16MB)
```

## Subsystem Diagram

```
┌─────────────────────────────────────────┐
│              Syscall Interface           │
│         exit(0)  write(1)  getpid(2)    │
├─────────────────────────────────────────┤
│  Process Table  │  VMM (2MB pages)      │
│  16 slots       │  map/unmap/alloc      │
├─────────────────┼───────────────────────┤
│  PMM (bitmap)   │  Page Tables          │
│  4096 pages     │  16MB identity map    │
├─────────────────┴───────────────────────┤
│  Timer (PIT 100Hz)  │  Keyboard (IRQ1)  │
│  PIC (8259A)        │  IDT (256 vec)    │
│  GDT (64-bit flat)  │  Serial (COM1)    │
├─────────────────────────────────────────┤
│              Boot Shim (32→64)          │
│           Multiboot1 (ELF32)            │
└─────────────────────────────────────────┘
```

## ISR Model

Interrupt service routines are built as bytecode in data buffers at runtime. This works because the ELF `PT_LOAD` segment has RWX permissions.

Timer ISR saves 9 caller-saved registers (rax, rcx, rdx, rsi, rdi, r8-r11), increments tick counter, sends EOI, restores registers, iretq.

Keyboard ISR reads port 0x60 (scancode), stores in ring buffer, advances head pointer with wrapping, sends EOI.
