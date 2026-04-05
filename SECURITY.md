# Security Policy

## Reporting Vulnerabilities

Report security issues to: security@agnosticos.org

Do **not** open public issues for security vulnerabilities.

## Scope

AGNOS is an operating system kernel. Security-relevant areas:

- **Memory safety**: PMM/VMM bounds checking, buffer overflows
- **Interrupt handling**: ISR register save/restore, EOI timing
- **Syscall validation**: pointer and length validation, PID bounds
- **Process isolation**: page table correctness, privilege enforcement
- **Boot integrity**: multiboot header validation, page table setup

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.9.x | Yes |
| < 0.9 | No |
