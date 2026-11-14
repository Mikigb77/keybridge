#!/usr/bin/env python3
"""KeyBridge: make this (WSL2) Linux act as a classic Bluetooth keyboard + mouse (HID combo device).

Run as root, with bluetoothd started WITHOUT its input plugin (-P input), which prepare.sh sets
up. Keys typed in this terminal are sent to the connected host (another computer, a Mac on its
setup screen, a tablet, ...). Ctrl+Q quits.

The mouse: the laptop's touchpad/mouse is captured on Windows by windows/MouseBridge.cs, which
streams it here over 127.0.0.1:<--mouse-port>. Ctrl+G toggles whether the pointer goes to the
host or stays on the laptop.

See docs/how-it-works.md for the design and the reasons behind it.
"""
import argparse
import os
import select
import socket
import struct
import subprocess
import sys
import termios
import threading
import time
import tty

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

# ---------------------------------------------------------------------------------------------
# HID description
# ---------------------------------------------------------------------------------------------
# Report ID 1: standard 8-byte keyboard report (modifiers, reserved, 6 key codes).
# Report ID 2: mouse = 5 buttons + X,Y (16-bit relative) + wheel + AC Pan (horizontal scroll).
REPORT_MAP = (
    "05010906a1018501050719e029e7150025017501950881029501750881039505"
    "750105081901290591029501750391039506750815002565050719002965"
    "8100c0"
    "05010902a10185020901a100"                        # Mouse, report ID 2, Pointer
    "05091901290515002501950575018102950175038103"    # 5 buttons + 3 padding bits
    "05010930093116018026ff7f751095028106"            # X, Y: -32767..32767, relative
    "09381581257f750895018106"                        # Wheel: -127..127
    "050c0a380295018106"                              # AC Pan (horizontal scroll)
    "c0c0"
)


def sdp_record(name):
    """HID service record (Bluetooth HID profile 1.1), subclass 0xC0 = keyboard + pointing device."""
    return f"""<?xml version="1.0" encoding="UTF-8" ?>
<record>
 <attribute id="0x0001"><sequence><uuid value="0x1124" /></sequence></attribute>
 <attribute id="0x0004"><sequence><sequence><uuid value="0x0100" /><uint16 value="0x0011" /></sequence><sequence><uuid value="0x0011" /></sequence></sequence></attribute>
 <attribute id="0x0005"><sequence><uuid value="0x1002" /></sequence></attribute>
 <attribute id="0x0006"><sequence><uint16 value="0x656e" /><uint16 value="0x006a" /><uint16 value="0x0100" /></sequence></attribute>
 <attribute id="0x0009"><sequence><sequence><uuid value="0x1124" /><uint16 value="0x0101" /></sequence></sequence></attribute>
 <attribute id="0x000d"><sequence><sequence><sequence><uuid value="0x0100" /><uint16 value="0x0013" /></sequence><sequence><uuid value="0x0011" /></sequence></sequence></sequence></attribute>
 <attribute id="0x0100"><text value="{name}" /></attribute>
 <attribute id="0x0101"><text value="Keyboard and mouse" /></attribute>
 <attribute id="0x0102"><text value="KeyBridge" /></attribute>
 <attribute id="0x0200"><uint16 value="0x0100" /></attribute>
 <attribute id="0x0201"><uint16 value="0x0111" /></attribute>
 <attribute id="0x0202"><uint8 value="0xc0" /></attribute>
 <attribute id="0x0203"><uint8 value="0x00" /></attribute>
 <attribute id="0x0204"><boolean value="true" /></attribute>
 <attribute id="0x0205"><boolean value="true" /></attribute>
 <attribute id="0x0206"><sequence><sequence><uint8 value="0x22" /><text encoding="hex" value="{REPORT_MAP}" /></sequence></sequence></attribute>
 <attribute id="0x0207"><sequence><sequence><uint16 value="0x0409" /><uint16 value="0x0100" /></sequence></sequence></attribute>
 <attribute id="0x020b"><uint16 value="0x0100" /></attribute>
 <attribute id="0x020c"><uint16 value="0x0c80" /></attribute>
 <attribute id="0x020d"><boolean value="true" /></attribute>
 <attribute id="0x020e"><boolean value="true" /></attribute>
 <attribute id="0x020f"><uint16 value="0x0640" /></attribute>
 <attribute id="0x0210"><uint16 value="0x0320" /></attribute>
</record>"""


