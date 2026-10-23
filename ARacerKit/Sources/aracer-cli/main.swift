import Foundation
import ARacerKit

// aracer-cli identify | quick [--key N] | replay <motolog.bin> <motolog.json>
// identify/quick: read-only check against the real bridge from a Mac joined to the ECU Wi-Fi.
// replay: run a phone log through the SAME DynoEngine/TunerEngine the app uses — offline analysis = app code.
let args = CommandLine.arguments.dropFirst()
let cmd = args.first ?? "identify"

if cmd == "fit" {
    // aracer-cli fit <activity.fit> — summarise a watch file: coverage, altitude, speed, HR.
    let a = Array(args)
    guard a.count >= 2 else { print("usage: aracer-cli fit <activity.fit>"); exit(2) }
    let r = try FITReader.records(url: URL(fileURLWithPath: a[1]))
    guard let f = r.first, let l = r.last else { print("no records"); exit(1) }
    let dur = l.time.timeIntervalSince(f.time)
    let gaps = zip(r, r.dropFirst()).map { $1.time.timeIntervalSince($0.time) }
    let alts = r.compactMap(\.altitude), spd = r.compactMap(\.speed), hr = r.compactMap(\.heartRate), pos = r.filter { $0.lat != nil }
    print("records: \(r.count)  \(f.time) → \(l.time)  (\(Int(dur)) s, median gap \(gaps.sorted()[gaps.count / 2]) s)")
    print("gps: \(pos.count) fixes  altitude: \(alts.count) samples" + (alts.isEmpty ? "" : String(format: " %.0f–%.0f m", alts.min()!, alts.max()!)))
    print("speed: " + (spd.isEmpty ? "–" : String(format: "max %.1f km/h, mean %.1f km/h", spd.max()! * 3.6, spd.reduce(0, +) / Double(spd.count) * 3.6))
          + "  distance: " + (l.distance.map { String(format: "%.2f km", $0 / 1000) } ?? "–")
          + "  hr: " + (hr.isEmpty ? "–" : "\(hr.min()!)–\(hr.max()!)"))
    if let p = pos.first { print(String(format: "start: %.5f, %.5f", p.lat!, p.lon!)) }
    for s in r.prefix(3) { print("  ", s.time, s.lat ?? 0, s.lon ?? 0, "alt", s.altitude ?? -1, "spd", s.speed ?? -1, "d", s.distance ?? -1, "hr", s.heartRate ?? -1) }
    exit(0)
}

