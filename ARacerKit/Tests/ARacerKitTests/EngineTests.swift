import Testing
import Foundation
@testable import ARacerKit

/// Synthetic rides through the same engines the phone runs — no hardware needed.
@Suite struct EngineTests {
    static let slots = [StreamSlot(index: 0x401A, size: 2), StreamSlot(index: 0x4171, size: 1),
                        StreamSlot(index: 0x4033, size: 2), StreamSlot(index: 0x4037, size: 2),
                        StreamSlot(index: 0x4306, size: 2), StreamSlot(index: 0x4021, size: 1)]

    /// One full-throttle pull: rpm rises linearly at `accel` rpm/s from 3000 to 9000 at 16 Hz, TPS 38, then throttle off.
    @MainActor static func ride(_ d: DynoEngine, accel: Double, afr: Double = 12.8, t0: Double) {
        var t = t0
        for _ in 0..<16 { d.ingest([UInt32(1700), 0, 0, UInt32(afr * 100), 1300, 70], slots: slots, at: Date(timeIntervalSince1970: t)); t += 1.0 / 16 }
        var rpm = 3000.0
        while rpm < 9000 {
            d.ingest([UInt32(rpm), 38, UInt32(rpm * 2), UInt32(afr * 100), 1250, 70], slots: slots, at: Date(timeIntervalSince1970: t))
            rpm += accel / 16; t += 1.0 / 16
        }
        for _ in 0..<16 { d.ingest([UInt32(6000), 5, 12000, UInt32(afr * 100), 1300, 70], slots: slots, at: Date(timeIntervalSince1970: t)); t += 1.0 / 16 }
    }

    @Test @MainActor func detectsPullAndMeasuresAccel() {
        let d = DynoEngine()
        Self.ride(d, accel: 2000, t0: 1000)
        #expect(d.pulls.count == 1)
        let p = d.pulls[0]
        #expect(p.rpmStart >= 3000 && p.rpmEnd >= 8800)
        #expect(!p.curve.isEmpty)
        for b in p.curve { #expect(abs(b.accel - 2000) < 60, "bin \(b.rpm) accel \(b.accel)") }
        #expect(p.maxAFR == 12.8)
    }

    @Test @MainActor func revisionComparisonRespectsNoise() {
        let d = DynoEngine()
        d.mapLabel = "base"
        for i in 0..<3 { Self.ride(d, accel: 2000 + Double(i % 2) * 20, t0: 1000 + Double(i) * 100) }   // ±1% jitter
        d.mapLabel = "rev1"
        for i in 0..<3 { Self.ride(d, accel: 2100 + Double(i % 2) * 20, t0: 2000 + Double(i) * 100) }   // +5%
        #expect(d.labels == ["rev1", "base"])
        let cmp = d.compare(label: "rev1", with: "base")
        #expect(!cmp.isEmpty)
        let mean = cmp.map(\.pct).reduce(0, +) / Double(cmp.count)
        #expect(mean > 3.5 && mean < 6.5)
        #expect(cmp.filter { $0.significant }.count == cmp.count)
        #expect(cmp.first?.nA == 3 && cmp.first?.nB == 3)
        // identical revisions → nothing significant
        d.mapLabel = "rev2"
        for i in 0..<3 { Self.ride(d, accel: 2100 + Double(i % 2) * 20, t0: 3000 + Double(i) * 100) }
        #expect(d.compare(label: "rev2", with: "rev1").allSatisfy { !$0.significant })
    }

    @Test @MainActor func pullsPersistViaHookAndReload() {
        let d = DynoEngine(); var saved: [DynoEngine.Pull] = []
        d.onPull = { saved.append($0) }
        Self.ride(d, accel: 1800, t0: 1000)
        #expect(saved.count == 1)
        let d2 = DynoEngine(); d2.load(saved)
        #expect(d2.pulls.count == 1 && d2.pulls[0].curve.map(\.accel) == saved[0].curve.map(\.accel))
    }

    @Test @MainActor func tunerGatesTransientsAndKeepsAFRMean() {
        let t = TunerEngine()
        // steady cruise: 4000 rpm, TPS 15, AFR 13.0 vs target 12.5
        for _ in 0..<40 { t.ingest([4000, 15, 0, 1300, 1250, 70], slots: Self.slots) }
        let cell = t.cells[t.tps.firstIndex(of: 15)!][t.rpm.firstIndex(of: 4000)!]
        #expect(cell.count > 25)
        #expect(abs(cell.meanAFR! - 13.0) < 0.01)
        #expect(abs(cell.correctionPct! - 4.0) < 0.1)
        // throttle snap: TPS jumping every sample must be rejected
        let before = t.samplesLearned
        for i in 0..<10 { t.ingest([4000, UInt32(10 + i * 3), 0, 1100, 1250, 70], slots: Self.slots) }
        #expect(t.samplesLearned == before)
        #expect(t.rejectedTransient >= 10)
    }
}

@Suite struct FuelMapTests {
    @MainActor func liveMap() -> FuelMap {
        let m = FuelMap(base: Array(repeating: Array(repeating: 100, count: 18), count: 11),
                        tps: [0, 2, 4, 6, 8, 10, 15, 20, 25, 30, 40], rpm: (1...18).map { $0 * 800 })
        var rows: [[UInt8]] = []
        for r in 0..<11 { var row = [UInt8](repeating: 0, count: 112); for c in 0..<56 { let v = UInt16(128 + r + c); row[c*2] = UInt8(v & 0xFF); row[c*2+1] = UInt8(v >> 8) }; rows.append(row) }
        m.load(rawRows: rows)
        return m
    }

