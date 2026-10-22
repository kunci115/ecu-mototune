# aRacer X Tune 3.7.2 — phone ↔ ECU protocol (reverse-engineered)

Source: `com.aracer.skycal` v3.7.2 (APKPure XAPK), analysed with REA 6.7.0 + jadx 0.7.1.
Static analysis only. Nothing below was observed on live hardware. Verify with a packet
capture before relying on a detail.

Evidence IDs (REA): service class `ev_028ffc05…`/`ev_17bb3adb…`/`ev_9c30369a…`/`ev_ec741820…`,
package `ev_6a362d6d…`. Decompiled source: see `jadx` output (obfuscated names kept below so
you can find them again).

## 1. Transport

| Item | Value | Where |
|---|---|---|
| Link | Phone joins the ECU Wi-Fi module's access point (WPA2) | `aRacerWiFiCANService.e()` uses `WifiNetworkSpecifier` |
| Bridge address | `192.168.88.88` | `A1/f.java` case 0 |
| Port | TCP `6666` | same, and `B1/r.java` |
| Socket options | TCP_NODELAY, 300 s read timeout, 8 KiB recv / 5 KiB send buffers | `aRacerWiFiCANService.c()` |
| Connect timeout | ~11 s | same |
| Alternate transport | USB serial (CDC-ACM, "aRacer Pro-Link") carrying the *same* framing | `z1/e.java` |

The Wi-Fi box is a transparent TCP ↔ CAN bridge. Everything above the socket is a CAN
frame wrapped in a 19-byte envelope.

## 2. Envelope (both directions)

```
offset  size  meaning
0       1     0xF8   sync
1       1     0x01   sync
2       1     0xC0   sync
3       1     LEN    payload length that follows (app always sends 14)
4       4     CAN ID, big-endian (11-bit or 29-bit)
8       1     flags: bit0 = extended ID, bit1 = RTR
9       1     DLC (0..8)
10      8     data, zero padded
18      1     CHK = (256 - sum(bytes[2..17])) & 0xFF
```

Receiver rule (`aRacerWiFiCANService.b()`): resync on `F8 01 C0`, read LEN at offset 3,
checksum is at offset LEN+4 and covers offsets 2 .. LEN+3. Sum of offsets 2..LEN+4 must be
0 mod 256. Frames failing the check are dropped silently.

Encoder: `x/AbstractC0521c.a()`. Decoder: `B0/a.java d(byte[])`.

## 3. CAN layer: it is CANopen

The ECU is a CANopen slave. The app is a CANopen master with vendor extensions.

| CAN ID | Direction | Purpose |
|---|---|---|
| `0x600 + node` | app → ECU | SDO request (read/write object dictionary) |
| `0x580 + node` | ECU → app | SDO response (app checks `id >> 7 == 11`) |
| `0x180 + node` | ECU → app | TPDO1: live-data stream, multi-frame |
| `0x700 + node` | ECU → app | heartbeat; app resets a 6 s watchdog on each one |
| `0x680` | app → ECU | vendor commands (opcode in byte 0) |
| `0x681` | app → bridge | identification request `[0x00]`. If the ECU *sends* `0x681` with DLC 1, the app disconnects |
| `0x682` | app → bridge | identification acks `[0xD1]`, `[0xC1]`, `[0xB1]` |
| `0x6A0` | ECU → app | vendor replies (opcode = request opcode + 1) |
| `0x6A1`, `0x6A2` | bridge → app | identification replies |
| `0x6A9` | ECU → app | consumed by a callback (`nVar.f778b0`), purpose not traced |
| `0x70A` | app → ECU | `[0x05]` seen once in `A/g.java`, purpose not traced |

Node ID (`k1/b.f11219k`) is derived from the ECU serial number's first byte, see §4.

## 4. Connection sequence (as the app does it)

