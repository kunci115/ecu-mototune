import Testing
import Foundation
@testable import ARacerKit

@Suite struct SessionTests {
    /// Drives the same state machine the dashboard observes: connect → identity → stream → sample → loss → reconnect.
    @Test @MainActor func sessionConnectsStreamsAndReconnects() async throws {
        let holder = TransportHolder()
        let slots = [(0x4001, 1), (0x4016, 2), (0x4019, 2)].map { StreamSlot(index: UInt16($0.0), size: $0.1) }
        let s = ECUSession(slots: slots) { holder.next() }
        s.connect()
        try await waitUntil { s.state == .connected }
        #expect(s.info?.name == "36-Y480-12SCAX0")
        #expect(s.identity?.firmware == "01.135.17.01")
        #expect(Licence.names(s.identity!.ownedFunctions, node: 1).contains("QuickShifter"))
        // sample: 1 + 2 + 2 bytes, big-endian
        holder.current!.inject(CANFrame(id: 0x181, data: [0x81, 0x20, 0x02, 0x00, 0x04, 0x14]))
        try await waitUntil { s.latest != nil }
        #expect(s.latest?.values == [32, 512, 1044])
        // connection drops → session must reconnect with a fresh transport
        holder.current!.close()
        try await waitUntil(timeout: 4) { holder.made >= 2 && s.state == .connected }
        #expect(holder.made >= 2)
        s.disconnect()
        #expect(s.state == .idle)
    }
}

final class TransportHolder: @unchecked Sendable {
    var current: ScriptedTransport?; var made = 0
    func next() -> Transport { made += 1; let t = ScriptedTransport(responder: ProtocolTests.script); current = t; return t }
}

func waitUntil(timeout: Double = 2, _ cond: @MainActor () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if await cond() { return }; try await Task.sleep(for: .milliseconds(20)) }
    Issue.record("timed out waiting for condition")
}

@Suite struct KnownVariableTests {
    @Test func defaultSlotsAreNamedAndSized() {
        let s = KnownVariables.defaultSlots
        #expect(s.count == KnownVariables.all.filter(\.inDefaultStream).count)
        #expect(s.first?.index == 0x401A)              // id 26 = RPM
        #expect(s.first?.name == "RPM")
        #expect(KnownVariables.byID(26)?.confidence == .strong)
        #expect(KnownVariables.byID(55)?.name == "AFR")           // confirmed from ride log
        #expect(KnownVariables.byID(774)?.name == "AFR Target")
        #expect(KnownVariables.byID(369)?.name == "TPS")
        #expect(KnownVariables.byID(55)?.decimals == 1)
        // total payload fits one TPDO burst (<512 B) and chunks cleanly
        #expect(s.reduce(0) { $0 + $1.size } == 13)
    }
    /// The RPM box must receive a changing value from the demo stream, decoded big-endian at slot 0.
    @Test @MainActor func demoFeedsNamedRPM() async throws {
        let sess = ECUSession(slots: KnownVariables.defaultSlots) { DemoECU.make() }
        sess.connect()
        try await waitUntil(timeout: 4) { sess.state == .connected }
        var seen = Set<UInt32>()
        try await waitUntil(timeout: 4) {
            if let v = sess.latest?.values.first { seen.insert(v) }
            return seen.count >= 3            // value is actually moving
        }
        #expect(seen.allSatisfy { $0 < 9000 })  // plausible RPM range
        sess.disconnect()
    }
}

@Suite struct CatalogTests {
    /// The real tuning tables must decode from the dump with sane values.
    @Test func realTablesDecode() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("table_catalog.json")
        let cat = try JSONDecoder().decode([CatTable].self, from: Data(contentsOf: url))
        let present = cat.filter { $0.present }
        #expect(present.count >= 15)
        // RPM limit scalar = 12000 (0x2EE0), little-endian 2 bytes
        let rl = cat.first { $0.name == "RPM limit" }!
        let b = [UInt8](hexString: rl.values_hex!["0"]!)
        #expect(Int(b[0]) | Int(b[1]) << 8 == 12000)
        // Target AFR as 1-byte grid: 17 rows of 20, all in a plausible AFR-code band
        let afr = cat.first { $0.name == "Target AFR" }!
        let rows = afr.values_hex!.keys.compactMap { Int($0) }.sorted()
        #expect(rows.count == 17)
        let r0 = [UInt8](hexString: afr.values_hex!["0"]!)
        #expect(r0.count == 20)
        #expect(r0.allSatisfy { $0 >= 100 && $0 <= 160 })
    }
}

struct CatTable: Decodable { var name: String; var present: Bool; var values_hex: [String:String]? }
extension Array where Element == UInt8 {
    init(hexString s: String) { self = stride(from: 0, to: s.count, by: 2).compactMap {
        let i = s.index(s.startIndex, offsetBy: $0); let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        return UInt8(s[i..<j], radix: 16) } }
}

@Suite struct ScalingTests {
    @Test func afrScalesToPhysicalRange() {
        let afr = Scaling.byID[54]!
        #expect(afr.unit == "AFR")
        #expect(afr.text(127) == "12.7")      // owner: floats ~12.8
        #expect(afr.text(100) == "10.0")      // very rich end
        #expect(afr.text(140) == "14.0")      // very lean end
    }
    @Test func sparkScalesToDegrees() {
        let sp = Scaling.byID[133]!
        #expect(sp.cellBytes == 2 && sp.unit == "°")
        #expect(sp.text(152) == "15.2")
        #expect(sp.text(80) == "8.0")
    }
    @Test func fuelAdjustNeutralIs100Percent() {
        let fa = Scaling.byID[4]!
        #expect(Int(fa.value(128).rounded()) == 100)   // 0x80 = no change
    }
}

@Suite struct GeometryTests {
    @Test func fuelAdjustAxesAndCrop() throws {
        let fuel = Axes.byID[4]!
        // rows 0–10 matched the official grid; 50…100 inferred from the 17 data-bearing rows in the dump
        #expect(Array(fuel.tps.prefix(11)) == [0, 2, 4, 6, 8, 10, 15, 20, 25, 30, 40] && fuel.tps.count == 17)
        #expect(fuel.rpm.count == 20 && fuel.rpm.first == 800 && fuel.rpm.last == 16000)
        // real dump: fuel adjust row0, first 6 cols (2-byte ×100/128) == official TPS0 row
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("table_catalog.json")
        let cat = try JSONDecoder().decode([CatTable].self, from: Data(contentsOf: url))
        let t = cat.first { $0.name == "Fuel adjust 3D" }!
        let b = [UInt8](hexString: t.values_hex!["0"]!)
        let row0 = stride(from: 0, to: 12, by: 2).map { Double(Int(b[$0]) | Int(b[$0+1]) << 8) * 100.0 / 128.0 }
        #expect(row0.map { ($0 * 10).rounded() / 10 } == [75, 75, 75, 100, 100, 100])
        // rows 15–16 carry data out to column 19 and rows 17+ are padding → 17×20 is the real extent
        let r16 = [UInt8](hexString: t.values_hex!["16"]!), r17 = [UInt8](hexString: t.values_hex!["17"]!)
        #expect(Int(r16[38]) | Int(r16[39]) << 8 != 128)
        #expect(r17.allSatisfy { $0 == 0x80 || $0 == 0 })
    }
    @Test func afrAxes() {
        let afr = Axes.byID[54]!
        #expect(afr.tps.count == 17 && afr.rpm.count == 20)
        #expect(afr.confirmed == false)
    }
}


