# Contributing to AGNOS

## Development Process

1. Install the Cyrius toolchain: `curl -sSf https://raw.githubusercontent.com/MacCracken/cyrius/main/scripts/install.sh | sh`
2. Build the kernel: `sh scripts/build.sh`
3. Make changes to `kernel/agnos.cyr`
4. Test: `sh scripts/test.sh`
5. Boot verify: `qemu-system-x86_64 -kernel build/agnos -serial stdio -display none`

## Rules

- Every change must produce a valid multiboot ELF that boots on QEMU
- Bounds check all array/table access (PMM bitmap, process table, ring buffers)
- ISRs must save and restore ALL caller-saved registers (9 regs)
- Syscalls must validate all arguments (pointers, lengths, PIDs)
- Test after every change, not after the feature is "done"

## Code Style

- Functions: `snake_case`
- Constants/tables: `UPPER_CASE` or descriptive names
- Comments: explain the hardware contract, not the obvious

## License

All contributions are licensed under GPL-3.0-only.
