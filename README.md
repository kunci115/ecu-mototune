# MotoTune — open ECU tuning for aRacer, built with an AI copilot

A personal iPhone app (plus a Swift library, a macOS dashboard, a CLI and a Python PoC) that talks
**directly** to an aRacer RC MiniX ECU over its Wi-Fi bridge — no official app in the loop — and
tunes the **Fuel Adjust** table the way an experienced human tuner does: change a few cells, measure
the bike's acceleration, keep what is faster, revert what is not. AFR is only a safety guard.
A Claude-powered copilot proposes the next pass from everything the app measured.

> **Ringkasan (ID):** app iPhone pribadi untuk ECU aRacer RC MiniX. Koneksi langsung ke bridge
> Wi-Fi, logging di latar belakang, editor Fuel Adjust dengan draft, deteksi pull full-throttle
> sebagai "dyno jalan", dan copilot Claude yang mengusulkan perubahan bertahap. Status lengkap
> (apa yang sudah terbukti di hardware, apa yang belum) ada di [`docs/STATUS.md`](docs/STATUS.md).

| Live | Tuner | Tables |
|---|---|---|
| ![Live](docs/screenshots/live.png) | ![Tuner](docs/screenshots/tuner.png) | ![Tables](docs/screenshots/tables.png) |

---

## Read this first

- **Unofficial.** Not affiliated with, endorsed by, or supported by aRacer. Everything here comes
  from reverse-engineering the Android app's cleartext behaviour and from observing a real ECU.
- **No vendor files.** The encrypted definition files (`ControlFile_*.dat`), the APK and the
  decompiled sources are deliberately **not** in this repo and never will be. All table geometry,
  scaling and variable identities were recovered from the ECU's own object dictionary, live
  observation and domain knowledge — see [`PROTOCOL.md`](PROTOCOL.md).
- **Writing to an ECU can damage an engine.** The write path does backup → write → read-back →
  verify, and never writes without a confirmation tap. It has *not yet been exercised on hardware*
  at the time of writing (see STATUS). You are responsible for your bike.
- **Never send firmware-flash opcodes** (`0x40/0x42/0x44/0x46/0x80/0x70` on CAN id `0x680`).
  The client refuses to; keep it that way.

---

## What is in the box

```
ARacerKit/                 Swift package (macOS 14 / iOS 17)
  Sources/ARacerKit/       the library: protocol, session, engines, SwiftUI views, theme
    Frame.swift            19-byte bridge envelope ↔ CAN frame
    SDO.swift              CANopen SDO expedited / block upload / block download
    StreamDecoder.swift    TPDO stream (big-endian values, 7-byte chunks)
    ECUClient.swift        actor: pipelined requests, probeMany, readBlock, writeBlock, startStream
    ECUSession.swift       @Observable state machine: connect/reconnect, live map read, guarded write,
                           background logging, persistence hooks
    KnownVariables.swift   live variable ids we proved (and candidates), with scale + confidence
    TableAxes.swift        17 TPS × 20 RPM axes of the grid tables
    TableScaling.swift     raw bytes → engineering values, with confidence + how we know
    FuelMap.swift          Fuel Adjust base + DRAFT overlay, raw-row patching for the ECU
    TunerEngine.swift      per-cell AFR statistics (steady-state gate, lag, outliers, std)
    DynoEngine.swift       full-throttle pull detection, dRPM/dt torque proxy, noise-aware comparison
    Copilot.swift          Claude API copilot: payload, schema, hard safety filter, draft staging
    TuningDB.swift         SwiftData models: sessions, map revisions, AI suggestions + verdicts, pulls
    Support/ClaudeClient   raw-HTTP Messages API client (structured JSON output)
    Support/KeychainStore  API key storage
    Views/                 one type per file (Dashboard, Tuner, Dyno, Tables, FuelEditor, Settings…)
  Sources/aracer-cli/      identify | quick | replay <log.bin> <log.json>
  Sources/ARacerDash/      macOS dashboard (same views), --demo and --snapshot for screenshots
  Tests/                   Swift Testing: protocol, session, engines, fuel map, copilot filter (25)
iOSApp/                    xcodegen spec + entry point + fonts + icon (project.yml → xcodegen)
aracer_client.py           stdlib-only Python client (the first thing that talked to the ECU)
ecu_dump.py                pipelined read-only dump of the whole object dictionary (~100 s)
PROTOCOL.md                the wire protocol, verified on hardware
ARCHITECTURE.md            (ID) how the official app is put together, from its cleartext
docs/STATUS.md             (ID) done / built-but-untested / not built / risks / next steps
field-data/                sample ride logs + identify snapshots from the real bike
```

## How it works (one screen)

