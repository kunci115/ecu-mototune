# Contributing

You don't need an aRacer, a bike, or an iPhone to help. Pick a rung.

## Rung 0 — no hardware

- Run `cd ARacerKit && swift test` and `swift run ARacerDash --demo`. If anything fails on your
  Mac/Xcode version, open an issue with the output.
- Read [`PROTOCOL.md`](PROTOCOL.md) and [`docs/STATUS.md`](docs/STATUS.md); fix what is unclear.
- Replay the sample logs (`swift run aracer-cli replay field-data/…`) and improve the analysis:
  better pull detection, better noise model, a chart, an export.
- Engines are pure Swift with synthetic-ride tests (`Tests/ARacerKitTests/EngineTests.swift`).
  Better statistics for `TunerEngine` / `DynoEngine` are welcome — add a test that would have
  failed before your change.
- Translate / polish the Indonesian docs (`ARCHITECTURE.md`, `docs/STATUS.md`) or the English ones.

## Rung 1 — you have an aRacer ECU

- **Confirm things marked `candidate` / `guess` / `low`** in `KnownVariables`, `TableScaling`,
  `TableAxes`. Each one lists what observation would confirm it (gear change while stationary,
  headlight on/off for battery, a reading from the official app for Idle/VVA, the AFR Target row
  labels). A one-line issue "id 130 is Gear, confirmed on <bike>" is a real contribution.
- **Contribute your calibration** under `catalogs/` — format in
  [`catalogs/README.md`](catalogs/README.md). State the engine build honestly.
- **Ride logs** with full-throttle pulls (we have none yet): tap *Record Log*, ride, pull the
  `motolog-*.bin` + `.json` off the phone (Files app or `devicectl … copy`), attach to an issue.
- Other aRacer models (RC Mini 5, RC Super, …): run `ecu_dump.py`, compare the object dictionary
  with ours, tell us what differs.

## Rung 2 — you can test the write path

Only if you accept the risk and have a backup of your map (the official app's `.amx` and our
`MapRevision` backup). Stage **one** cell +0.5 % → Apply to ECU → report the log lines → power-cycle
the ECU → reconnect → is the cell still changed? That single experiment decides whether a
"burn" step is needed. Then test with the official app that it reads the same value.

## Rung 3 — another platform

The core is small and already has two implementations of the protocol (Swift `ARacerKit`, Python
`aracer_client.py`). An **Android** port is the most wanted thing in this repo. Reasonable paths:
Kotlin port of `Frame`/`SDO`/`StreamDecoder`/`ECUClient` + Compose UI; Kotlin Multiplatform
sharing the engines; or a Rust core with thin native UIs. Open an issue titled "Android: <approach>"
before writing a lot of code so the protocol layer stays one source of truth (tests in
`Tests/ARacerKitTests` are the spec — port them first).

## Rung 4 — another ECU

See README → *Port to another ECU*. Open an issue first with: ECU model, how the vendor app talks
to it (Wi-Fi/BLE/USB), a traffic capture if you have one, and whether it looks like CANopen
(SDO ids `0x600+node` / `0x580+node`, heartbeat `0x700+node`). We'll map the layers together.

## Rules

- **No vendor files.** No APKs, no decompiled sources, no `ControlFile_*.dat`, no key material.
  PRs containing them are closed.
- **Say how you know.** Every scaling, axis, or variable id carries a `note`/`source` and a
  confidence. "It matches the official app's screen" is good; "I think" is a `candidate`.
- **Safety is code, not prompt.** Anything the AI proposes passes a hard filter; anything that
  writes to an ECU does backup → write → read-back → verify, behind a confirmation. Keep it so.
- **Per-sample paths are O(1).** The stream runs at ~16 Hz for hours on a phone. No allocation
  per sample, bounded collections, derive expensive things when state changes, not per render.
- One type per file under `Views/`, `Theme` tokens for colour/spacing, English UI strings.
- Tests: `swift test` must stay green; add one for behaviour you change.
- Commit messages: what changed and why. If you pair with an AI, say so in the trailer.

## Getting in touch

Issues on this repo. Indonesian or English, both fine.