1. TCP connect to 192.168.88.88:6666.
2. Send `0x681 [00]` (session `l1/e.java` case 0).
3. Bridge answers on `0x6A1 [ver, x]`. `ver` is stored as bridge version (7 = current). App sends `0x682 [D1]`.
4. Bridge streams on `0x6A2`, first byte is an opcode:
   - `D2` name bytes 0..6, `D3` name bytes 7..13, `D4` name byte 14 → 15-char device name. App sends `0x682 [C1]`.
   - `C2` + 4 bytes big-endian product code. App sends `0x682 [B1]`.
   - `B2` serial bytes 0..6, `B3` serial byte 7 → 8-byte ECU serial.
   - If serial[0] ∈ {B3, B6} and ver == 7: app sends `0x680 [9A]`, ECU replies `0x6A0 [9B, hi, lo]` (16-bit code shown as `%04X`).
5. ECU model and node ID from serial[0] (`E1/n.java k()` tail):

   | serial[0] | model string | node ID |
   |---|---|---|
   | `A6` | RC MiniX | 1 |
   | `A3` | RC SuperX | 2 |
   | `A4` | RC SuperX Pro | 4 |
   | `A5` | RC SuperX Pro | 5 |
   | `B6` | (newer family) | 33 |
   | `B3` | (newer family) | 34 |
   | `B5` | (newer family) | 37 |

6. If bridge ver == 7: unlock with the calibration key:
   `0x680 [88, 00, K2, K1, K0]` where K is the 24-bit *decimal* key the user set
   (default `888888` = `0x0D8EB8`). Reply `0x6A0 [89, status]`, 0 = accepted.
   Changing the key uses opcode `0x88` with sub-byte `01`.
7. Identity reads over SDO at index `0x1018` (see §6), device name at `0x1008` (10 bytes),
   then the per-model table definitions are loaded from the encrypted asset files and the
   maps are read with SDO block upload.
8. Heartbeat watchdog: if no `0x700+node` for 6 s, app drops the link.

## 5. SDO encoding (standard CANopen, verified against the decompiled builder `m1/a.java`)

Request on `0x600+node`, DLC 8. Index little-endian at bytes 1..2, sub-index at byte 3.

**Expedited read (≤ 4 bytes)**: `[0x40, idx_lo, idx_hi, sub, 0,0,0,0]`.
Reply byte 0 has `e=1,s=1`, `n=(b0>>2)&3` unused bytes, data little-endian at bytes 4..7.

**Expedited write (≤ 4 bytes)**: `[0x23 | ((4-len)<<2), idx_lo, idx_hi, sub, d0,d1,d2,d3]`.
Reply byte 0 `>> 5 == 3` (0x60) means accepted.

**Block upload (read > 4 bytes)** — `l1/c.java` default case, states 176→177→178:
1. `[0xA4, idx_lo, idx_hi, sub, 0x7F, 0x00, 0, 0]` (ccs=5, CRC bit, blksize 127)
2. Reply: if byte0 bit1 set, bytes 4..7 LE = total size, must match expected.
3. Send `[0xA3]` (start).
4. ECU sends segments `[seq | 0x80 if last, 7 data bytes]`.
5. After the last, send `[0xA2, seq_count, 0x7F]`.
6. Reply byte0: `n=(b0>>2)&7` trailing bytes to discard, `(b0&3)==1` → send `[0xA1]` (end).

**Block download (write > 4 bytes)** — `l1/d.java` case 0, states 208→209→210:
1. `[0xC6, idx_lo, idx_hi, sub, size LE 4 bytes]`
2. Reply byte 4 = block size; must be ≥ segment count.
3. Send every segment raw: `[seq, 7 bytes]` (seq starts at 1, no last-bit here).
4. Reply `(b0&3)==2` and byte1 == segment count.
5. Send `[0xC1 | ((7 - size%7) % 7) << 2]` (end). Reply `(b0&3)==1` → done.

Timeouts: 4.5 s per step, 2 s for block download steps. The app retries nothing; a timeout
fails the task (status 226).

