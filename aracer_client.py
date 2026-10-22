#!/usr/bin/env python3
"""
Proof-of-concept client for the aRacer Wi-Fi CAN bridge (reverse-engineered from
aRacer X Tune 3.7.2). Standard library only.

UNTESTED AGAINST HARDWARE. Static analysis only. Run read-only commands first and
compare against a capture of the real app before trusting any write.

Usage:
    python3 aracer_client.py identify          # bridge handshake, prints name/serial/model
    python3 aracer_client.py read 0x1018 8     # SDO expedited read (<=4 bytes)
    python3 aracer_client.py readblk 0x1008 0 10   # SDO block upload (>4 bytes)
    python3 aracer_client.py monitor 10        # enable live stream for 10 s, dump frames
    python3 aracer_client.py write 0x1800 5 64 2   # SDO expedited write (needs --i-own-this-ecu)
"""
import socket, struct, sys, time, argparse

HOST, PORT = "192.168.88.88", 6666
SYNC = b"\xF8\x01\xC0"

# ---------------------------------------------------------------- envelope --
def encode(can_id, data, ext=False, rtr=False):
    """19-byte envelope exactly as x/AbstractC0521c.a() builds it."""
    data = bytes(data)
    assert len(data) <= 8
    body = bytearray(SYNC + bytes([14]))
    body += struct.pack(">I", can_id)
    body += bytes([(2 if rtr else 0) | (1 if ext else 0), len(data)])
    body += data.ljust(8, b"\x00")
    chk = (256 - (sum(body[2:18]) & 0xFF)) & 0xFF
    body.append(chk)
    return bytes(body)

class Decoder:
    """Byte-wise resync parser mirroring aRacerWiFiCANService.b()."""
    def __init__(self):
        self.buf = bytearray(); self.state = 0; self.end = 255; self.sum = 0
    def feed(self, chunk):
        out = []
        for b in chunk:
            i = self.state
            if (i == 0 and b != 0xF8) or (i == 1 and b != 0x01) or (i == 2 and b != 0xC0):
                self.state = 0; self.end = 255; self.sum = 0; self.buf = bytearray(); continue
            if i == 0: self.buf = bytearray()
            self.buf.append(b)
            if i == 3:
                self.end = b + 4
            elif i == self.end:
                if ((256 - (self.sum & 0xFF)) & 0xFF) == b:
                    out.append(self._frame(bytes(self.buf)))
                self.state = 0; self.end = 255; self.sum = 0; continue
            if i >= 2: self.sum += b
            self.state = i + 1
        return out
    @staticmethod
    def _frame(raw):
        can_id = struct.unpack(">I", raw[4:8])[0]
        ext = bool(raw[8] & 1)
        can_id &= 0x1FFFFFFF if ext else 0x7FF
        dlc = raw[9]
        return (can_id, raw[10:10 + dlc], ext, bool(raw[8] & 2))