```
 iPhone ──Wi-Fi (192.168.88.88:6666, TCP)──▶ aRacer bridge ──CAN──▶ ECU (CANopen node 1)
   │
   ├─ ECUClient (actor)      SDO reads/writes  ·  TPDO stream @ ~16 Hz  ·  NMT, heartbeat
   ├─ ECUSession             connect → identity → read Fuel Adjust live → start stream → pump
   │     ├─ TunerEngine      AFR vs target per TPS×RPM cell (statistics, guard only)
   │     ├─ DynoEngine       detects pulls → dRPM/dt per 500-rpm bin → compares map revisions
   │     ├─ FuelMap          base (from ECU) + draft (manual edits + AI proposals)
   │     └─ Copilot          Claude ← {map, draft, AFR cells, pull curves, history, notes} → cell deltas
   └─ SwiftUI tabs           Live · Tuner (Change → Measure → Decide) · Dyno · Tables
```

The tuning loop the app enforces: **1 · Change** (stage cells in the draft — by hand or by AI,
≤ 3 % per cell per pass) → **2 · Measure** (3–5 full-throttle pulls in one gear; revisions are
averaged and only a difference beyond pull-to-pull noise counts) → **3 · Decide** (Apply to ECU
with backup + verify, or Revert). Every suggestion gets the measured verdict written back so the
copilot learns from its own history.

---

## Getting started

Requirements: macOS 14+, Xcode 26/27 (Swift 6), `xcodegen` (`brew install xcodegen`), an iPhone on
iOS 17+, Python 3.10+ for the PoC scripts, Pillow only if you regenerate the icon.

```bash
# library, CLI, macOS dashboard, tests
cd ARacerKit
swift build
swift test                                   # 25 tests, no hardware needed
swift run ARacerDash --demo                  # dashboard with synthetic data
swift run ARacerDash --demo --tab tables --table 4

# iPhone
cd ../iOSApp
xcodegen generate                            # project.yml → ARacerXTune.xcodeproj
# edit project.yml: DEVELOPMENT_TEAM / bundle id to yours (free Personal Team works, 7-day signing)
xcodebuild -project ARacerXTune.xcodeproj -scheme ARacerXTune \
  -destination 'id=<your iPhone UDID>' -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/ARacerXTune.app
```

On the phone: join the bridge's Wi-Fi (no internet on it — iOS keeps cellular for the Claude
call), open MotoTune, allow Local Network. Tuner → ⚙ → paste a Claude API key (stored in the
Keychain, sent only to `api.anthropic.com`) → Test.

Python, from a Mac joined to the bridge Wi-Fi:

```bash
python3 ecu_dump.py                 # read-only dump → dumps/<timestamp>/
```

Replay a phone log through the exact engines the app runs (offline analysis = app code):

```bash
cd ARacerKit && swift run aracer-cli replay ../field-data/motolog-20261022-203505.bin ../field-data/motolog-20261022-203505.json
```

---

## Extending it

### Add a live variable
1. Find its id without the vendor file: Live tab → wand → **Identify** takes two SDO snapshots of
   every variable (`0x4001…0x4600`) — idle vs throttle held — and ranks movers. Or profile a ride
   log statistically (range, std, correlation with RPM / T_Eng); that is how Gear, BPW and battery
   voltage were found (see `docs/STATUS.md`).
2. Add it to `KnownVariables.all` with `scale`, `decimals`, `confidence` (`.candidate` until
   proven) and `inDefaultStream` (keep the default stream ≤ ~2 TPDO frames).
3. Engines read by index (`0x4000 + id`): `DynoEngine.ingest` / `TunerEngine.ingest`.

### Add or calibrate a table
- Tables live in `table_catalog.json` (id, index `0x3000 + id`, shape, raw hex rows).
- Scaling goes in `TableScaling.byID` **with a note saying how you know** and a confidence.
- Axes in `TableAxes.byID`. Every grid on this ECU is 17 TPS rows × 20 RPM columns; the ECU pads
  rows/columns beyond that — `FuelMap.patchedRow` writes the padding back byte-identical.
- Editing another grid table (e.g. Spark) = a `FuelMap`-like model with its own scaling + an
  editor view; keep the draft → Apply (backup/verify) flow.

### Add a feature
- Put logic in an `@Observable @MainActor` engine fed from `ECUSession.pump` (see
  `DynoEngine`), persist with a SwiftData `@Model` in `TuningDB`, surface it in a view under
  `Views/` (one type per file, `Theme` tokens, `card()` / `eyebrow()`).
- Per-sample work must be O(1) with no allocation (ring buffers, fixed grids); derive expensive
  things in `didSet` of the state that changes, not in view bodies.
- Anything that writes to the ECU goes through `ECUSession.writeFuelDraft`-style code: fresh
  backup, change check, write, read-back, verify, then a new revision label.

### Port to another ECU
The stack separates cleanly:

| Layer | aRacer-specific? | Where |
|---|---|---|
| Transport (TCP to a Wi-Fi bridge) | yes, but tiny | `Transport.swift` (`Transport` protocol; `NWTransport`, `ScriptedTransport`) |
| Envelope (19-byte frame with checksum) | yes | `Frame.swift` |
| CANopen SDO / PDO / NMT | **no** — standard CiA 301 | `SDO.swift`, `StreamDecoder.swift`, `ECUClient.swift` |
| Object dictionary (which index is which table/variable) | yes | `KnownVariables`, `TableAxes`, `TableScaling`, `table_catalog.json` |
| Engines, DB, copilot, UI | **no** | everything else |