## 6. Object dictionary entries seen in code

| Index (dec/hex) | Sub | Size | Name in app |
|---|---|---|---|
| 4104 / `0x1008` | 0 | 10 | DeviceName |
| 4120 / `0x1018` | 2 | 4 | Product_Code |
| | 5 | 4 | Table_ID (byte 1 selects definition set; 60/61/62 special) |
| | 6 / 7 / 8 / 9 | 2 each | firmware V / S / C / A, shown as `V.S.C.A` |
| | 10 | 8 | ECU_SN |
| | 11 | 4 | ECU_Fun (licensed feature bits) |
| | 12 | 4 | ECU_Trial_Fun |
| | 13 | 4 | ECU_Factory_Fun |
| | 14 | 4 | ECU_Order_SN |
| | 15 / 17 / 18 | 4 | AllTrial_Status / Timer / TimeMax |
| | 16 | — | written to clear something (toast "ClearComplete" path) |
| | 19..22 | 4 | Act_TimeStamp, ECU_Flag, OfflineAct_RunTime, Subscription_RunTime |
| 6144 / `0x1800` | 5 | 2 | TPDO1 event timer: write `64` to start live stream, `0` to pause |
| 8201 / `0x2009` | — | — | "clear" command |
| 8202 / `0x200A` | 2, 3 | 4 | feature/status flag words |
| 8203 / `0x200B` | 7, 8 | 4 | status words |
| `0xE000`-masked | — | — | special region, uses vendor read `0x680 [0x62, idx&15, sub]` |

Map tables (fuel, ignition, etc.) live at indices defined in the encrypted
`assets/ECUFile/ControlFile_*.dat`. Those were not decrypted. The entries can instead be
enumerated from a real ECU by walking SDO indices, or by capturing the app's traffic.

## 7. Live-data stream (`0x180+node`)

Enable: SDO write `0x1800:5 = 64`. Frames: byte 0 = sequence (1 = first) with bit 7 = last;
bytes 1..7 are data. Concatenate until the last frame, then parse as a packed record of
u8/u16/u32 little-endian values in the order of the "monitor" variable list (list 26 in the
definition file). Units are converted client-side (kPa→psi, km/h→mph, °C→°F).

## 8. Vendor opcodes on `0x680` (reply on `0x6A0` = opcode + 1)

| Opcode | Meaning (from context) |
|---|---|
| `0x88 00 k k k` | calibration-key unlock; `0x88 01` = change key |
| `0x9A` | query 16-bit code, reply `0x9B hi lo` |
| `0x62 idx sub` | read from the 0xE000 region |
| `0x30 …`, `0x38`, `0x3C`, `0x40 …`, `0x42`, `0x44`, `0x46`, `0x80`, `0x70` | firmware / "SOF" flash sequence (`l1/j.java`) — do not send |
| `0x32`, `0x34`, `0x36`, `0x3A`, `0x3E` | map block transfers used by QuickBurn |
| `0x94`, `0x9C` | key/activation sequences (`l1/d.java` case 1 expects `0x95`/`0x9D`) |
| `0xAE`, `0xBE`, `0xFA`, `0xFC` | single-byte commands, purpose not traced |

## 9. What this means for building your own app

- Transport + framing + CANopen SDO/PDO are enough to read identity, read and write
  any object-dictionary entry, and receive live data. A stdlib Python client is in
  `aracer_client.py`.
- The gap is the **table map**: which index/sub-index holds which calibration table, with
  axis scaling. That is in the AES-encrypted definition files and in the ECU's own object
  dictionary. Getting it legitimately means reading it from an ECU you own, or asking
  aRacer for the dictionary.
- Feature licensing (`ECU_Fun`, trial timers, activation) is enforced by the ECU, not the
  app. Your app should respect those flags rather than try to work around them.
- Firmware flashing opcodes are listed only so you know to avoid them.