PSM_CTRL, PSM_INTR = 0x11, 0x13       # L2CAP channels of the HID profile: control, interrupt

# ---------------------------------------------------------------------------------------------
# Key maps: character -> list of (modifier, HID usage) key presses
# ---------------------------------------------------------------------------------------------
# The HOST decides which character a key produces, using ITS keyboard layout, so there is one
# map per host layout. Ctrl+L cycles through them while running.
SHIFT, ALT = 0x02, 0x04               # Left Shift, Left Alt (= Option on a Mac)


def _common():
    k = {}
    for i, c in enumerate("abcdefghijklmnopqrstuvwxyz"):
        k[c] = [(0, 4 + i)]
        k[c.upper()] = [(SHIFT, 4 + i)]
    for i, d in enumerate("1234567890"):
        k[d] = [(0, 30 + i)]
    k[" "] = [(0, 0x2C)]
    k["\r"] = k["\n"] = [(0, 0x28)]
    k["\x7f"] = k["\x08"] = [(0, 0x2A)]
    k["\t"] = [(0, 0x2B)]
    return k


def layout_us():
    """US English (any operating system)."""
    k = _common()
    for i, s in enumerate("!@#$%^&*()"):
        k[s] = [(SHIFT, 30 + i)]
    for c, code, sh in [("-", 0x2D, "_"), ("=", 0x2E, "+"), ("[", 0x2F, "{"), ("]", 0x30, "}"),
                        ("\\", 0x31, "|"), (";", 0x33, ":"), ("'", 0x34, '"'), ("`", 0x35, "~"),
                        (",", 0x36, "<"), (".", 0x37, ">"), ("/", 0x38, "?")]:
        k[c] = [(0, code)]
        k[sh] = [(SHIFT, code)]
    return k


def layout_es_mac():
    """macOS 'Spanish - ISO'. Symbols like @ # [ ] use Option (Alt), as on a Mac keyboard."""
    k = _common()
    for i, s in enumerate('!"·$%&/()='):            # Shift + 1..0
        k[s] = [(SHIFT, 30 + i)]
    for s, code in [("|", 0x1E), ("@", 0x1F), ("#", 0x20), ("¬", 0x23)]:   # Option + 1, 2, 3, 6
        k[s] = [(ALT, code)]
    for c, code, sh in [("'", 0x2D, "?"), ("¡", 0x2E, "¿"), ("+", 0x30, "*"), ("ñ", 0x33, "Ñ"),
                        ("ç", 0x31, "Ç"), (",", 0x36, ";"), (".", 0x37, ":"), ("-", 0x38, "_"),
                        ("<", 0x35, ">"), ("º", 0x64, "ª")]:
        k[c] = [(0, code)]
        k[sh] = [(SHIFT, code)]
    k["["], k["]"] = [(ALT, 0x2F)], [(ALT, 0x30)]
    k["{"], k["}"] = [(ALT, 0x34)], [(ALT, 0x31)]
    k["\\"] = [(ALT, 0x64)]
    space = (0, 0x2C)                                 # dead key + space = the accent itself
    k["`"], k["^"] = [(0, 0x2F), space], [(SHIFT, 0x2F), space]
    k["´"], k["¨"], k["~"] = [(0, 0x34), space], [(SHIFT, 0x34), space], [(ALT, 0x33), space]
    for n, (v, code) in enumerate(zip("aeiou", (0x04, 0x08, 0x0C, 0x12, 0x18))):
        acute, grave, diaer = "áéíóú"[n], "àèìòù"[n], "äëïöü"[n]
        k[acute], k[acute.upper()] = [(0, 0x34), (0, code)], [(0, 0x34), (SHIFT, code)]
        k[grave], k[grave.upper()] = [(0, 0x2F), (0, code)], [(0, 0x2F), (SHIFT, code)]
        k[diaer], k[diaer.upper()] = [(SHIFT, 0x34), (0, code)], [(SHIFT, 0x34), (SHIFT, code)]
    return k


