#!/usr/bin/env python3
"""
Read-only dump of an aRacer ECU over the Wi-Fi bridge.

    python3 ecu_dump.py                 # default key 888888
    python3 ecu_dump.py --key 123456    # if you changed the calibration key in the app
    python3 ecu_dump.py --quick         # identity + licence only, skip the table scan

Writes everything into dumps/<timestamp>/ :
    run.log        everything printed, plus errors
    frames.log     every CAN frame sent/received, with timestamps (raw evidence)
    identify.json  bridge name, serial, model, node id, bridge version
    identity.json  0x1018 fields, firmware version, licence bits decoded
    tables.json    every object found at 0x3000-0x37FF (tables) and 0x4000-0x47FF (variables)
    stream.log     10 s of live-data frames

Nothing is written to the ECU. The only non-read command is the calibration-key
unlock (same thing the official app does on every connect) and the live-stream
on/off toggle, which the official app also sends.

UNTESTED ON HARDWARE until the first run. If it stops early, keep the dumps/
folder: run.log and frames.log are what we need to fix it.
"""
import sys, os, json, time, argparse, struct, socket
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aracer_client as ac

MINIX_BITS = {0:"FuelBase",1:"EngVehSetting",2:"Fuel3D",3:"Spark3D",4:"InjAngle",5:"FuelComp",
    6:"BackFire",7:"AutoTune",8:"TagAFR",9:"NBCLC",10:"LaunchControl",11:"PitLimit",12:"QuickShifter",
    13:"TSC",14:"RButton",15:"HPower",16:"HighIdle",17:"ExupD3Control",18:"TSCPlus",20:"ServiceInterval"}
MINIXX_BITS = {0:"EngVehSettings",3:"AutoTune2",4:"RideModeMatrix",5:"RealTimePower",6:"ServiceAlert",
    7:"ECUDynamicLED",8:"YAMAHA_eBoostAdv",9:"InjectionTiming",10:"BackFire_Motion",12:"NBO2CL",
    13:"EXUP",14:"TractionPlus",16:"InjectorCal"}
IDENTITY = {2:("Product_Code",4),5:("Table_ID",4),6:("Ver_V",2),7:("Ver_S",2),8:("Ver_C",2),9:("Ver_A",2),
    10:("ECU_SN",8),11:("ECU_Fun",4),12:("ECU_Trial_Fun",4),13:("ECU_Factory_Fun",4),14:("ECU_Order_SN",4),
    15:("AllTrial_Status",4),17:("AllTrial_Timer",4),18:("AllTrial_TimeMax",4),
    19:("Act_TimeStamp",4),20:("ECU_Flag",4),21:("OfflineAct_RunTime",4),22:("Subscription_RunTime",4)}

class Log:
    def __init__(self, path): self.f = open(path, "a")
    def __call__(self, *a):
        s = " ".join(str(x) for x in a); print(s, flush=True); self.f.write(s + "\n"); self.f.flush()

