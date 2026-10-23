import Foundation
import Observation
import SwiftData

/// App-facing connection state machine with automatic reconnect.
/// Shared by the macOS dashboard and the iOS app. UI observes `state`, `identity`, `latest`.
@MainActor @Observable
public final class ECUSession {
    public enum State: Equatable {
        case idle, connecting(attempt: Int), connected, lost(reason: String)
        public var label: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting(let n): return n > 1 ? "Reconnecting (\(n))…" : "Connecting…"
            case .connected: return "Connected"
            case .lost(let r): return "Lost: \(r)"
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var info: BridgeInfo?
    public private(set) var identity: ECUIdentity?
    public private(set) var nmtState: UInt8?
    public private(set) var latest: StreamSample?
    public private(set) var sampleRate: Double = 0
    public private(set) var lastError: String?
    // Background logging (runs while locked via AudioKeepAlive)
    public let tuner = TunerEngine()
    public let dyno = DynoEngine()
    public let copilot = Copilot()
    public let fuelMap: FuelMap? = FuelMap.fromCatalog()
    /// Persistence (set by the root view). Pulls are saved as they happen; revisions/backups on write.
    @ObservationIgnored public var db: ModelContext? { didSet { attachDB() } }
    public private(set) var writeBusy = false
    public private(set) var writeLog: [String] = []
    public private(set) var isLogging = false
    public private(set) var logCount = 0
    public private(set) var logName: String?
    @ObservationIgnored private var logHandle: FileHandle?
    @ObservationIgnored private var logStart: Date?
    @ObservationIgnored private var logBuffer = Data()
    // Variable identification (snapshot diff)
    public private(set) var identifyBusy = false
    public private(set) var snapIdle: [UInt16: Int]?
    public private(set) var snapThrottle: [UInt16: Int]?
    public struct Mover: Identifiable, Sendable { public let index: UInt16; public let name: String; public let idle: Int; public let throttle: Int
        public var id: UInt16 { index }; public var delta: Int { throttle - idle } }
    @ObservationIgnored private let keepAlive = AudioKeepAlive()
    public private(set) var history: SampleRing            // last N samples, flat ring (O(1) push)
    public var slots: [StreamSlot]

    public var key: UInt32 = 888_888
    @ObservationIgnored public var makeTransport: @Sendable () async throws -> Transport
    @ObservationIgnored private var client: ECUClient?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var sampleCount = 0
    @ObservationIgnored private var rateTimer: Timer?
    public let historyLength = 300

    public init(slots: [StreamSlot], makeTransport: @escaping @Sendable () async throws -> Transport) {
        self.slots = slots; self.makeTransport = makeTransport
        self.history = SampleRing(capacity: 300, stride: slots.count)
    }