LAYOUTS = {"us": layout_us(), "es-mac": layout_es_mac()}
ESCAPES = {"[A": 0x52, "[B": 0x51, "[C": 0x4F, "[D": 0x50, "[3~": 0x4C}       # arrows, Delete
LABELS = {0x28: "[Enter]\r\n", 0x2A: "[Bksp]", 0x2B: "[Tab]", 0x29: "[Esc]", 0x52: "[Up]",
          0x51: "[Down]", 0x4F: "[Right]", 0x50: "[Left]", 0x4C: "[Del]"}
WHEEL_STEP = 120                      # Windows wheel units per HID wheel step (one notch)


def parse_args():
    p = argparse.ArgumentParser(description="Bluetooth HID keyboard + mouse emulator (run by Start-KeyBridge)")
    p.add_argument("--layout", default="us", help="keyboard layout set on the host: us | es-mac")
    p.add_argument("--name", default="KeyBridge", help="name shown to the host")
    p.add_argument("--mouse-port", type=int, default=47321, help="localhost port of the touchpad helper")
    p.add_argument("--mouse-speed", default="1.0", help="pointer speed factor on the host")
    a, _ = p.parse_known_args()
    a.layout = {"es": "es-mac"}.get(a.layout, a.layout)
    if a.layout not in LAYOUTS:
        a.layout = "us"
    a.mouse_speed = float(str(a.mouse_speed).replace(",", "."))
    return a


ARGS = parse_args()


