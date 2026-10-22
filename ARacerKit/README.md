# ARacerKit

Swift package that speaks the aRacer Wi-Fi bridge / ECU protocol documented in `../PROTOCOL.md`.
Pure Swift, no dependencies. Targets macOS 13+ and iOS 16+.

| Type | Role |
|---|---|
| `CANFrame`, `FrameDecoder` | 19-byte bridge envelope, resynchronising parser |
| `Transport`, `NWTransport`, `ScriptedTransport` | Network.framework TCP (pinned to Wi-Fi), in-memory replay for tests |
| `ECUClient` (actor) | identify, unlock, NMT start, SDO read/write/block upload, pipelined probes, stream start/stop, `events` |
| `StreamDecoder`, `StreamSlot` | TPDO1 mapping words and sample reassembly (big-endian values) |
| `ECUIdentity`, `Licence`, `ECUModel` | 0x1018 fields, licence bit names, serial→model/node |
| `ECUSession` (@MainActor) | connect / auto-reconnect / stream state for SwiftUI, shared by macOS dashboard and iOS app |
| `ARacerDash` (executable) | macOS SwiftUI app: **Live** tab (identity, licence, live gauges) + **Tabel** tab (real tuning tables from the dump as heat-map grids); `--demo` runs without the bike |
| `table_catalog.json` | 18 tuning tables (Fuel/Spark/AFR/Idle/…) joined from the feature→id map, the ECU dump shapes, and ScaleData.xml; RAW values, scaling pending calibration |

Hard-won rules baked in (all verified on an RC MiniX, 2026-10-21):
every SDO request is padded to DLC 8; replies are matched by index/sub; the block-end reply has
no index; `A1` is always sent so the ECU is never left busy; NMT start precedes the stream;
the 0x1A00 mapping is written before `0x1800:5 = 64`.

Writes: `write()` is only used for the two things the official app writes on every connect
(stream on/off, TPDO mapping). Any calibration write must be an explicit, user-confirmed action
in the app layer. Firmware-flash opcodes are not implemented on purpose.

## Build & test (Command Line Tools are enough, Xcode not required)

```
swift build
./run_tests.sh            # Swift Testing via the CLT frameworks
swift run aracer-cli identify   # Mac joined to the ECU Wi-Fi
swift run aracer-cli quick      # + 10 s of live data from 8 variables
swift run ARacerDash --demo     # dashboard window with simulated data
swift run ARacerDash            # dashboard against the real ECU
```

Tests replay real frames from `../dumps/`. The iOS app (next stage) needs Xcode.
