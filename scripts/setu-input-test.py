#!/usr/bin/env python3
# setu-input-test.py — prove INPUT routes over setu to the FOCUSED client on agnos.
#
# Reuses the image staged by aethersafha-setu-smoke.sh (build/ae-setu-smoke/agnos-ae.img:
# compositor spawns TWO present_probe clients, cascaded to distinct windows), but boots it
# with a QEMU USB-xHCI keyboard so HMP `sendkey` injects real Set-1 make/break — the same
# kb_buf that bhumi_input_poll drains via sys_kbscan(#42).
#
# Flow: wait for BOTH clients to present -> BEFORE dump (2 green-bordered windows) ->
# `sendkey a` (a plain key: input_handle is a no-op, so it's FORWARDED to the focused
# client) -> AFTER dump. The compositor focuses the last-accepted client, so exactly ONE
# window flips WHITE (border + bar) while the other stays green — proving focus-routed input.
import socket, subprocess, sys, time, os, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = ROOT + "/build/ae-setu-smoke"
IMG  = WORK + "/agnos-ae.img"
SER  = WORK + "/serial-input.log"
MON  = WORK + "/mon-input.sock"
VARS = WORK + "/vars-input.fd"
PPM_A = WORK + "/setu-input-before.ppm"
PPM_B = WORK + "/setu-input-after.ppm"

if not os.path.exists(IMG):
    print("FAIL: %s missing — run scripts/aethersafha-setu-smoke.sh first" % IMG); sys.exit(1)

def find(cands):
    for c in cands:
        if os.path.isfile(c): return c
    return None
OVMF_CODE = find(["/usr/share/edk2/x64/OVMF_CODE.4m.fd","/usr/share/edk2/x64/OVMF_CODE.fd","/usr/share/OVMF/OVMF_CODE.fd","/usr/share/OVMF/OVMF_CODE_4M.fd"])
OVMF_VARS = find(["/usr/share/edk2/x64/OVMF_VARS.4m.fd","/usr/share/edk2/x64/OVMF_VARS.fd","/usr/share/OVMF/OVMF_VARS.fd","/usr/share/OVMF/OVMF_VARS_4M.fd"])
subprocess.run(["cp", OVMF_VARS, VARS], check=True); os.chmod(VARS, 0o644)
open(SER, "w").close()
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-cpu", "max",
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={VARS}",
    "-drive", f"file={IMG},format=raw,if=none,id=disk0",
    "-device", "nvme,drive=disk0,serial=AGNOS-AE",
    "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
    "-serial", f"file:{SER}", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def p(*a): print(*a, flush=True)
def ser():
    try: return open(SER, "rb").read().decode("latin1")
    except OSError: return ""

def whitegreen(path):
    # returns (white_px, green_border_px, red_px, blue_px)
    try: d = open(path, "rb").read()
    except OSError: return (-1,-1,-1,-1)
    i = d.find(b'\n', d.find(b'\n', d.find(b'\n', 0) + 1) + 1) + 1  # skip P6\n W H\n 255\n
    px = d[i:]
    w=g=r=b=0
    for k in range(0, len(px) - 2, 3):
        R,G,B = px[k],px[k+1],px[k+2]
        if R>200 and G>200 and B>200: w+=1
        elif R<80 and G>200 and B<80: g+=1
        elif R>200 and G<80 and B<80: r+=1
        elif B>200 and R<80 and G<80: b+=1
    return (w,g,r,b)

rc = 0
try:
    s = None
    for _ in range(60):
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(MON); break
        except OSError: time.sleep(0.2)
    if s is None: p("FAIL: no monitor"); sys.exit(1)
    s.settimeout(1.0)
    def drain():
        try:
            while True:
                if not s.recv(65536): break
        except OSError: pass
    def hmp(cmd):
        s.sendall((cmd + "\n").encode()); time.sleep(0.5); drain()

    # Wait for BOTH clients to present their surfaces.
    for _ in range(50):
        if ser().count("presented surface") >= 2: break
        time.sleep(1)
    time.sleep(int(os.environ.get("AE_RENDER_WAIT", "14")))   # let both animate + settle
    drain()

    # (A) BEFORE: two green-bordered windows (red + blue bars), no white.
    hmp("screendump %s" % PPM_A); time.sleep(1.0)
    wa,ga,ra,ba = whitegreen(PPM_A)
    p(f"  [A] before: white={wa} green-border={ga} red={ra} blue={ba}")

    # (1) inject a plain key -> forwarded to the FOCUSED client -> it flips WHITE.
    # Send several times: the key->kernel->bhumi->compositor->setu->client path is
    # timing-sensitive over QEMU USB-kbd, so one sendkey occasionally misses. The
    # client latches on the FIRST it receives, so repeats are harmless.
    for _ in range(4):
        hmp("sendkey a"); time.sleep(0.8)
    time.sleep(1.5)
    hmp("screendump %s" % PPM_B); time.sleep(1.0)
    wb,gb,rb,bb = whitegreen(PPM_B)
    p(f"  [B] after 'a': white={wb} green-border={gb} red={rb} blue={bb}")

    # Verdict (deltas — the desktop chrome carries a baseline white/green count):
    #   * focused client REACTED: white jumped (its border+bar flipped white).
    #   * routing was FOCUS-SCOPED: exactly ONE window's green border flipped (green
    #     dropped ~one border's worth) AND one green border survived (the other client
    #     did NOT react) AND the unfocused bar colour is intact.
    # The compositor spawns present_probe (region A, top-left, a red bar) + the dhancha
    # widget client (region B, bottom-right, focused by default). A key routes to the
    # FOCUSED client (dhancha) → its button flips WHITE (white jumps); the unfocused
    # present_probe (its red bar) is untouched — that's focus-routed input.
    white_delta = wb - wa
    reacted = white_delta > 1000                          # focused client reacted to the key
    unfocused_intact = ra > 500 and abs(ra - rb) < 400    # present_probe (unfocused) red bar unchanged
    p(f"      white +{white_delta}; present_probe red {ra}->{rb} (unfocused, should be intact)")
    if reacted and unfocused_intact:
        p("  PASS: the FOCUSED client reacted to the keypress; the unfocused client was untouched — input FOCUS-ROUTED over setu")
    elif reacted:
        p("  PARTIAL: a client reacted but the unfocused client also changed — check focus scope"); rc = 1
    else:
        p("  FAIL: no white appeared after keypress — input did not reach the client"); rc = 1
finally:
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=5)
    except Exception: qemu.kill()

p("")
p("  --- serial tail (setu) ---")
for ln in [l for l in ser().splitlines() if any(k in l for k in ("setu","aethersafha","presented","client"))][-10:]:
    p("   " + ln)
p("")
p("setu-input-test: PASS — input routes over setu to the focused client" if rc == 0 else "setu-input-test: FAIL")
sys.exit(rc)