def log(msg):
    sys.stdout.write("\r\n>>> " + msg + "\r\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------------------------
# BlueZ D-Bus objects
# ---------------------------------------------------------------------------------------------
class Agent(dbus.service.Object):
    """Pairing agent with NoInputNoOutput capability: accepts pairing ("Just Works")."""
    IFACE = "org.bluez.Agent1"

    @dbus.service.method(IFACE, in_signature="", out_signature="")
    def Release(self):
        pass

    @dbus.service.method(IFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        log(f"Authorized service {uuid}")

    @dbus.service.method(IFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        log("PIN requested -> 0000")
        return "0000"

    @dbus.service.method(IFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        log("Passkey requested -> 0")
        return dbus.UInt32(0)

    @dbus.service.method(IFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        log(f"The other device asks to TYPE THIS CODE: {passkey:06d}  (type it here, then Enter)")

    @dbus.service.method(IFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        log(f"The other device asks to TYPE THIS PIN: {pincode}  (type it here, then Enter)")

    @dbus.service.method(IFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        log(f"Pairing confirmed ({passkey:06d})")

    @dbus.service.method(IFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        log("Pairing authorized")

    @dbus.service.method(IFACE, in_signature="", out_signature="")
    def Cancel(self):
        log("Pairing cancelled by the other device")


class Profile(dbus.service.Object):
    """Only used to publish the HID SDP record; the L2CAP channels are accepted by us directly."""
    IFACE = "org.bluez.Profile1"

    @dbus.service.method(IFACE, in_signature="", out_signature="")
    def Release(self):
        pass

    @dbus.service.method(IFACE, in_signature="oha{sv}", out_signature="")
    def NewConnection(self, path, fd, props):
        os.close(fd.take())

    @dbus.service.method(IFACE, in_signature="o", out_signature="")
    def RequestDisconnection(self, path):
        pass


# ---------------------------------------------------------------------------------------------
# The HID device
# ---------------------------------------------------------------------------------------------
class HidDevice:
    def __init__(self):
        self.ctrl = self.intr = None
        self.boot = False             # host switched us to boot protocol
        self.lock = threading.Lock()
        self.mconn = None             # link to the Windows touchpad helper (MouseBridge.cs)
        self.grabbed = False          # True while the laptop pointer goes to the host
        self.buttons = 0
        self.frac = [0.0, 0.0]        # leftover sub-pixel movement (after --mouse-speed)
        self.wrem = [0, 0]            # leftover wheel units (< WHEEL_STEP)

    # ---- connections ----
    def listen(self):
        def server(psm):
            s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((socket.BDADDR_ANY, psm))
            s.listen(1)
            return s
        self.sctrl, self.sintr = server(PSM_CTRL), server(PSM_INTR)
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def _accept_loop(self):
        while True:
            c, addr = self.sctrl.accept()
            log(f"Host {addr[0]} connected (control channel)")
            i, _ = self.sintr.accept()
            log("Host connected - KEYS NOW GO TO THE OTHER DEVICE (Ctrl+G sends the mouse too)")
            self._use(c, i)

    def _use(self, c, i):
        with self.lock:
            self.ctrl, self.intr, self.boot = c, i, False
        threading.Thread(target=self._ctrl_loop, args=(c,), daemon=True).start()

    def reconnect_loop(self):
        """A host that already paired with us stops scanning and waits for the keyboard to call,
        like a real keyboard does on a key press. So while nothing is connected, call every paired
        host on the HID channels."""
        while True:
            if self.intr is None:
                out = subprocess.run(["bluetoothctl", "devices", "Paired"],
                                     capture_output=True, text=True).stdout
                for line in out.splitlines():
                    p = line.split(maxsplit=2)
                    if len(p) < 2 or p[0] != "Device" or self.intr is not None:
                        continue
                    addr, name = p[1], (p[2] if len(p) > 2 else p[1])
                    c = i = None
                    try:
                        c = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
                        c.settimeout(8)
                        c.connect((addr, PSM_CTRL))
                        i = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
                        i.settimeout(8)
                        i.connect((addr, PSM_INTR))
                        c.settimeout(None)
                        i.settimeout(None)
                        if self.intr is not None:          # the host called us meanwhile
                            c.close()
                            i.close()
                            continue
                        log(f"Reconnected to {name} - KEYS NOW GO THERE (Ctrl+G sends the mouse too)")
                        self._use(c, i)
                    except OSError:
                        for s in (c, i):
                            if s:
                                s.close()
            time.sleep(5)

    def _ctrl_loop(self, c):
        """Answer the host's HID control requests (protocol mode, idle rate, reports)."""
        while True:
            try:
                data = c.recv(64)
            except OSError:
                data = b""
            if not data:
                log("Host disconnected - waiting for it to come back")
                with self.lock:
                    self.ctrl = self.intr = None
                self.set_grab(False, " (host disconnected)")
                return
            kind, param = data[0] >> 4, data[0] & 0x0F
            try:
                if kind == 0x7:            # SET_PROTOCOL
                    self.boot = (param & 1) == 0
                    c.send(b"\x00")
                elif kind == 0x6:          # GET_PROTOCOL
                    c.send(bytes([0xA0, 0 if self.boot else 1]))
                elif kind in (0x5, 0x9):   # SET_REPORT (LEDs) / SET_IDLE
                    c.send(b"\x00")
                elif kind == 0x8:          # GET_IDLE
                    c.send(b"\xA0\x00")
                elif kind == 0x4:          # GET_REPORT (byte 1 = report ID)
                    if len(data) > 1 and data[1] == 2:
                        c.send(b"\xA1\x02" + bytes(3 if self.boot else 7))
                    else:
                        c.send(b"\xA1" + (b"" if self.boot else b"\x01") + bytes(8))
                elif kind == 0x1:          # HID_CONTROL (suspend / virtual unplug)
                    pass
                else:
                    c.send(b"\x03")        # HANDSHAKE: unsupported request
            except OSError:
                pass

    # ---- keyboard ----
    def press(self, mod, code):
        with self.lock:
            intr, boot = self.intr, self.boot
        if not intr:
            sys.stdout.write(" (not connected yet)")
            return False
        hdr = b"\xA1" if boot else b"\xA1\x01"
        try:
            intr.send(hdr + bytes([mod, 0, code, 0, 0, 0, 0, 0]))
            time.sleep(0.012)
            intr.send(hdr + bytes(8))
            time.sleep(0.012)
            return True
        except OSError:
            return False

    def type_char(self, presses):
        for mod, code in presses:
            if not self.press(mod, code):
                return

    # ---- mouse ----
    # MouseBridge.cs (Windows) connects to us and sends text lines:
    #   "M dx dy" movement, "B mask" buttons, "W v h" wheel (120 = one notch),
    #   "R" = it let go of the pointer by itself (user switched to another window).
    # We send it "G1" (capture the pointer for the host) / "G0" (give it back).
    def mouse_server(self, port):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            srv.bind(("127.0.0.1", port))
            srv.listen(1)
        except OSError as e:
            log(f"Mouse disabled: port {port} unavailable ({e}). The keyboard still works.")
            return
        while True:
            conn, _ = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            old, self.mconn = self.mconn, conn
            if old:
                old.close()
            self._mouse_pump(conn)
            if self.mconn is conn:
                self.mconn = None
                self.set_grab(False, " (touchpad helper stopped)")
            conn.close()

    def _mouse_pump(self, conn):
        buf = b""
        while True:
            try:
                data = conn.recv(4096)
            except OSError:
                data = b""
            if not data:
                return
            t0 = time.monotonic()
            buf += data
            *lines, buf = buf.split(b"\n")
            mx = my = wv = wh = 0
            for ln in lines:
                p = ln.split()
                try:
                    if not p:
                        continue
                    if p[0] == b"R":
                        self.set_grab(False, " (you switched to another window)")
                    elif not self.grabbed:
                        continue
                    elif p[0] == b"M":
                        mx += int(p[1])
                        my += int(p[2])
                    elif p[0] == b"W":
                        wv += int(p[1])
                        wh += int(p[2])
                    elif p[0] == b"B":                  # movement before the click, then the click
                        self._flush_mouse(mx, my, wv, wh)
                        mx = my = wv = wh = 0
                        self.buttons = int(p[1]) & 0x1F
                        self.send_mouse(self.buttons, 0, 0, 0, 0)
                except (IndexError, ValueError):
                    pass
            if self.grabbed:
                self._flush_mouse(mx, my, wv, wh)
            # At most ~125 reports/s; whatever arrives meanwhile is merged into the next one,
            # so the Bluetooth link never builds up a queue (= lag).
            time.sleep(max(0.0, 0.008 - (time.monotonic() - t0)))

    def _flush_mouse(self, mx, my, wv, wh):
        fx, fy = mx * ARGS.mouse_speed + self.frac[0], my * ARGS.mouse_speed + self.frac[1]
        dx, dy = int(fx), int(fy)                         # keep the fraction for next time
        self.frac = [fx - dx, fy - dy]
        self.wrem[0] += wv
        self.wrem[1] += wh
        sv, sh = int(self.wrem[0] / WHEEL_STEP), int(self.wrem[1] / WHEEL_STEP)
        self.wrem[0] -= sv * WHEEL_STEP
        self.wrem[1] -= sh * WHEEL_STEP
        if dx or dy or sv or sh:
            self.send_mouse(self.buttons, dx, dy, sv, sh)

    def send_mouse(self, buttons, dx, dy, wheel, pan):
        with self.lock:
            intr, boot = self.intr, self.boot
        if not intr:
            return

        def clamp(v, m):
            return max(-m, min(m, v))
        if boot:                                          # boot mouse: 3 buttons, 8-bit X/Y
            pkt = b"\xA1\x02" + struct.pack("<Bbb", buttons & 7, clamp(dx, 127), clamp(dy, 127))
        else:
            pkt = b"\xA1\x02" + struct.pack("<Bhhbb", buttons, clamp(dx, 32767), clamp(dy, 32767),
                                            clamp(wheel, 127), clamp(pan, 127))
        try:
            intr.send(pkt)
        except OSError:
            pass

    def toggle_mouse(self):
        if self.mconn is None:
            log("Mouse not available: the Windows touchpad helper isn't connected (keyboard still works)")
        elif not self.grabbed and self.intr is None:
            log("Not connected yet - the mouse stays on the laptop")
        else:
            self.set_grab(not self.grabbed)

    def set_grab(self, on, why=""):
        if on == self.grabbed:
            return
        self.grabbed = on
        conn = self.mconn
        try:
            if conn:
                conn.sendall(b"G1\n" if on else b"G0\n")
        except OSError:
            pass
        self.frac, self.wrem = [0.0, 0.0], [0, 0]
        if on:
            log("MOUSE NOW GOES TO THE OTHER DEVICE (touchpad, clicks, scrolling). Ctrl+G gives it back.")
        else:
            if self.buttons:                              # never leave a button held down
                self.buttons = 0
                self.send_mouse(0, 0, 0, 0, 0)
            log("Mouse is back on the laptop" + why)

    # There is deliberately NO "forget the paired host" key. A host keeps its half of the pairing
    # and waits for this keyboard to come back with the same key; if this laptop is the host's only
    # keyboard, nobody could click "Forget" on the host to start over. prepare.sh backs pairings up.


# ---------------------------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------------------------
HCI_INDEX = "0"       # set in main() to the adapter bluetoothd actually offers


def find_adapter(bus, wait=30):
    """Return (index, properties) of the adapter bluetoothd offers, once it accepts power-on.
    Right after the chip is attached bluetoothd may still be setting it up, so wait for it.
    Not hard-coded to hci0: a chip unplugged while connected can leave a dead hci0 behind."""
    deadline, last = time.monotonic() + wait, "no adapter yet"
    while time.monotonic() < deadline:
        try:
            om = dbus.Interface(bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager")
            paths = [str(p) for p, ifs in om.GetManagedObjects(timeout=5).items() if "org.bluez.Adapter1" in ifs]
            for path in sorted(paths, key=lambda p: int(p.rsplit("hci", 1)[1]), reverse=True):  # newest first
                props = dbus.Interface(bus.get_object("org.bluez", path), "org.freedesktop.DBus.Properties")
                try:
                    props.Set("org.bluez.Adapter1", "Powered", True, timeout=5)
                    return path.rsplit("hci", 1)[1], props
                except dbus.exceptions.DBusException as e:
                    last = f"{path}: {e.get_dbus_name()}"
        except dbus.exceptions.DBusException as e:
            last = e.get_dbus_name()
        time.sleep(1)
    sys.exit(f"!! The Bluetooth adapter never became ready ({last}).\n"
             "!! Close this window and start KeyBridge again.")


def keep_limited_discoverable():
    """Keyboards in pairing mode use LIMITED discoverable mode; macOS' keyboard setup assistant
    only finds a keyboard in that mode. It times out after 180 s, so keep refreshing it."""
    while True:
        subprocess.run(["btmgmt", "--index", HCI_INDEX, "discov", "limited", "180"], capture_output=True)
        time.sleep(170)


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
def main():
    global HCI_INDEX
    layout = ARGS.layout
    keys = LAYOUTS[layout]

    dbus.mainloop.glib.threads_init()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    Agent(bus, "/keybridge/agent")
    am = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.AgentManager1")
    am.RegisterAgent("/keybridge/agent", "NoInputNoOutput")
    am.RequestDefaultAgent("/keybridge/agent")
    Profile(bus, "/keybridge/profile")
    pm = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.ProfileManager1")
    pm.RegisterProfile("/keybridge/profile", "00001124-0000-1000-8000-00805f9b34fb",
                       {"ServiceRecord": sdp_record(ARGS.name), "Role": "server",
                        "RequireAuthentication": False, "RequireAuthorization": False})
    HCI_INDEX, adapter = find_adapter(bus)                               # powered on
    for k, v in [("Alias", ARGS.name), ("Pairable", True),
                 ("PairableTimeout", dbus.UInt32(0)), ("DiscoverableTimeout", dbus.UInt32(0)),
                 ("Discoverable", True)]:
        adapter.Set("org.bluez.Adapter1", k, v, timeout=5)
    # Class of device: peripheral (5), keyboard + pointing device (0xC0)
    subprocess.run(["btmgmt", "--index", HCI_INDEX, "class", "5", "192"], capture_output=True)
    threading.Thread(target=keep_limited_discoverable, daemon=True).start()

    dev = HidDevice()
    dev.listen()
    threading.Thread(target=GLib.MainLoop().run, daemon=True).start()
    threading.Thread(target=dev.reconnect_loop, daemon=True).start()
    threading.Thread(target=dev.mouse_server, args=(ARGS.mouse_port,), daemon=True).start()

    print(f"=== This laptop is now a Bluetooth KEYBOARD + MOUSE named '{ARGS.name}' ===")
    print("New device: open its Bluetooth settings (or setup assistant) and pick it; it connects within ~30 s.")
    print("A device that already paired with this laptop: KeyBridge reconnects to it by itself.")
    print("If the other device shows a code, type it here and press Enter.")
    print(f"Host keyboard layout: {layout}  (Ctrl+L switches layout if symbols come out wrong)")
    print("Ctrl+G: send the touchpad/mouse to the other device (again: give it back). Alt+Tab also gives it back.")
    print("Type here once connected. Ctrl+Q quits.\n")
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        while True:
            b = os.read(fd, 1)
            if b and b[0] >= 0xC0:                       # multi-byte UTF-8 (ñ, á, ¿, ...)
                need = 1 if b[0] < 0xE0 else 2 if b[0] < 0xF0 else 3
                b += os.read(fd, need)
            ch = b.decode(errors="ignore")
            if ch == "\x11":                              # Ctrl+Q
                break
            if ch == "\x07":                              # Ctrl+G: mouse to the host / back
                dev.toggle_mouse()
                continue
            if ch == "\x0c":                              # Ctrl+L: next layout
                names = list(LAYOUTS)
                layout = names[(names.index(layout) + 1) % len(names)]
                keys = LAYOUTS[layout]
                log(f"Host keyboard layout is now {layout}")
                continue
            if ch == "\x1b":                              # Esc, or an arrow/Delete escape sequence
                seq = ""
                while select.select([fd], [], [], 0.03)[0]:
                    seq += os.read(fd, 1).decode(errors="ignore")
                    if seq[-1:].isalpha() or seq.endswith("~"):
                        break
                code = ESCAPES.get(seq, 0x29 if not seq else None)
                if code:
                    dev.press(0, code)
                    sys.stdout.write(LABELS[code])
            elif ch in keys:
                presses = keys[ch]
                dev.type_char(presses)
                sys.stdout.write(LABELS.get(presses[0][1], ch) if len(presses) == 1 else ch)
            elif ch:
                sys.stdout.write(f"[{ch}?]")              # no key for this character in this layout
            sys.stdout.flush()
    finally:
        dev.set_grab(False)
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        print("\nStopped.")


if __name__ == "__main__":
    main()