if cmd == "replay" {
    let a = Array(args)
    guard a.count >= 3 else { print("usage: aracer-cli replay <motolog.bin> <motolog.json> [--fit activity.fit] [--offset seconds]"); exit(2) }
    let fitPath = a.firstIndex(of: "--fit").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
    let offset = a.firstIndex(of: "--offset").flatMap { a.indices.contains($0 + 1) ? Double(a[$0 + 1]) : nil } ?? 0
    let bin = try Data(contentsOf: URL(fileURLWithPath: a[1]))
    let side = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[2]))) as? [String: Any] ?? [:]
    let vars = side["vars"] as? [[String: Any]] ?? []
    let slots = vars.map { StreamSlot(index: UInt16($0["index"] as? Int ?? 0), size: $0["size"] as? Int ?? 1) }
    let payload = slots.reduce(0) { $0 + $1.size }
    let start = (side["startedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
    let dyno = await DynoEngine(), tuner = await TunerEngine()
    var pullSamples: [UUID: [DynoEngine.Sample]] = [:]
    await MainActor.run { dyno.onPullSamples = { pullSamples[$0.id] = $1 } }
    var off = 0, n = 0
    var speedTrack: [(t: Double, vss: Double)] = []        // for the GPS-vs-VSS scale check
    let vssSlot = slots.firstIndex { $0.index == 0x4033 }
    while off + 4 + payload <= bin.count {
        let ms = bin[off..<off+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let raw = [UInt8](bin[off+4..<off+4+payload]); off += 4 + payload; n += 1
        var values: [UInt32] = []; var p = 0
        for sl in slots { values.append(Array(raw[p..<p + sl.size]).uintBE); p += sl.size }
        let t = start.addingTimeInterval(Double(ms) / 1000)
        await tuner.ingest(values, slots: slots)
        await dyno.ingest(values, slots: slots, at: t)
        if let i = vssSlot { speedTrack.append((t.timeIntervalSince1970, Double(values[i]) / 256)) }
    }
    print("records:", n, "payload:", payload, "B  started:", start, " tpsMaxSeen:", await dyno.tpsMaxSeen)
    let pulls = await dyno.pulls
    print("pulls:", pulls.count)

    var fit: [FITReader.Sample] = []
    if let fitPath {
        fit = try FITReader.records(url: URL(fileURLWithPath: fitPath))
        let withAlt = fit.filter { $0.altitude != nil }.count, withPos = fit.filter { $0.lat != nil }.count
        print("fit: \(fit.count) records, \(withPos) with GPS, \(withAlt) with altitude, \(fit.first.map { "\($0.time)" } ?? "–") → \(fit.last.map { "\($0.time)" } ?? "–")")
        // GPS speed vs ECU VSS over the whole ride (nearest sample within 1 s, both moving)
        var ratios: [Double] = []; var j = 0
        for f in fit {
            guard let gps = f.speed, gps > 2 else { continue }
            let tf = f.time.timeIntervalSince1970 + offset
            while j + 1 < speedTrack.count && speedTrack[j + 1].t <= tf { j += 1 }
            guard j < speedTrack.count, abs(speedTrack[j].t - tf) <= 1, speedTrack[j].vss > 3 else { continue }
            ratios.append(gps * 3.6 / speedTrack[j].vss)
        }
        if ratios.count >= 10 {
            let sorted = ratios.sorted(); let med = sorted[sorted.count / 2]
            print(String(format: "speed check: GPS km/h ÷ (VSS raw/256) median %.3f over %d matched samples → %@", med, ratios.count,
                         abs(med - 1) < 0.08 ? "raw/256 CONFIRMED" : String(format: "scale should be raw/256 × %.3f", med)))
        } else { print("speed check: not enough overlapping moving samples (\(ratios.count)) — check --offset or that the watch recorded the same ride") }
    }
    let ctx = fit.isEmpty ? [] : RideFusion.annotate(pulls: pulls, rawSamples: pulls.map { pullSamples[$0.id] ?? [] }, fit: fit, offset: offset)
    for (i, p) in pulls.enumerated().reversed() {
        print(String(format: "  %@ %ds rpm %d→%d maxAFR %@ gear %@", "\(p.startedAt)", Int(p.duration), p.rpmStart, p.rpmEnd,
                     p.maxAFR.map { String(format: "%.1f", $0) } ?? "–", p.gear.map { "\($0)" } ?? "–"))
        print("    measured  " + p.curve.map { "\($0.rpm):\(Int($0.accel))" }.joined(separator: " "))
        if i < ctx.count {
            let c = ctx[i]
            print(String(format: "    grade %@  gps %@ km/h  vss %@ km/h  segment %@  (%d fit samples)",
                         c.grade.map { String(format: "%+.1f%%", $0) } ?? "–", c.gpsSpeedMean.map { String(format: "%.0f", $0) } ?? "–",
                         c.vssMean.map { String(format: "%.0f", $0) } ?? "–", c.segment ?? "–", c.samples))
            if c.grade != nil { print("    corrected " + c.corrected.map { "\($0.rpm):\(Int($0.accel))" }.joined(separator: " ")) }
        }
    }
    print("AFR samples:", await tuner.samplesLearned, "rejected transients:", await tuner.rejectedTransient)
    let cells = await tuner.cells, tps = await tuner.tps, rpm = await tuner.rpm
    print("cells with ≥5 samples (TPS/RPM: n mean±std%):")
    for (r, row) in cells.enumerated() { for (c, cell) in row.enumerated() where cell.count >= 5 {
        print(String(format: "  %2d/%5d: n=%3d AFR %.2f  vs target %+.1f%% ±%.1f", tps[r], rpm[c], cell.count, cell.meanAFR ?? 0, cell.correctionPct ?? 0, cell.stdPct ?? 0))
    } }
    exit(0)
}
let key = args.firstIndex(of: "--key").flatMap { UInt32(args[args.index(after: $0)]) } ?? 888_888

let t = NWTransport(wifiOnly: false)
do {
    try await t.connect()
    let ecu = ECUClient(transport: t)
    let (info, ident) = try await ecu.connectSequence(key: key)
    print("bridge:", info.name, "serial", info.serialHex, "model", info.model?.rawValue ?? "?", "node", info.node ?? 0)
    print("ecu:", ident.deviceName, "fw", ident.firmware, "owned:", Licence.names(ident.ownedFunctions, node: info.node).joined(separator: ","))
    if cmd == "quick" {
        let slots = [(0x4001, 1), (0x4006, 1), (0x4009, 1), (0x4014, 1), (0x4016, 2), (0x4019, 2), (0x401B, 2), (0x4020, 2)]
            .map { StreamSlot(index: UInt16($0.0), size: $0.1) }
        try await ecu.startStream(slots)
        let deadline = Date().addingTimeInterval(10); var n = 0
        for await ev in ecu.events {
            if case .sample(let s) = ev { n += 1; if n % 16 == 0 { print(s.values) } }
            if case .heartbeat(let st) = ev { print("heartbeat state", String(format: "%02X", st)) }
            if Date() > deadline { break }
        }
        try await ecu.stopStream(); print("samples:", n)
    }
    await ecu.close()
} catch { print("error:", error); exit(1) }
