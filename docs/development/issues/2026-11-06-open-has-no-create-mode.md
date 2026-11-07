# 2026-11-06 — open has no create mode, so a private file lands 0644

**Status:** 🟡 OPEN.
*(Filed from thoth **0.55.1**, where it has been a standing row on the roadmap's waiting table.)*
**Checked against:** agnos **107ad763** (1.57.17), `ext2_create`; cyrius **6.7.18**, `sys_open(name, namelen, ao_flags)`.
**Severity:** low today, with one user. It becomes real the day `getuid` stops being a stub.

## What happens

`sys_open` carries no mode, and a created file gets the kernel's default. thoth writes its tool pins, session store and session log at 0600 on Linux and macOS, and hoosh and daimon keep credentials and stores the same way. On agnos all of them land at the default, and a consumer cannot ask otherwise.

## The ask

A create mode on `open`, honoured by `ext2_create`, in a way an old caller keeps today's default.

**Related:** `fsync` syncs the whole filesystem, so an atomic store write costs more than it should. A per-file sync would help every store that writes through a temp and a rename.

## What thoth does meanwhile

Nothing it can do. It never claims a mode it cannot enforce, and its config example says so.