## Verified on hardware (2026-10-21, RC MiniX, bridge "36-Y480-12SCAX0", fw 01.135.17.01)

Raw log: `dumps/20261021-214319/frames.log`.

- Bridge identify, calkey unlock (`0x680 [88 00 0d 90 38]` → `0x6A0 [89 00]`), expedited SDO reads
  and heartbeat (`0x701 [7F]` once per second, state pre-operational) behave exactly as documented above.
- **Every SDO request must be DLC 8.** The app zero-pads (`m1/a.java` always allocates `byte[8]`).
  A block sub-command sent as DLC 1–3 (`[A3]`, `[A2 n 7F]`, `[A1]`) is answered with
  `80 00 00 00 00 00 00 08` (abort 0x08000000, index 0) and the transfer is dropped.
- Plain `0x40` read of an object larger than 4 bytes answers `41 idx sub size32` (segmented offer).
  Sending abort `0x80` then starting a block upload (`A4`) works; the ECU stays silent on the abort.
- Abort codes seen: `06020000` object does not exist, `06090011` sub-index does not exist,
  `08000021` "local control" (object exists but sub 0 is not readable, e.g. 0x3000:0, 0x3002:0).
- Responses carry index/sub in bytes 1–3; a client must match on them, or one stray abort shifts
  every later answer by one (this is what corrupted the first dump).
- Licence word 0x1018:0B on this ECU = `0x000BFFFF` → bits 0–17 and 19 owned (all MiniX features).
  0x1018:0C (trial) = 0, 0x1018:0D = 0x410C, 0x1018:0E = 0xBBFF3, subs 0x13–0x16 do not exist.

- Block upload confirmed end to end (0x1018:0A → `01 a6 05 17 0f 00 6f 69`, `82 59 …`). The **end response
  carries no index/sub**: `D9 00 00 00 00 00 00 00` (scs 6, n=6 padding bytes, ss=1). Match it by command
  specifier, not by index. The client must then send `A1` (DLC 8); until it does, the ECU answers every
  further SDO read with abort `08000021` ("busy"), which is what the first "local control" aborts were.
- **Live stream needs a TPDO mapping first** (`E1/n.java` ~l.940, before `start_log_run`): write
  `0x1800:5 = 0`, then `0x1A00:n = (index << 16) | (bytes*8)` (u32) for each monitored object
  (index = var id + 0x4000 or table id + 0x3000, sub-index 0), then `0x1A00:0 = count` (u8),
  then `0x1800:5 = 64`. With an empty mapping the ECU acks the start but sends no `0x181` frames
  (second dump, 2026-10-21 21:52).
- Other session kinds in `A/g.java`: 9 = NMT start `0x000 [01 00]`, 10 = `0x70A [05]`; not needed
  for identify/read/stream on this ECU (pre-operational state still answers SDO and streams TPDO1).
- **Pipelining works.** The ECU processes SDO requests in order and answers several outstanding
  expedited reads correctly (seen in run 1: two `0x40` requests back to back, two matching replies).
  Median round trip over the bridge is 8 ms, segments of a block arrive in one burst (0 ms apart),
  so wall time is request-count × RTT. `ecu_dump.py` keeps 16 reads in flight (`--window`);
  a read that lands while a segmented offer is still open gets abort `08000021` and is simply retried.
  Only one block transfer can be open at a time (single SDO channel), so blocks stay sequential.
- **NMT start is required for the stream.** `A/g.java` case 9 (session kind 10, `p117q.r.j` = kind−1) sends
  `CAN id 0x000, [01 00]` (start all nodes) the moment the link is up (`E1/d.java` case 7), before the
  stream pause and identity reads. The ECU heartbeat then changes 7F → 05 (operational); TPDO1 frames on
  `0x181` are only sent in operational. Session kind 11 = `0x70A [05]` is a fake node-10 "operational"
  heartbeat sent only while retrying the link. Third dump (22:43): mapping + `0x1800:5=64` acked but no
  `0x181` frames while still pre-operational.
