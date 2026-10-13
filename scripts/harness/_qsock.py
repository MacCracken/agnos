"""_qsock.py — where a harness binds QEMU's UNIX sockets (1.57.13): the Python twin of qemu-dwell.sh's smoke_qsock.

sun_path holds 108 bytes (unix(7)), and a sweep worker copy's build dir alone is ~75 — a socket under the harness's
own WORK dir was refused by QEMU ("UNIX socket path ... is too long") and the boot never started (hid-mouse-deferred
and pipeline VOIDed under SWEEP_JOBS=4 at 1.57.11 and 1.57.12). The fixed /tmp/agnos-*.sock names the older harnesses
use are short but SHARED: two trees running the same harness at once bind one path, and a driver can talk to the
other tree's QEMU. One rule for both (keep it identical to smoke_qsock):

    ${XDG_RUNTIME_DIR:-/tmp}/agnos-q.<first 12 hex of md5(<path>)>/<basename of <path>>

deterministic per (tree, harness, socket). The hash-named directory is used only when lstat says it is a real
directory (never a symlink), owned by this uid, with no group / other bits (mode & 0o077 == 0); anything else at that
name gets mkdtemp in the same base instead (1.57.13 review: a symlink there redirected a run's sockets into any directory
the user owns). Directories of this rule (real directories, mine) untouched for a day are pruned RECURSIVELY, as the
shell's `rm -rf` does. Prior art: OpenSSH ControlPath %C, systemd's $XDG_RUNTIME_DIR sockets, libvirt's
/run/libvirt/qemu monitors.
"""
import hashlib, os, shutil, stat, tempfile, time


def _dir_ok(d):
    try:
        st = os.lstat(d)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and (st.st_mode & 0o077) == 0


def qsock(path):
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    if not (os.path.isdir(base) and os.access(base, os.W_OK)):
        base = "/tmp"
    now = time.time()
    try:
        for name in os.listdir(base):
            if not name.startswith("agnos-q."):
                continue
            p = os.path.join(base, name)
            try:
                st = os.lstat(p)
                if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and now - st.st_mtime > 86400:
                    shutil.rmtree(p, ignore_errors=True)
            except OSError:
                pass
    except OSError:
        pass
    d = os.path.join(base, "agnos-q." + hashlib.md5(path.encode()).hexdigest()[:12])
    if not os.path.islink(d):
        try:
            os.mkdir(d, 0o700)
        except OSError:
            pass
    if not _dir_ok(d):
        d = tempfile.mkdtemp(prefix="agnos-q.", dir=base)
    try:
        os.utime(d)
    except OSError:
        pass
    return os.path.join(d, os.path.basename(path))