    @Test @MainActor func loadDecodesAndPatchPreservesTail() {
        let m = liveMap()
        #expect(m.isLive && m.source == "ecu")
        #expect(abs(m.base[2][3] - Double(128 + 5) * 100 / 128) < 0.001)
        m.nudge([(2, 3)], by: 2.0)
        #expect(m.changedRows == [2])
        let p = m.patchedRow(2)!
        #expect(p.count == 112)
        let v = Int(p[6]) | Int(p[7]) << 8
        #expect(v == Int(FuelMap.rawCell(m.value(2, 3))))
        // untouched cells and the undisplayed tail are byte-identical
        for i in 0..<112 where i != 6 && i != 7 { #expect(p[i] == m.rawRows![2][i]) }
        #expect(m.patchedRow(3)! == m.rawRows![3])
    }

    @Test @MainActor func stageIsGradualAndClamped() {
        let m = liveMap()
        m.stage(1, 1, to: m.base[1][1] + 12, maxStep: 3)
        #expect(abs(m.delta(1, 1) - 3) < 0.001)
        m.stage(1, 2, to: 10, maxStep: 100)
        #expect(m.value(1, 2) == m.minPct)
    }
}

@Suite struct CopilotFilterTests {
    @Test @MainActor func leanGuardAndPullRangeAreEnforcedInCode() {
        let m = FuelMap(base: Array(repeating: Array(repeating: 100, count: 18), count: 11),
                        tps: [0, 2, 4, 6, 8, 10, 15, 20, 25, 30, 40], rpm: (1...18).map { $0 * 800 })
        let t = TunerEngine(), d = DynoEngine()
        // lean cell at TPS 30 / 6400 rpm: AFR 14.2 vs target 12.5
        for _ in 0..<10 { t.ingest([6400, 30, 0, 1420, 1250, 70], slots: EngineTests.slots) }
        EngineTests.ride(d, accel: 2000, t0: 1000)   // pulls cover ~3000–9000
        let raw: [[String: Any]] = [
            ["tps": 30, "rpm": 6400, "delta_pct": -2.0, "reason": "cut"],        // blocked: lean
            ["tps": 30, "rpm": 6400, "delta_pct": 2.0, "reason": "add"],         // ok
            ["tps": 20, "rpm": 12800, "delta_pct": 1.0, "reason": "far"],        // blocked: no pull there
            ["tps": 99, "rpm": 800, "delta_pct": 1.0, "reason": "bad axis"],     // blocked: unknown cell
        ]
        let (acc, rej) = Copilot.filter(raw, map: m, tuner: t, dyno: d)
        #expect(acc.count == 1 && acc[0].delta == 2.0)
        #expect(rej.count == 3)
    }
}

@Suite struct SampleRingTests {
    @Test func ringKeepsLastNInOrderWithoutGrowth() {
        var r = SampleRing(capacity: 4, stride: 2)
        for i in 0..<10 { r.push([UInt32(i), UInt32(i * 10)]) }
        #expect(r.count == 4)
        #expect(r.series(slot: 0) == [6, 7, 8, 9])
        #expect(r.series(slot: 1) == [60, 70, 80, 90])
        #expect(r.series(slot: 5).isEmpty)
        r.reset(stride: 3); #expect(r.count == 0 && r.series(slot: 0).isEmpty)
        r.push([1, 2]); #expect(r.series(slot: 2) == [0])   // short sample padded, never out of bounds
    }
}

@Suite struct FITTests {
    /// Hand-built FIT: header, one record definition (timestamp, lat, lon, altitude, speed, distance), two data messages,
    /// one compressed-timestamp message. No CRC (the reader does not verify it).
    static func fit() -> Data {
        var b: [UInt8] = []
        func u16(_ v: UInt16) { b += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func s32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        var body: [UInt8] = []
        // definition, local 0, little-endian, global 20, 6 fields
        body += [0x40, 0, 0, 20, 0, 6, 253, 4, 0x86, 0, 4, 0x85, 1, 4, 0x85, 2, 2, 0x84, 6, 2, 0x84, 5, 4, 0x86]
        func rec(_ ts: UInt32, _ lat: Int32, _ lon: Int32, _ altRaw: UInt16, _ spd: UInt16, _ dist: UInt32) {
            b = []; u32(ts); s32(lat); s32(lon); u16(altRaw); u16(spd); u32(dist); body += [0x00] + b
        }
        rec(1_000_000, 0, 0, (0 + 500) * 5, 10_000, 0)                   // 0 m, 10 m/s, d=0
        rec(1_000_001, 0, 0, (2 + 500) * 5, 10_000, 10_000)              // 2 m up after 100 m → 2 %
        // compressed-timestamp data: header 1 0 00 00010 → local 0, offset 2 → ts 1_000_002
        b = []; s32(0); s32(0); u16((4 + 500) * 5); u16(10_000); u32(20_000)
        body += [0x82] + b.dropFirst(4)   // compressed header replaces the timestamp field? No: FIT keeps all fields; emulate with full fields
        // (the reader reads all defined fields for a compressed record; timestamp field then also appears → keep it explicit)
        body.removeLast(b.count - 4)     // undo: rebuild explicit below
        body.removeLast()                // remove the 0x82 header
        b = []; u32(1_000_002); s32(0); s32(0); u16((4 + 500) * 5); u16(10_000); u32(20_000); body += [0x00] + b
        var out: [UInt8] = [14, 0x10, 0, 0]
        let size = UInt32(body.count); out += [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]
        out += Array(".FIT".utf8) + [0, 0]
        out += body + [0, 0]
        return Data(out)
    }

    @Test func readsRecordsAndScales() throws {
        let r = try FITReader.records(from: Self.fit())
        #expect(r.count == 3)
        #expect(r[0].time == FITReader.epoch.addingTimeInterval(1_000_000))
        #expect(r[1].altitude == 2 && r[1].speed == 10 && r[1].distance == 100)
        #expect(r[2].altitude == 4 && r[2].distance == 200)
    }

    @Test @MainActor func fusionCorrectsForGrade() throws {
        let fitSamples = try FITReader.records(from: Self.fit())
        // a pull at 4000 rpm mean over those 2 s at 10 m/s (36 km/h): rpm per m/s = 400
        let t0 = FITReader.epoch.addingTimeInterval(1_000_000)
        let pull = DynoEngine.makePull(startedAt: t0, duration: 2, rpmStart: 3000, rpmEnd: 5000, gearRatio: nil,
                                       curve: [.init(rpm: 3000, accel: 1000, n: 5), .init(rpm: 4000, accel: 1000, n: 5)],
                                       minAFR: nil, maxAFR: nil, sampleCount: 10, mapLabel: "base")
        let raw = (0..<10).map { DynoEngine.Sample(t: t0.timeIntervalSince1970 + Double($0) * 0.2, rpm: 4000, tps: 100, vss: 36 * 256, afr: nil) }
        let ctx = RideFusion.annotate(pulls: [pull], rawSamples: [raw], fit: fitSamples)
        #expect(ctx.count == 1)
        #expect(ctx[0].grade == 2.0)
        #expect(abs((ctx[0].gpsSpeedMean ?? 0) - 36) < 0.01 && abs((ctx[0].vssMean ?? 0) - 36) < 0.01)
        // 2 % uphill: g·sinθ ≈ 0.196 m/s² × 400 rpm per m/s ≈ +78 rpm/s added back
        #expect(abs(ctx[0].corrected[0].accel - 1078) < 2)
        #expect(ctx[0].segment != nil)
    }
}
