import Foundation
import ARacerKit

// aracer-cli identify | quick [--key N] | replay <motolog.bin> <motolog.json>
// identify/quick: read-only check against the real bridge from a Mac joined to the ECU Wi-Fi.
// replay: run a phone log through the SAME DynoEngine/TunerEngine the app uses — offline analysis = app code.
let args = CommandLine.arguments.dropFirst()
let cmd = args.first ?? "identify"

if cmd == "replay" {
    let a = Array(args)
    guard a.count >= 3 else { print("usage: aracer-cli replay <motolog.bin> <motolog.json>"); exit(2) }
    let bin = try Data(contentsOf: URL(fileURLWithPath: a[1]))
    let side = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[2]))) as? [String: Any] ?? [:]
    let vars = side["vars"] as? [[String: Any]] ?? []
    let slots = vars.map { StreamSlot(index: UInt16($0["index"] as? Int ?? 0), size: $0["size"] as? Int ?? 1) }
    let payload = slots.reduce(0) { $0 + $1.size }
    let dyno = await DynoEngine(), tuner = await TunerEngine()
    var off = 0, n = 0
    let start = Date(timeIntervalSince1970: 0)
    while off + 4 + payload <= bin.count {
        let ms = bin[off..<off+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let raw = [UInt8](bin[off+4..<off+4+payload]); off += 4 + payload; n += 1
        var values: [UInt32] = []; var p = 0
        for sl in slots { values.append(Array(raw[p..<p + sl.size]).uintBE); p += sl.size }
        let t = start.addingTimeInterval(Double(ms) / 1000)
        await tuner.ingest(values, slots: slots)
        await dyno.ingest(values, slots: slots, at: t)
    }
    print("records:", n, "payload:", payload, "B  tpsMaxSeen:", await dyno.tpsMaxSeen)
    print("pulls:", await dyno.pulls.count)
    for p in await dyno.pulls.reversed() {
        print(String(format: "  t=%.1fs %ds rpm %d→%d maxAFR %@  gear %@", p.startedAt.timeIntervalSince1970, Int(p.duration), p.rpmStart, p.rpmEnd,
                     p.maxAFR.map { String(format: "%.1f", $0) } ?? "–", p.gearRatio.map { String(format: "%.3f", $0) } ?? "–"))
        print("    " + p.curve.map { "\($0.rpm):\(Int($0.accel))" }.joined(separator: " "))
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