So for another CANopen-based ECU you replace the envelope and the dictionary and keep the rest.
For a non-CANopen ECU you implement `Transport` + a client with the same surface (`read`, `readBlock`,
`writeBlock`, `startStream`) and the engines don't care. Start by capturing traffic from the vendor
app (a PCAP or a Wi-Fi bridge log), reproduce the handshake in Python (`aracer_client.py` is a
200-line template), dump the dictionary read-only, then identify channels with the snapshot-diff
trick. Confirm every scaling against the vendor UI before trusting it.

### The copilot
`Copilot.swift` holds the system prompt, the JSON schema (`rationale`, `changes[{tps,rpm,delta_pct,reason}]`,
`cautions`) and the **hard filter** that runs on the model's answer regardless of what it says:
no fuel cut in a cell already lean (> 13.6 at ≥ 10 % TPS), no cells outside the RPM range any
pull measured, unknown cells dropped, ≤ `maxStep` per cell. Model and effort are in
`ClaudeClient` (`claude-haiku-5-5` by the owner's choice; any Claude model works).

---

## How this was built (the Claude Code workflow)

The whole project — protocol RE, Python PoC, Swift package, iOS app, design system, icon, docs —
was built in a few days in [Claude Code](https://claude.com/claude-code) with a human doing the
hardware runs and the judgement calls. If you want to reproduce the process rather than just the
code:

**Models.** Claude in Claude Code (Claude Fable 5.1 for the later sessions, the then-current
Claude models before that). The in-app copilot calls `claude-haiku-5-5` (the owner's cost choice)
through the Messages API with structured output.

**Skills / tools used inside Claude Code**
- `reverse-engineer-anything` (REA MCP server + JADX): decompiling the Android app to its
  cleartext — gauge bindings, the block-download state machine, the SharedPreferences channel
  defaults, `ScaleData.xml` names. Only cleartext was used; the AES definition files were left alone.
- `swiftui-pro`: review passes for modern SwiftUI (`@Observable`, one type per file, Dynamic Type,
  VoiceOver labels, `Text(_, format:)`, iOS/macOS conditionals).
- `ui-ux-pro-max`: the dark telemetry design system (palette tokens, Space Grotesk, card/eyebrow
  modifiers, heat scale), then applied per screen.
- `claude-api`: the Messages API shape (headers, `output_config.format` JSON schema, refusal /
  `max_tokens` handling, server-side fallbacks) for `ClaudeClient.swift`.
- Plain Python (stdlib) for the bridge PoC and statistics; Pillow for the programmatic app icon
  (`iOSApp/make_icon.py`); `xcodegen` + `xcodebuild` + `devicectl` for sideloading.

**Working rules that mattered**
- Hardware in the loop, early: every protocol claim was checked against the real ECU the same day.
  Several "facts" from the decompiled code were wrong until tested (SDO frames must be DLC 8, the
  block-end reply carries no index, the stream is big-endian, NMT start is required).
- When the log analysis said "82 % corrupt", the bug was in the analysis (endianness), not the
  bridge. Decode with the app's own code (`aracer-cli replay`) so offline analysis == shipped code.
- Tests without hardware: `ScriptedTransport` replays recorded exchanges; engines are tested with
  synthetic rides; the catalog JSON is a test fixture.
- Don't trust a scrolled screenshot: the "11 × 18" table geometry survived a day until the raw
  dump was re-read row by row (it is 17 × 20).
- The owner rejected AFR-target auto-learn ("drifts"); the Tuner tab was rebuilt around measured
  acceleration. Statistics (steady-state gating, lag alignment, outlier rejection, revision
  averaging with a noise threshold) exist because a wideband sensor "moves all the time".
- Memory across sessions: a project memory file (what was verified, what was a decode bug, what
  the owner decided) kept later sessions from re-deriving or re-breaking earlier work.

**Stack**
Swift 6 · SwiftPM · SwiftUI · `@Observable` · SwiftData · Network.framework (`NWConnection`) ·
AVAudioSession (background keep-alive) · Swift Testing · xcodegen · Keychain Services ·
Claude Messages API (raw `URLSession`, no SDK) · Python 3 stdlib · Pillow.

---

## The shipped calibration is one specific bike

`table_catalog.json` is the real map of a **Yamaha WR155R bore-up** — 76 mm piston on a 61.7 mm
crank (≈ 280 cc), 28/25 mm valves, 45 mm throttle body tuned with the air filter on, aRacer
RC MiniX — tuned by a human tuner. It is **not** a stock WR155 map and must not be written into
another engine. Details and the contribution format for your own bike or ECU:
[`catalogs/README.md`](catalogs/README.md).

## Status, contributing, licence

- Honest status, including what is **not** proven: [`docs/STATUS.md`](docs/STATUS.md).
- Issues and PRs welcome — especially calibrations and ride data from other bikes on aRacer,
  confirmed variable ids, and ports to other ECUs. Keep vendor files out of PRs. Add a note of
  *how you know* to every scaling/axis you add.
- Licence: [MIT](LICENSE).