    /// Connect and keep reconnecting with backoff until `disconnect()`.
    public func connect() {
        guard task == nil else { return }
        keepAlive.start()      // stay alive while locked for the whole session: stream, tuner, dyno, reconnects
        task = Task { [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled {
                attempt += 1
                self.state = .connecting(attempt: attempt)
                do {
                    let t = try await self.makeTransport()
                    let c = ECUClient(transport: t)
                    self.client = c
                    let (info, ident) = try await c.connectSequence(key: self.key)
                    self.info = info; self.identity = ident; self.state = .connected; self.lastError = nil; attempt = 0
                    await self.readFuelMapLive(c)
                    try await c.startStream(self.slots)
                    await self.pump(c)                         // returns when the connection is lost
                    self.state = .lost(reason: "koneksi terputus")
                } catch {
                    self.lastError = "\(error)"
                    self.state = .lost(reason: "\(error)")
                }
                self.client = nil
                let delay = min(1.0 * Double(attempt), 5.0)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.sampleRate = Double(self.sampleCount); self.sampleCount = 0 }
        }
    }

    public func disconnect() {
        task?.cancel(); task = nil; rateTimer?.invalidate(); rateTimer = nil
        keepAlive.stop()
        if let c = client { Task { try? await c.stopStream(); await c.close() } }
        client = nil; state = .idle
    }

    private func pump(_ c: ECUClient) async {
        var lastHeartbeat = Date()
        for await ev in c.events {
            switch ev {
            case .heartbeat(let s): nmtState = s; lastHeartbeat = Date()
            case .sample(let s):
                latest = s; sampleCount += 1
                history.push(s.values)
                if isLogging { logSample(s) }
                tuner.ingest(s.values, slots: slots)
                dyno.ingest(s.values, slots: slots, at: s.timestamp)
            case .connectionLost: return
            case .frame: break
            }
            if Date().timeIntervalSince(lastHeartbeat) > 6 { await c.close(); return }   // same watchdog as the app
        }
    }

    /// Re-map the stream to a new set of objects (max 64, ≤512 bytes).
    public func setSlots(_ s: [StreamSlot]) async {
        slots = s; history.reset(stride: s.count)
        if let c = client { try? await c.startStream(s) }
    }

    // MARK: variable identification (snapshot diff)

    /// Read every variable's value into a snapshot. `idle=false` stores the throttle-held snapshot.
    public func captureSnapshot(idle: Bool) async {
        guard state == .connected, let c = client, !identifyBusy else { return }
        identifyBusy = true
        let indices = (0x4001...0x4600).map { UInt16($0) }
        let snap = (try? await c.readVariableWord(indices)) ?? [:]
        if idle { snapIdle = snap } else { snapThrottle = snap }
        identifyBusy = false
        if snapIdle != nil, snapThrottle != nil { saveIdentify() }
    }

    public func clearSnapshots() { snapIdle = nil; snapThrottle = nil }

    /// Variables ranked by how much they changed between idle and throttle (biggest movers first).
    public var movers: [Mover] {
        guard let a = snapIdle, let b = snapThrottle else { return [] }
        return a.keys.compactMap { idx -> Mover? in
            guard let i = a[idx], let t = b[idx], i != t else { return nil }
            let id = Int(idx) - 0x4000
            return Mover(index: idx, name: KnownVariables.byID(id)?.name ?? "VAR \(id)", idle: i, throttle: t)
        }
        .sorted { abs($0.delta) > abs($1.delta) }
    }

    private func saveIdentify() {
        func hexMap(_ m: [UInt16: Int]) -> [String: Int] { Dictionary(uniqueKeysWithValues: m.map { (String(format: "0x%04X", $0.key), $0.value) }) }
        let top = movers.prefix(40).map { ["index": String(format: "0x%04X", $0.index), "id": Int($0.index) - 0x4000, "name": $0.name, "idle": $0.idle, "throttle": $0.throttle, "delta": $0.delta] as [String: Any] }
        let dict: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: .now), "idle": hexMap(snapIdle ?? [:]), "throttle": hexMap(snapThrottle ?? [:]), "topMovers": top]
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]))?.write(to: dir.appendingPathComponent("identify-\(Self.stamp()).json"))
    }

    // MARK: persistence + live map + ECU write

    private func attachDB() {
        guard let db else { return }
        dyno.onPull = { [weak self] pull in
            guard let self, let ctx = self.db else { return }
            let row = AccelPull(at: pull.startedAt, duration: pull.duration, rpmStart: pull.rpmStart, rpmEnd: pull.rpmEnd,
                                gearRatio: pull.gearRatio ?? 0, minAFR: pull.minAFR ?? 0, maxAFR: pull.maxAFR ?? 0,
                                mapLabel: pull.mapLabel, curveJSON: (try? JSONEncoder().encode(pull.curve)) ?? Data(), gear: pull.gear ?? 0)
            row.meanRPM = pull.meanRPM; row.meanVSS = pull.meanVSS
            ctx.insert(row); try? ctx.save()
        }
        // restore earlier pulls so per-revision averages survive app restarts
        var fd = FetchDescriptor<AccelPull>(sortBy: [SortDescriptor(\.at, order: .reverse)]); fd.fetchLimit = DynoEngine.maxPulls
        let saved = (try? db.fetch(fd)) ?? []
        dyno.load(saved.map { a in
            var p = DynoEngine.makePull(startedAt: a.at, duration: a.duration, rpmStart: a.rpmStart, rpmEnd: a.rpmEnd,
                                        gearRatio: a.gearRatio == 0 ? nil : a.gearRatio,
                                        curve: (try? JSONDecoder().decode([DynoEngine.BinAccel].self, from: a.curveJSON)) ?? [],
                                        minAFR: a.minAFR == 0 ? nil : a.minAFR, maxAFR: a.maxAFR == 0 ? nil : a.maxAFR,
                                        sampleCount: 0, mapLabel: a.mapLabel, gear: a.gear == 0 ? nil : a.gear,
                                        meanRPM: a.meanRPM, meanVSS: a.meanVSS)
            if a.gradeKnown {
                p.grade = a.grade; p.segment = a.segment.isEmpty ? nil : a.segment
                p.corrected = try? JSONDecoder().decode([DynoEngine.BinAccel].self, from: a.correctedJSON)
            }
            return p
        })
        var d = FetchDescriptor<MapRevision>(sortBy: [SortDescriptor(\.at, order: .reverse)]); d.fetchLimit = 1
        if let last = (try? db.fetch(d))?.first, last.source != "backup" { dyno.mapLabel = last.label }
    }

    /// Read the real Fuel Adjust rows from the ECU so edits are relative to what it holds now, not the dump.
    private func readFuelMapLive(_ c: ECUClient) async {
        guard let map = fuelMap else { return }
        var rows: [[UInt8]] = []
        for r in 0..<map.tps.count {
            guard let row = try? await c.readBlock(FuelMap.index, UInt8(r)), row.count >= map.rpm.count * 2 else {
                lastError = "fuel map live read failed at row \(r)"; return
            }
            rows.append(row)
        }
        map.load(rawRows: rows)
        if let db {
            let json = (try? JSONEncoder().encode(map.base)) ?? Data()
            var d = FetchDescriptor<MapRevision>(sortBy: [SortDescriptor(\.at, order: .reverse)]); d.fetchLimit = 1
            if (try? db.fetch(d))?.first?.fuelMapJSON != json {       // O(1) row, no duplicate per connect
                db.insert(MapRevision(label: dyno.mapLabel, source: "ecu-read", fuelMapJSON: json)); try? db.save()
            }
        }
    }

    /// Write the staged draft to the ECU: fresh backup → block-download each changed row → read back → verify.
    /// Only called from a user-confirmed button. Returns the new revision label on success.
    @discardableResult
    public func writeFuelDraft(source: String) async -> String? {
        guard !writeBusy, let c = client, let map = fuelMap, map.isLive, state == .connected else {
            writeLog = ["Not connected, or map not read live from ECU"]; return nil
        }
        let rows = map.changedRows
        guard !rows.isEmpty else { writeLog = ["Nothing staged"]; return nil }
        writeBusy = true; defer { writeBusy = false }
        writeLog = ["Backup: re-reading \(rows.count) row(s)…"]
        // 1. backup + guard against the ECU having changed since we read it
        var backup: [Int: [UInt8]] = [:]
        for r in rows {
            guard let cur = try? await c.readBlock(FuelMap.index, UInt8(r)) else { writeLog.append("✗ backup read failed row \(r) — aborted"); return nil }
            if cur != map.rawRows?[r] { writeLog.append("✗ ECU row \(r) differs from what was read at connect — aborted, reconnect to refresh"); return nil }
            backup[r] = cur
        }
        if let db { db.insert(MapRevision(label: dyno.mapLabel + "-backup", source: "backup", fuelMapJSON: (try? JSONEncoder().encode(map.base)) ?? Data())); try? db.save() }
        writeLog.append("✓ backup saved (\(dyno.mapLabel))")
        // 2. write + 3. verify, row by row
        var newRows = map.rawRows!
        for r in rows {
            guard let patched = map.patchedRow(r) else { continue }
            let cells = map.changedCells.filter { $0.row == r }.map { "\(map.rpm[$0.col])rpm \(String(format: "%.1f→%.1f", $0.from, $0.to))" }
            writeLog.append("TPS \(map.tps[r]): writing \(cells.joined(separator: ", "))")
            do { try await c.writeBlock(FuelMap.index, UInt8(r), patched) }
            catch { writeLog.append("✗ write failed row \(r): \(error)"); return nil }
            guard let back = try? await c.readBlock(FuelMap.index, UInt8(r)) else { writeLog.append("✗ readback failed row \(r)"); return nil }
            if back != patched {
                let diff = zip(back, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map { $0.offset }
                writeLog.append("✗ readback mismatch row \(r) at bytes \(diff.prefix(8)) — ECU kept: \(FuelMap.decodeRow(back, cols: map.rpm.count)?.prefix(18).map { String(format: "%.1f", $0) }.joined(separator: " ") ?? "?")")
                newRows[r] = back; map.load(rawRows: newRows); return nil
            }
            newRows[r] = back
            writeLog.append("✓ TPS \(map.tps[r]) verified")
        }
        map.load(rawRows: newRows)
        let label = "rev" + String(Int(Date.now.timeIntervalSince1970) % 100000)
        dyno.mapLabel = label
        if let db {
            db.insert(MapRevision(label: label, source: source, fuelMapJSON: (try? JSONEncoder().encode(map.base)) ?? Data()))
            if let pending = TuningDB.pendingSuggestion(db) { pending.applied = true; pending.decision = "kept"; pending.label = label }
            try? db.save()
        }
        writeLog.append("✓ done — ECU now on \(label). Next pulls are tagged \(label).")
        return label
    }

    /// Fuse a watch FIT file (barometric grade, GPS) into every stored pull it overlaps. Returns a one-line summary.
    @discardableResult
    public func importFIT(_ url: URL, offset: TimeInterval = 0) -> String {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fit: [FITReader.Sample]
        do { fit = try FITReader.records(url: url) } catch { return "Could not read FIT: \(error)" }
        guard let f0 = fit.first, let f1 = fit.last else { return "FIT file has no records" }
        let ctx = RideFusion.annotate(pulls: dyno.pulls, fit: fit, offset: offset)
        var matched = 0, ratios: [Double] = []
        for (pull, c) in zip(dyno.pulls, ctx) where c.samples >= 2 && c.grade != nil {
            matched += 1
            dyno.enrich(pull.id, grade: c.grade, segment: c.segment, corrected: c.corrected)
            if let g = c.gpsSpeedMean, let v = c.vssMean, v > 5 { ratios.append(g / v) }
            if let db {
                let at = pull.startedAt
                var d = FetchDescriptor<AccelPull>(predicate: #Predicate { $0.at == at }); d.fetchLimit = 1
                if let row = (try? db.fetch(d))?.first {
                    row.gradeKnown = true; row.grade = c.grade ?? 0; row.segment = c.segment ?? ""
                    row.correctedJSON = (try? JSONEncoder().encode(c.corrected)) ?? Data()
                }
            }
        }
        try? db?.save()
        let span = "\(Int(f1.time.timeIntervalSince(f0.time)) / 60) min, \(fit.count) samples"
        guard matched > 0 else { return "FIT covers \(span) but overlaps none of \(dyno.pulls.count) pulls — same ride? try an offset" }
        var speed = ""
        if ratios.count >= 2 { let m = ratios.sorted()[ratios.count / 2]; speed = String(format: " · GPS/VSS %.2f%@", m, abs(m - 1) < 0.08 ? " ✓ raw/256" : " ✗ rescale") }
        return "\(matched) of \(dyno.pulls.count) pulls got grade + segment from \(span)\(speed)"
    }

    public func revertDraft() {
        fuelMap?.clearDraft()
        if let db, let pending = TuningDB.pendingSuggestion(db) { pending.decision = "reverted"; try? db.save() }
    }

    // MARK: background logging

    /// Start recording a broad set of live variables to a CSV in the app's Documents,
    /// and keep the app alive while the screen is locked.
    public func startLogging() async {
        guard !isLogging, state == .connected else { return }
        let ts = Self.stamp()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let start = Date.now
        // sidecar describing the binary format + variables (lossless decode)
        try? DiagnosticVars.sidecar(startedAt: start).write(to: dir.appendingPathComponent("motolog-\(ts).json"))
        let binURL = dir.appendingPathComponent("motolog-\(ts).bin")
        FileManager.default.createFile(atPath: binURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: binURL)
        logName = "motolog-\(ts).bin"; logCount = 0; logStart = start; logBuffer = Data()
        await setSlots(DiagnosticVars.slots)
        isLogging = true
    }

    public func stopLogging() async {
        guard isLogging else { return }
        isLogging = false
        flushLog()
        try? logHandle?.close(); logHandle = nil; logBuffer = Data()
        await setSlots(KnownVariables.defaultSlots)
    }

    /// One compact binary record: uint32 LE ms-since-start + the raw sample bytes. Batched to disk.
    private func logSample(_ s: StreamSample) {
        let ms = UInt32(max(0, s.timestamp.timeIntervalSince(logStart ?? s.timestamp) * 1000))
        withUnsafeBytes(of: ms.littleEndian) { logBuffer.append(contentsOf: $0) }
        logBuffer.append(contentsOf: s.raw)
        logCount += 1
        if logBuffer.count >= 8192 { flushLog() }   // ~80 records per write: low I/O, low battery
    }

    private func flushLog() {
        guard !logBuffer.isEmpty, let h = logHandle else { return }
        try? h.write(contentsOf: logBuffer); logBuffer.removeAll(keepingCapacity: true)
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: .now)
    }
}
