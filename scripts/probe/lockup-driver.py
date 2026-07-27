#!/usr/bin/env python3
"""Drive the AGNOS interactive shell over QEMU QMP send-key, hunting the
1.33.x delayed/interactive lockup. See lockup-repro.sh for context.

Boots QEMU (gnoboot+OVMF) with qemu-xhci + usb-kbd, waits for the shell
banner on the serial log, then types commands one keystroke at a time via
QMP `send-key`. Each `uptime` prints the live timer_ticks; as long as that
RISES the timer ISR + hlt-wake loop is alive. A freeze = serial log stops
growing while keys keep being sent. Reports whether it reproduced the hang.
"""
import argparse, json, os, re, socket, subprocess, sys, time

# Minimal qcode map for the characters our command set needs.
QCODE = {c: c for c in "abcdefghijklmnopqrstuvwxyz0123456789"}
QCODE[" "] = "spc"
QCODE["/"] = "slash"
QCODE["."] = "dot"
QCODE["-"] = "minus"
QCODE["\n"] = "ret"


class Qmp:
    def __init__(self, path):
        self.path = path
        self.sock = None
        self.f = None

    def connect(self, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.path)
                self.sock = s
                self.f = s.makefile("rwb", buffering=0)
                self._read_obj()                 # greeting
                self._cmd("qmp_capabilities")
                return True
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.2)
        return False

    def _read_obj(self):
        line = self.f.readline()
        if not line:
            raise EOFError("QMP closed")
        return json.loads(line.decode())

    def _cmd(self, execute, arguments=None):
        obj = {"execute": execute}
        if arguments:
            obj["arguments"] = arguments
        self.f.write((json.dumps(obj) + "\n").encode())
        # Drain until we see a return/error (skip async events).
        while True:
            r = self._read_obj()
            if "return" in r or "error" in r:
                return r

    def send_char(self, ch, hold_ms=8):
        q = QCODE.get(ch)
        if q is None:
            return
        self._cmd("send-key", {
            "keys": [{"type": "qcode", "data": q}],
            "hold-time": hold_ms,
        })

    def type_line(self, text, key_delay=0.012):
        for ch in text:
            self.send_char(ch)
            time.sleep(key_delay)
        self.send_char("\n")


def serial_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def last_ticks(path):
    """Return the max integer N appearing as 'N ticks' in the serial log."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    vals = re.findall(rb"(\d+)\s+ticks", data)
    return max(int(v) for v in vals) if vals else None


def wait_for(path, needle, timeout):
    deadline = time.time() + timeout
    nb = needle.encode()
    while time.time() < deadline:
        try:
            with open(path, "rb") as fh:
                if nb in fh.read():
                    return True
        except OSError:
            pass
        time.sleep(0.3)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--ovmf-code", required=True)
    ap.add_argument("--ovmf-vars", required=True)
    ap.add_argument("--serial", required=True)
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--duration", type=int, default=120)
    ap.add_argument("--stall-window", type=float, default=10.0,
                    help="seconds of zero serial growth (while typing) = lockup")
    args = ap.parse_args()

    for p in (args.serial, args.qmp):
        try:
            os.remove(p)
        except OSError:
            pass

    qemu = [
        "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
        "-drive", f"if=pflash,format=raw,readonly=on,file={args.ovmf_code}",
        "-drive", f"if=pflash,format=raw,file={args.ovmf_vars}",
        "-drive", f"file={args.image},format=raw,if=none,id=disk0",
        "-device", "nvme,drive=disk0,serial=AGNOS-LOCK",
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd,bus=xhci.0",
        "-serial", f"file:{args.serial}",
        "-qmp", f"unix:{args.qmp},server,nowait",
        "-display", "none", "-no-reboot",
    ]
    print("QEMU:", " ".join(qemu), flush=True)
    proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)

    qmp = Qmp(args.qmp)
    if not qmp.connect(timeout=30):
        print("FAIL: could not connect QMP", flush=True)
        proc.terminate()
        sys.exit(2)
    print("QMP connected.", flush=True)

    print("Waiting for shell banner (up to 90s)...", flush=True)
    if not wait_for(args.serial, "AGNOS shell v", 90):
        print("FAIL: shell banner never appeared. Serial tail:", flush=True)
        _dump_tail(args.serial)
        err = proc.stderr.read().decode(errors="replace")[-2000:]
        if err.strip():
            print("--- qemu stderr ---\n" + err, flush=True)
        proc.terminate()
        sys.exit(3)
    print("Shell is up. Driving keystrokes...", flush=True)

    # Command mix mirroring the iron session (1333 photo): mostly `uptime`
    # (the live-tick canary), with periodic FS-write verbs so allocator /
    # dirent / inode paths get exercised too — more chances to trip any
    # corruption that surfaces later at idle.
    mix = ["uptime"] * 8 + ["echo hello", "ls", "sync", "uptime",
                            "echo agnos lives", "uptime"]

    start = time.time()
    n_cmds = 0
    max_ticks = 0
    last_growth_size = serial_size(args.serial)
    last_growth_time = time.time()
    locked = False

    while time.time() - start < args.duration:
        cmd = mix[n_cmds % len(mix)]
        qmp.type_line(cmd)
        n_cmds += 1
        time.sleep(0.25)            # let the command run + echo to serial

        sz = serial_size(args.serial)
        if sz > last_growth_size:
            last_growth_size = sz
            last_growth_time = time.time()
        t = last_ticks(args.serial)
        if t is not None and t > max_ticks:
            max_ticks = t

        stalled_for = time.time() - last_growth_time
        if stalled_for >= args.stall_window:
            locked = True
            break

        if n_cmds % 40 == 0:
            print(f"  [{int(time.time()-start)}s] cmds={n_cmds} "
                  f"max_ticks={max_ticks} serial={sz}B "
                  f"stall={stalled_for:.1f}s", flush=True)

    elapsed = int(time.time() - start)
    print("", flush=True)
    if locked:
        print(f"*** LOCKUP REPRODUCED after {n_cmds} commands / {elapsed}s ***",
              flush=True)
        print(f"    last rising tick value seen: {max_ticks}", flush=True)
        print(f"    serial frozen at {last_growth_size}B; no growth for "
              f">= {args.stall_window}s while still sending keys.", flush=True)
        # Probe: is the QEMU vCPU still running or did the guest halt hard?
        try:
            st = qmp._cmd("query-status")
            print("    query-status:", st.get("return"), flush=True)
        except Exception as e:
            print("    query-status failed:", e, flush=True)
        _dump_tail(args.serial)
    else:
        print(f"NO LOCKUP: {n_cmds} commands over {elapsed}s, "
              f"timer ticks rose to {max_ticks}, serial kept growing "
              f"({last_growth_size}B). The hang did NOT reproduce in QEMU.",
              flush=True)

    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    sys.exit(1 if locked else 0)


def _dump_tail(path, n=1400):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
        print("--- serial tail ---", flush=True)
        sys.stdout.write(data[-n:].decode(errors="replace"))
        print("\n--- end serial ---", flush=True)
    except OSError as e:
        print("(no serial log:", e, ")", flush=True)


if __name__ == "__main__":
    main()