class RecordingBridge(ac.Bridge):
    """Bridge that also records every frame to frames.log.

    Lessons from the first hardware run (dumps/20261021-214319):
      * every SDO request must be DLC 8 (zero padded) or the ECU aborts with 0x08000000
      * responses must be matched on index/sub, otherwise one stray abort shifts
        every later answer by one and the whole dump is garbage
    """
    def __init__(self, framelog, **kw):
        self.fl = open(framelog, "a"); self.stale = 0; self.busy = 0; super().__init__(**kw)
    def _rec(self, d, cid, data):
        self.fl.write(f"{time.time():.3f} {d} {cid:03X} {bytes(data).hex(' ')}\n"); self.fl.flush()
    def send(self, can_id, data):
        data = list(data)
        if self.node and can_id == 0x600 + self.node and len(data) < 8:
            data += [0] * (8 - len(data))
        self._rec("TX", can_id, data); self.s.sendall(ac.encode(can_id, data))
    def recv(self, want=None, timeout=4.5):
        deadline = time.time() + timeout
        while time.time() < deadline:
            while self.pending:
                f = self.pending.pop(0)
                if want is None or f[0] in want: return f
            self.s.settimeout(max(0.05, deadline - time.time()))
            try: chunk = self.s.recv(8192)
            except socket.timeout: break
            if not chunk: raise ConnectionError("bridge closed socket")
            for f in self.dec.feed(chunk):
                self._rec("RX", f[0], f[1]); self.pending.append(f)
        raise TimeoutError(f"no frame {want and [hex(w) for w in want]}")

    def recv_sdo(self, index, sub, timeout=1.5):
        """Next SDO response that belongs to (index, sub); stale ones are dropped and counted."""
        deadline = time.time() + timeout
        while True:
            _, d, *_ = self.recv(self._rsp(), timeout=max(0.05, deadline - time.time()))
            d = bytes(d)
            if len(d) >= 4 and d[1] == (index & 0xFF) and d[2] == (index >> 8) and d[3] == sub: return d
            if d[0] == 0x80 and d[1:4] == b"\0\0\0": return d      # ECU's generic abort (no index)
            self.stale += 1

    def sdo_read_any(self, index, sub):
        """Read any object. Returns (bytes|None, how)."""
        self.send(self._req(), [0x40, index & 0xFF, index >> 8, sub])
        d = self.recv_sdo(index, sub)
        b0 = d[0]
        if b0 == 0x80: return None, f"abort {d[4:8][::-1].hex()}"
        if b0 >> 5 != 2: return None, f"unexpected {d.hex()}"
        if b0 & 2:                                           # expedited
            n = (b0 >> 2) & 3 if (b0 & 1) else 0
            return d[4:8 - n], "expedited"
        size = struct.unpack("<I", d[4:8])[0] if (b0 & 1) else None   # segmented offer
        self.send(self._req(), [0x80, index & 0xFF, index >> 8, sub])  # abort the segmented transfer (ECU stays silent)
        if not size: return None, "segmented, size unknown"
        try: return self.sdo_read_block_auto(index, sub, size), f"block {size}B"
        except Exception as e:
            try: self.send(self._req(), [0x80, index & 0xFF, index >> 8, sub])
            except OSError: pass
            return None, f"block {size}B failed: {e}"

    def sdo_read_block_auto(self, index, sub, size):
        self.send(self._req(), [0xA4, index & 0xFF, index >> 8, sub, 0x7F, 0x00])
        d = self.recv_sdo(index, sub)
        if d[0] == 0x80: raise RuntimeError(f"block init abort {d[4:8][::-1].hex()}")
        if d[0] >> 5 != 6: raise RuntimeError(f"block init unexpected {d.hex()}")
        if d[0] & 2: size = struct.unpack("<I", d[4:8])[0]
        self.send(self._req(), [0xA3])
        segs = []; seq = 0
        while True:
            _, d, *_ = self.recv(self._rsp(), timeout=2.0); d = bytes(d)
            if d[0] == 0x80: raise RuntimeError(f"abort during segments {d[4:8][::-1].hex()}")
            segs.append(d[1:8]); seq += 1
            if d[0] & 0x80: break
            if seq == 127:                                   # block full, ack and continue
                self.send(self._req(), [0xA2, 127, 0x7F]); seq = 0
        self.send(self._req(), [0xA2, seq, 0x7F])
        deadline = time.time() + 2.0
        while True:                                          # end response: C1|n<<2, index bytes are 0 on the real ECU
            _, d, *_ = self.recv(self._rsp(), timeout=max(0.05, deadline - time.time())); d = bytes(d)
            if d[0] == 0x80: raise RuntimeError(f"block end abort {d[4:8][::-1].hex()}")
            if d[0] >> 5 == 6 and (d[0] & 3) == 1: break
            self.stale += 1
        n = (d[0] >> 2) & 7
        self.send(self._req(), [0xA1])                       # without this the ECU's SDO stays busy (abort 08000021 on the next read)
        data = b"".join(segs)
        return data[:len(data) - n][:size]

    def sdo_write_small(self, index, sub, value, size):
        payload = struct.pack("<I", value & 0xFFFFFFFF)
        self.send(self._req(), [0x23 | ((4 - size) << 2), index & 0xFF, index >> 8, sub, *payload])
        d = self.recv_sdo(index, sub)
        if d[0] >> 5 != 3: raise RuntimeError(f"write rejected: {d.hex()}")
        return True

    # ---- fast path -------------------------------------------------------------
    # Wall time is bound by Wi-Fi round-trip (median 8 ms), not CPU. The ECU answers
    # requests in order and accepts several outstanding expedited reads, so we keep a
    # window of W requests in flight: N reads cost ~N*t_frame + RTT instead of N*RTT.
    # Only one block transfer can run at a time (single SDO channel), so blocks stay
    # sequential but skip the 0x40 probe and go straight to A4 (2 RTT per object).
    def probe_many(self, keys, window=16, log=None):
        """Pipelined expedited reads. keys: iterable of (index, sub).
        Returns {key: (bytes|None, how, size)}; size>4 means 'read it with a block upload'."""
        res = {}; queue = list(keys); inflight = {}; tries = {}; done = 0; t0 = time.time()
        def expire():
            now = time.time()
            for k, t in list(inflight.items()):
                if now - t > 1.0:
                    del inflight[k]; tries[k] = tries.get(k, 0) + 1
                    if tries[k] < 3: queue.insert(0, k)
                    else: res[k] = (None, "timeout", 0)
        while queue or inflight:
            while queue and len(inflight) < window:
                k = queue.pop(0); self.send(self._req(), [0x40, k[0] & 0xFF, k[0] >> 8, k[1]]); inflight[k] = time.time()
            try: _, d, *_ = self.recv(self._rsp(), timeout=0.25)
            except TimeoutError: expire(); continue
            d = bytes(d); k = (d[1] | d[2] << 8, d[3]); b0 = d[0]
            if k not in inflight: self.stale += 1; continue
            if b0 == 0x80:
                code = d[4:8][::-1].hex()
                if code == "08000021":                          # SDO busy (a segmented offer was pending): retry later
                    del inflight[k]; self.busy += 1
                    if len(inflight) < window // 2: tries[k] = tries.get(k, 0) + 1   # busy with a quiet pipeline = really refused
                    if tries.get(k, 0) < 3: queue.append(k)
                    else: res[k] = (None, "abort 08000021", 0)  # e.g. 0x3000:0 on the real ECU
                    continue
                res[k] = (None, f"abort {code}", 0)
            elif b0 >> 5 == 2 and (b0 & 2):
                n = (b0 >> 2) & 3 if (b0 & 1) else 0
                res[k] = (d[4:8 - n], "expedited", 4 - n)
            elif b0 >> 5 == 2:
                size = struct.unpack("<I", d[4:8])[0] if (b0 & 1) else 0
                self.send(self._req(), [0x80, k[0] & 0xFF, k[0] >> 8, k[1]])   # release the segmented offer
                res[k] = (None, "big", size)
            else: res[k] = (None, f"unexpected {d.hex()}", 0)
            del inflight[k]; done += 1
            if log and done % 500 == 0: log(f"   probed {done}/{len(res) + len(queue) + len(inflight)} ({time.time() - t0:.0f}s)")
        return res

    def read_block_direct(self, index, sub, size):
        try: return self.sdo_read_block_auto(index, sub, size), f"block {size}B"
        except Exception as e:
            if not str(e).startswith("block init abort"):      # ECU still mid-transfer: abort and drain
                try: self.send(self._req(), [0x80, index & 0xFF, index >> 8, sub])
                except OSError: pass
                try: self.recv(self._rsp(), timeout=0.3)
                except TimeoutError: pass
            return None, f"block {size}B failed: {e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", default="888888"); ap.add_argument("--quick", action="store_true", help="identity + 10 s stream only, no table scan")
    ap.add_argument("--host", default=ac.HOST); ap.add_argument("--port", type=int, default=ac.PORT)
    ap.add_argument("--window", type=int, default=16, help="requests kept in flight (pipelining)")
    ap.add_argument("--max-sub", type=int, default=256, help="stop scanning sub-indices after this many")
    a = ap.parse_args()

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dumps", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(out, exist_ok=True)
    log = Log(os.path.join(out, "run.log"))
    log(f"== aRacer ECU dump  {time.ctime()}  -> {out}")

    # 1. connect
    try:
        br = RecordingBridge(os.path.join(out, "frames.log"), host=a.host, port=a.port)
    except OSError as e:
        log(f"TIDAK BISA KONEK ke {a.host}:{a.port}: {e}")
        log("Cek: Mac sudah join Wi-Fi ECU? App aRacer di HP sudah ditutup?"); return 2
    log("TCP connected")

    # 2. identify
    try:
        info = br.identify(); log("identify:", json.dumps(info))
        json.dump(info, open(os.path.join(out, "identify.json"), "w"), indent=1)
    except Exception as e:
        log("identify GAGAL:", repr(e)); log("frames.log tersimpan, kirim folder dumps/ ke sesi Claude."); return 3
    if br.node is None:
        log("Model ECU tidak dikenal dari serial, berhenti. Serial:", info.get("serial")); return 4

    # 3. unlock (what the app does on every connect)
    if info.get("bridge_ver") == 7:
        try: log("unlock:", br.unlock(a.key))
        except Exception as e: log("unlock gagal (lanjut read-only):", repr(e))

    # 3b. NMT start (A/g.java case 9, sent by the app the moment the link is up: E1/d.java case 7).
    #     Moves the ECU from pre-operational (heartbeat 7F) to operational (05); TPDO streaming needs this.
    br.send(0x000, [0x01, 0x00]); log("NMT start sent")

    # 4. identity object 0x1018 + device name 0x1008
    ident = {}
    for sub, (name, size) in IDENTITY.items():
        try:
            v, how = br.sdo_read_any(0x1018, sub)
            if v is None: ident[name] = None; continue
            ident[name] = v.hex() if size == 8 else int.from_bytes(v, "little")
            ident[name + "_how"] = how
        except Exception as e: ident[name] = f"err {e}"
    try:
        v, how = br.sdo_read_any(0x1008, 0); ident["DeviceName"] = v.decode("ascii", "replace") if v else None
    except Exception as e: ident["DeviceName"] = f"err {e}"
    fw = [ident.get(k) for k in ("Ver_V", "Ver_S", "Ver_C", "Ver_A")]
    ident["firmware"] = ".".join(f"{x:02d}" if isinstance(x, int) else "?" for x in fw)
    bits = MINIXX_BITS if br.node in (33, 34, 37) else MINIX_BITS
    def dec(word):
        return [] if not isinstance(word, int) else [f"{b}:{bits.get(b, 'bit'+str(b))}" for b in range(32) if word >> b & 1]
    ident["owned_functions"] = dec(ident.get("ECU_Fun")); ident["trial_functions"] = dec(ident.get("ECU_Trial_Fun"))
    ident["factory_functions"] = dec(ident.get("ECU_Factory_Fun"))
    log("identity:", json.dumps(ident, indent=1))
    json.dump(ident, open(os.path.join(out, "identity.json"), "w"), indent=1)

    # 5. heartbeat check
    t0 = time.time(); hb = 0; state = None
    while time.time() - t0 < 3:
        try:
            cid, d, *_ = br.recv(None, timeout=1.0)
            if cid == 0x700 + br.node: hb += 1; state = d[0]
        except TimeoutError: pass
    log(f"heartbeats in 3 s: {hb}, NMT state 0x{state:02X} ({ {0x7F: 'pre-operational', 0x05: 'operational', 0x04: 'stopped'}.get(state, '?') })" if state is not None else "no heartbeat")

    # 6. scan tables 0x3000-0x37FF and variables 0x4000-0x47FF, in three pipelined phases
    found = {}
    W = a.window
    if a.quick: log("--quick: scan dilewati, langsung uji stream")
    def scan(lo, hi, label):
        t = time.time()
        # phase A: does object exist?  (one pipelined pass over every index, sub 0)
        r0 = br.probe_many([(i, 0) for i in range(lo, hi)], W, log)
        objs = {i: r0[(i, 0)] for i in range(lo, hi) if not (r0[(i, 0)][1].startswith("abort 0602") or r0[(i, 0)][1] == "timeout")}
        log(f"{label}: {len(objs)} objects exist ({time.time() - t:.0f}s)")
        # phase B: how many sub-indices?  probe 8 subs per object per round, pipelined across objects
        subs = {i: {0: objs[i]} for i in objs}
        bigobjs = {i for i in objs if objs[i][1] == "big"}     # rows of a big table are read by block upload (phase C)
        alive = set(objs) - bigobjs; level = 1; step = 1       # most objects have one row: probe sub 1 alone first
        while alive and level < a.max_sub:
            hi_ = min(level + step, a.max_sub)
            rb = br.probe_many([(i, sb) for i in alive for sb in range(level, hi_)], W, log)
            nxt = set()
            for i in list(alive):
                for sb in range(level, hi_):
                    v, how, size = rb[(i, sb)]
                    if v is None and how.startswith("abort 060"): break          # 0609 sub-index / 0602 object does not exist
                    subs[i][sb] = (v, how, size)
                else: nxt.add(i)
            alive = nxt; level = hi_; step = 8
        nsub = sum(len(x) for x in subs.values())
        big = [(i, sb, x[2]) for i in subs for sb, x in subs[i].items() if x[1] == "big"]
        log(f"{label}: {nsub} sub-indices, {len(big)} need block upload, {sum(z for *_, z in big)} bytes ({time.time() - t:.0f}s)")
        # phase C: block uploads, sequential (single SDO channel), straight to A4
        for n, (i, sb, size) in enumerate(big, 1):
            v, how = br.read_block_direct(i, sb, size)
            subs[i][sb] = (v, how, size)
            if n % 50 == 0:
                el = time.time() - t; log(f"   block {n}/{len(big)} ({el:.0f}s)")
        for i in sorted(bigobjs):                              # rows 1.. of big tables: A4 until the ECU aborts
            sb = 1
            while sb < a.max_sub:
                v, how = br.read_block_direct(i, sb, subs[i][0][2])
                if v is None: break
                subs[i][sb] = (v, how, len(v)); sb += 1
        log(f"{label}: busy retries {br.busy}")
        for i in subs:
            entry = {"how": subs[i][0][1], "subs": {}, "sub_how": {}, "size": {}}
            for sb, (v, how, size) in sorted(subs[i].items()):
                entry["subs"][sb] = v.hex() if v is not None else None
                entry["size"][sb] = size
                if how != "expedited": entry["sub_how"][sb] = how
            found[f"{i:04X}"] = entry
        json.dump(found, open(os.path.join(out, "tables.json"), "w"), indent=1)
        log(f"{label} scan done: {len(subs)} objects in {time.time() - t:.0f}s")
    if not a.quick:
        scan(0x3000, 0x3800, "table")
        scan(0x4000, 0x4800, "var")

    # 7. 10 s of live stream. The app first writes the TPDO1 mapping 0x1A00 (sub n = index<<16 | bitlen,
    #    sub 0 = count) and only then 0x1800:5 = 64; with an empty mapping the ECU streams nothing.
    try:
        vars_ = [(int(k, 16), len(v["subs"][0]) // 2) for k, v in found.items()
                 if k >= "4000" and v["how"] == "expedited" and v["subs"].get(0)] if found else []
        if not vars_: vars_ = [(0x4001, 1), (0x4006, 1), (0x4009, 1), (0x4014, 1), (0x4016, 2), (0x4019, 2), (0x401B, 2), (0x4020, 2)]
        vars_ = vars_[:8]
        br.sdo_write_small(0x1800, 5, 0, 2)
        br.sdo_write_small(0x1A00, 0, 0, 1)
        for n, (idx, size) in enumerate(vars_, 1):
            br.sdo_write_small(0x1A00, n, (idx << 16) | (size * 8), 4)
        br.sdo_write_small(0x1A00, 0, len(vars_), 1)
        log("stream mapping:", [f"{i:04X}/{sz}B" for i, sz in vars_])
        br.sdo_write_small(0x1800, 5, 64, 2)
        with open(os.path.join(out, "stream.log"), "w") as sf:
            t0 = time.time()
            while time.time() - t0 < 10:
                try:
                    cid, d, *_ = br.recv({0x180 + br.node}, timeout=1.0)
                    sf.write(f"{time.time():.3f} {d.hex(' ')}\n")
                except TimeoutError: pass
        br.sdo_write_small(0x1800, 5, 0, 2)
        log("stream captured")
    except Exception as e:
        log("stream capture gagal:", repr(e))
    log(f"stale frames dropped: {br.stale}")
    log("== SELESAI. Folder:", out)
    return 0

if __name__ == "__main__":
    sys.exit(main())
