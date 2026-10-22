# Calibration catalogs — one folder per bike / ECU

The tables the app ships with (`ARacerKit/Sources/ARacerKit/table_catalog.json`) are **one real
bike's calibration**, not a vendor base map and not a stock bike. Contribute yours here so people
with the same engine, the same aRacer model, or a different ECU altogether have a reference.

## Reference bike (the shipped catalog)

| | |
|---|---|
| Bike | Yamaha **WR155R** — **bore-up**, not standard |
| Bore × stroke | **76 mm** piston, **61.7 mm** crankshaft stroke (≈ 280 cc) |
| Valves | intake **28 mm**, exhaust **25 mm** |
| Throttle body | **45 mm**, tuned with the air filter **on** (airbox fitted) |
| ECU | aRacer **RC MiniX**, bridge 36-Y480-12SCAX0, firmware 01.135.17.01, all MiniX licence bits |
| Maps | Fuel Adjust, Target AFR, Spark 3D tuned by a human tuner on the dyno; Accel fuel and Temp comp untouched (100 %) |
| Fuel | (fill in: octane / brand) |
| Exhaust | (fill in) |

Do **not** write these values into a standard WR155 or any other engine — a 139.8 % fuel cell
that is right for 280 cc with a 45 mm body is very wrong for a stock 155 cc.

## How to contribute a catalog

Create `catalogs/<ecu>-<bike>-<short-tag>/`, for example `catalogs/aracer-minix-wr155-76mm/`, with:

```
bike.md              the table above, filled in honestly (what is modified, what is stock, who tuned it, dyno or road)
table_catalog.json   same format as the shipped one (array of {id, index, name, kind, rows, rowlen, cell, cols, values_hex, …})
logs/                optional: motolog-*.bin + .json sidecars, identify-*.json (strip nothing — the app reads them back)
NOTES.md             optional: what the tuner changed and why, dyno sheets, known issues
```

To produce `table_catalog.json` from your own ECU, read-only:

```bash
python3 ecu_dump.py                     # from a Mac on the bridge Wi-Fi → dumps/<timestamp>/
```

then copy the catalog JSON the dump writes. Never include the vendor's `ControlFile_*.dat`, the APK,
or decompiled sources. Strip nothing else: the ECU serial in `bike.md` is up to you, the table
values are the point.

## Other ECUs

Same layout, different prefix (`catalogs/<ecu>-…`). If the ECU is CANopen-based the shipped
`SDO.swift` / `StreamDecoder.swift` likely work as-is and only the envelope + dictionary differ
(see README → *Port to another ECU*). Open an issue with a traffic capture and a dump and we'll
map it together.
