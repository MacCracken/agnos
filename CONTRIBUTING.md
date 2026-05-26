# Contributing to AGNOS

## Development Process

1. Install the Cyrius toolchain: `curl -sSf https://raw.githubusercontent.com/MacCracken/cyrius/main/scripts/install.sh | sh`
2. Install git hooks: `sh scripts/install-hooks.sh` — sets up the pre-push format gate (local CI parity; blocks a push with `cyrius fmt` drift instead of failing in CI). Run once per fresh checkout.
3. Build the kernel: `sh scripts/build.sh`
4. Make changes to `kernel/agnos.cyr`
5. Test: `sh scripts/test.sh`
6. Boot verify: `qemu-system-x86_64 -kernel build/agnos -serial stdio -display none`

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
- Formatting is enforced by `cyrius fmt` (CI gate + pre-push hook). Fix drift in place with `sh scripts/fmt-fix.sh`; check with `sh scripts/fmt-check.sh`.

## License

All contributions are licensed under GPL-3.0-only.