- Third dump also confirmed pipelining on the real ECU: 1494 tables (491 of them block uploads, 11.4 kB)
  + 1665 variables in ~100 s, 0 failures, 32 stale frames. Device name 0x1008 = "aRacer M32".
- **Stream verified (22:48, `dumps/20261021-224811`).** After NMT start the heartbeat reads 05 and
  `0x181` frames arrive ~16 Hz. One sample = the mapped objects concatenated in mapping order, split into
  7-byte chunks with byte 0 = seq (01, 02, …; bit 7 set on the last chunk). **Multi-byte values in the
  stream are big-endian** (`A4/a.java` parses the sample with `ByteBuffer.allocate(512)`, Java default
  order, `getChar()`/`getInt()`), whereas SDO payloads are little-endian. Example with 8 objects mapped
  (1,1,1,1,2,2,2,2 bytes): `01 20 11 48 5f 02 00 04` + `82 14 00 28 00 0c` → 0x4001=32, 0x4006=17,
  0x4009=72, 0x4014=95, 0x4016=2, 0x4019=0x0414=1044, 0x401B=40, 0x4020=12; the SDO read of 0x4019 gave
  bytes `14 04` (LE) = 1044, so both paths agree. Max sample size 512 bytes. The app also resets its 6 s
  heartbeat watchdog on every stream frame.

## Definition files (NOT decrypted - deliberate)

The per-model object dictionary (name↔id, scaling, rows/cols) is in `assets/ECUFile/ControlFile_*.dat`
and `Default_*_Template.dat`. Format: UTF-8-BOM Base64 of AES-256-CBC/PKCS5 ciphertext; key = PBKDF2
(HMAC-SHA1, 1000 iters, 256-bit) over a password+salt fetched from the app's native `native-lib.so`
(`getMxKey1`/`getMxKey2`), applied in `com.bumptech.glide.f.f()`. These protect aRacer's proprietary
data; we do not extract the native key or decrypt them.

Variable names are recovered only from cleartext instead:
- `assets/ECUFile/ScaleData.xml` (plaintext): axis names RPM, Eng_AP, dTPS, T_Eng, Volt, TPS_Pct, Gear,
  VSS, T_Air, Angle, APS_Pct, ...
- hard-coded gauge bindings `dVar.p(id)` and behaviour in the app: id 26 = RPM (main gauge),
  51 = vehicle speed (toggles with GPS speed -9002), 33 = overheat flag (icon_overheater),
  55 = AF2 sensor status; variable CANopen index = id + 0x4000.
- SharedPreferences channel defaults: RPM, TPS_Percent, AFR_WBO2, Cyl1_Eng_AP.
- the reliable per-ECU method: watch the live stream while blipping the throttle and see which index tracks.

## Table scaling (domain-anchored, not from the encrypted file)

Cell→value conversions derived from the owner's tuning knowledge + the real dump, confirmable by re-dump diff:
| Table | id | cell | value | range seen | note |
|---|---|---|---|---|---|
| Target AFR | 54 (0x3036) | 1 B | raw ÷ 10 | 12.0–13.3 AFR | owner: AFR 10 rich … 14 lean, floats ~12.8 ✓ |
| Spark 3D | 133 (0x3085) | 2 B LE | raw ÷ 10 | 8.0–16.0° | ignition advance ✓ |
| Fuel adjust 3D | 4 (0x3004) | 2 B LE | raw × 100/128 | 75–140 % | 0x80=128 → 100 % neutral; 25×56, axis match TBD |
| RPM limit | 8 (0x3008) | 2 B LE | raw | 12000 | ✓ |
| Accel fuel / Temp comp | 21 / 41 | 1 B | raw × 100/128 | — | %, 128=100 % |
Axes are TPS (rows) × RPM (cols) for the 3D tables (owner-confirmed); exact breakpoints still to be matched to ScaleData.xml by re-dump diff.
