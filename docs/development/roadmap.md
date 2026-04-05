# AGNOS Kernel Roadmap

> **Current**: v0.9.0 — x86_64 kernel complete, hardened

For language roadmap, see `../cyrius/docs/development/roadmap.md`.

## Active

| # | Item | Notes |
|---|------|-------|
| 1 | Scheduler | Round-robin with priority, context switching |
| 2 | Kernel heap | Slab allocator for variable-size allocations |
| 3 | VFS layer | Virtual filesystem abstraction |
| 4 | Init integration | Boot kybernet as PID 1 |

## Planned

| # | Item | Prerequisite |
|---|------|-------------|
| 5 | aarch64 port | Cyrius Phase 9 complete |
| 6 | SMP support | Cyrius Phase 14 (concurrency) |
| 7 | Network stack | VFS + scheduler complete |
| 8 | Userland exec | ELF loader, process memory isolation |
| 9 | Device driver framework | VFS + DMA support |