# ------------------------------------------------------------------ client --
class Bridge:
    def __init__(self, host=HOST, port=PORT, timeout=11.0):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.s.settimeout(4.5)
        self.dec = Decoder(); self.pending = []
        self.node = None
    def send(self, can_id, data):
        if self.node and can_id == 0x600 + self.node and len(data) < 8:
            data = list(data) + [0] * (8 - len(data))   # ECU aborts SDO frames with DLC < 8
        print(f"  -> {can_id:03X} {bytes(data).hex(' ')}")
        self.s.sendall(encode(can_id, data))
    def recv(self, want=None, timeout=4.5):
        """Return next frame (optionally only with CAN ID in `want`). Others are logged."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            while self.pending:
                f = self.pending.pop(0)
                if want is None or f[0] in want:
                    print(f"  <- {f[0]:03X} {f[1].hex(' ')}"); return f
                self._log_other(f)
            self.s.settimeout(max(0.05, deadline - time.time()))
            try: chunk = self.s.recv(8192)
            except socket.timeout: break
            if not chunk: raise ConnectionError("bridge closed socket")
            self.pending += self.dec.feed(chunk)
        raise TimeoutError(f"no frame {want and [hex(w) for w in want]}")
    def _log_other(self, f):
        cid, d = f[0], f[1]
        if self.node and cid == 0x700 + self.node: tag = "heartbeat"
        elif self.node and cid == 0x180 + self.node: tag = "pdo"
        elif cid == 0x681 and len(d) == 1: tag = "ECU REQUESTS DISCONNECT"
        else: tag = "other"
        print(f"  .. {cid:03X} {d.hex(' ')}  ({tag})")

    # --- §4 bridge identification --------------------------------------
    MODEL = {0xA6: ("RC MiniX", 1), 0xA3: ("RC SuperX", 2), 0xA4: ("RC SuperX Pro", 4),
             0xA5: ("RC SuperX Pro", 5), 0xB6: ("family B6", 33), 0xB3: ("family B3", 34),
             0xB5: ("family B5", 37)}
    def identify(self):
        name = bytearray(15); serial = bytearray(8); info = {}
        self.send(0x681, [0x00])
        cid, d, *_ = self.recv({0x6A1})
        info["bridge_ver"], info["bridge_sub"] = d[0], d[1]
        self.send(0x682, [0xD1])
        while True:
            cid, d, *_ = self.recv({0x6A2, 0x6A0})
            op = d[0]
            if op == 0xD2: name[0:7] = d[1:8]
            elif op == 0xD3: name[7:14] = d[1:8]
            elif op == 0xD4:
                name[14] = d[1]; info["name"] = name.decode("ascii", "replace").strip("\x00 ")
                self.send(0x682, [0xC1])
            elif op == 0xC2:
                info["product_code"] = struct.unpack(">I", d[1:5])[0]; self.send(0x682, [0xB1])
            elif op == 0xB2: serial[0:7] = d[1:8]
            elif op == 0xB3:
                serial[7] = d[1]; info["serial"] = serial.hex().upper()
                model, node = self.MODEL.get(serial[0], ("unknown", None))
                info["model"], info["node"] = model, node; self.node = node
                if serial[0] in (0xB3, 0xB6) and info["bridge_ver"] == 7:
                    self.send(0x680, [0x9A]); continue
                break
            elif op == 0x9B:
                info["code_9b"] = f"{(d[1] << 8) | d[2]:04X}"; break
        return info

    def unlock(self, key_decimal=888888):
        """§4 step 6. Only meaningful when bridge_ver == 7. Default key is the app's default."""
        k = int(key_decimal)
        self.send(0x680, [0x88, 0x00, (k >> 16) & 0xFF, (k >> 8) & 0xFF, k & 0xFF])
        cid, d, *_ = self.recv({0x6A0})
        return d[0] == 0x89 and d[1] == 0

    # --- §5 SDO ----------------------------------------------------------
    def _req(self): return 0x600 + self.node
    def _rsp(self): return {0x580 + self.node}
    def sdo_read(self, index, sub):
        self.send(self._req(), [0x40, index & 0xFF, index >> 8, sub, 0, 0, 0, 0])
        _, d, *_ = self.recv(self._rsp())
        b0 = d[0]
        if b0 >> 5 == 2 and (b0 & 2):              # expedited response (scs=2)
            n = (b0 >> 2) & 3
            return d[4:8 - n]
        if b0 == 0x80: raise RuntimeError(f"SDO abort {d[4:8].hex()}")
        raise RuntimeError(f"unexpected SDO response {d.hex()}")
    def sdo_read_block(self, index, sub, size):
        self.send(self._req(), [0xA4, index & 0xFF, index >> 8, sub, 0x7F, 0x00, 0, 0])
        _, d, *_ = self.recv(self._rsp())
        if d[0] & 2:
            got = struct.unpack("<I", d[4:8])[0]
            if got != size: raise RuntimeError(f"size mismatch: ECU says {got}, expected {size}")
        self.send(self._req(), [0xA3])
        segs = []
        while True:
            _, d, *_ = self.recv(self._rsp(), timeout=2.0)
            segs.append(d[1:8])
            if d[0] & 0x80: break
        self.send(self._req(), [0xA2, len(segs), 0x7F])
        _, d, *_ = self.recv(self._rsp())
        n = (d[0] >> 2) & 7
        if d[0] & 3 != 1: raise RuntimeError(f"block end not confirmed: {d.hex()}")
        self.send(self._req(), [0xA1])
        data = b"".join(segs)
        return data[:len(data) - n]
    def sdo_write(self, index, sub, value, size):
        assert 1 <= size <= 4
        payload = struct.pack("<I", value & 0xFFFFFFFF)
        self.send(self._req(), [0x23 | ((4 - size) << 2), index & 0xFF, index >> 8, sub, *payload])
        _, d, *_ = self.recv(self._rsp())
        if d[0] >> 5 != 3: raise RuntimeError(f"write rejected: {d.hex()}")
        return True

    # --- §7 live stream --------------------------------------------------
    def monitor(self, seconds):
        self.sdo_write(0x1800, 5, 64, 2)
        buf = bytearray(); t_end = time.time() + seconds
        try:
            while time.time() < t_end:
                try: cid, d, *_ = self.recv({0x180 + self.node}, timeout=1.0)
                except TimeoutError: continue
                if d[0] & 0x7F == 1: buf = bytearray()
                buf += d[1:]
                if d[0] & 0x80:
                    print(f"  record {len(buf)} bytes: {bytes(buf).hex(' ')}")
        finally:
            self.sdo_write(0x1800, 5, 0, 2)

# -------------------------------------------------------------------- main --
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["identify", "read", "readblk", "write", "monitor"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--host", default=HOST); ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--node", type=int, help="override node id (skip identify)")
    ap.add_argument("--key", default="888888", help="calibration key, decimal")
    ap.add_argument("--i-own-this-ecu", action="store_true", help="required for write")
    a = ap.parse_args()
    br = Bridge(a.host, a.port)
    if a.node: br.node = a.node
    else:
        info = br.identify(); print("identify:", info)
        if info.get("bridge_ver") == 7: print("unlock ok:", br.unlock(a.key))
    if br.node is None: sys.exit("unknown ECU model; pass --node")
    h = lambda x: int(x, 0)
    if a.cmd == "read":
        v = br.sdo_read(h(a.args[0]), h(a.args[1])); print("value:", v.hex(' '), int.from_bytes(v, "little"))
    elif a.cmd == "readblk":
        v = br.sdo_read_block(h(a.args[0]), h(a.args[1]), h(a.args[2])); print("data:", v.hex(' '), v)
    elif a.cmd == "write":
        if not a.i_own_this_ecu: sys.exit("refusing to write without --i-own-this-ecu")
        print("ok:", br.sdo_write(h(a.args[0]), h(a.args[1]), h(a.args[2]), h(a.args[3])))
    elif a.cmd == "monitor":
        br.monitor(float(a.args[0]) if a.args else 10)

if __name__ == "__main__":
    main()
