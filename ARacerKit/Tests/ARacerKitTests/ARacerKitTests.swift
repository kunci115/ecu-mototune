import Testing
@testable import ARacerKit

fileprivate func thx(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

@Suite struct FrameTests {
    @Test func testEncodeMatchesPythonGolden() {
        let f = CANFrame(id: 0x601, data: thx("40 18 10 08 00 00 00 00"))
        #expect([UInt8](f.encoded()).hex == "f8 01 c0 0e 00 00 06 01 00 08 40 18 10 08 00 00 00 00 b3")
    }
    @Test func testRoundTripAndResync() {
        var d = FrameDecoder()
        let a = CANFrame(id: 0x6A2, data: thx("d2 33 36 2d 59 34 38 30"))
        let b = CANFrame(id: 0x701, data: [0x7F])
        var bytes: [UInt8] = [0x00, 0xF8, 0x13] + [UInt8](a.encoded()) + [UInt8](b.encoded())
        let cut = 7
        var out = d.feed(Array(bytes[..<cut])); bytes.removeFirst(cut)
        out += d.feed(bytes)
        #expect(out == [a, b])
    }
}

/// Replays the real exchange recorded in dumps/20261021-215203/frames.log and dumps/20261021-224811.
@Suite struct ProtocolTests {
    static let script: @Sendable (CANFrame) -> [CANFrame] = { f in
        let d = f.data.hex
        switch (f.id, d.prefix(2)) {
        case (0x681, "00"): return [CANFrame(id: 0x6A1, data: thx("07 3c 00 00 01 47 00 04"))]
        case (0x682, "d1"): return [CANFrame(id: 0x6A2, data: thx("d2 33 36 2d 59 34 38 30")), CANFrame(id: 0x6A2, data: thx("d3 2d 31 32 53 43 41 58")), CANFrame(id: 0x6A2, data: thx("d4 30 00"))]
        case (0x682, "c1"): return [CANFrame(id: 0x6A2, data: thx("c2 01 27 0a 01"))]
        case (0x682, "b1"): return [CANFrame(id: 0x6A2, data: thx("b2 a6 05 17 0f 00 6f 69")), CANFrame(id: 0x6A2, data: thx("b3 59"))]
        case (0x680, "88"): return [CANFrame(id: 0x6A0, data: thx("89 00"))]
        case (0x601, _):
            guard f.data.count == 8 else { return [CANFrame(id: 0x581, data: thx("80 00 00 00 00 00 00 08"))] }   // DLC<8 → abort
            switch d {
            case "40 18 10 0b 00 00 00 00": return [CANFrame(id: 0x581, data: thx("43 18 10 0b ff ff 0b 00"))]
            case "40 18 10 07 00 00 00 00": return [CANFrame(id: 0x581, data: thx("4b 18 10 07 87 00 00 00"))]
            case "40 18 10 06 00 00 00 00": return [CANFrame(id: 0x581, data: thx("4b 18 10 06 01 00 00 00"))]
            case "40 18 10 08 00 00 00 00": return [CANFrame(id: 0x581, data: thx("4b 18 10 08 11 00 00 00"))]
            case "40 18 10 09 00 00 00 00": return [CANFrame(id: 0x581, data: thx("4b 18 10 09 01 00 00 00"))]
            case "40 18 10 02 00 00 00 00": return [CANFrame(id: 0x581, data: thx("43 18 10 02 a6 00 00 00"))]
            case "40 18 10 05 00 00 00 00": return [CANFrame(id: 0x581, data: thx("43 18 10 05 01 0a 27 01"))]
            case "40 18 10 0e 00 00 00 00": return [CANFrame(id: 0x581, data: thx("43 18 10 0e f3 bf 0b 00"))]
            case "40 18 10 0a 00 00 00 00": return [CANFrame(id: 0x581, data: thx("41 18 10 0a 08 00 00 00"))]
            case "80 18 10 0a 00 00 00 00": return []
            case "a4 18 10 0a 7f 00 00 00": return [CANFrame(id: 0x581, data: thx("c2 18 10 0a 08 00 00 00"))]
            case "a3 00 00 00 00 00 00 00": return [CANFrame(id: 0x581, data: thx("01 a6 05 17 0f 00 6f 69")), CANFrame(id: 0x581, data: thx("82 59 00 00 00 00 00 00"))]
            case "a2 02 7f 00 00 00 00 00": return [CANFrame(id: 0x581, data: thx("d9 00 00 00 00 00 00 00"))]
            case "a1 00 00 00 00 00 00 00": return []
            case "40 00 30 00 00 00 00 00": return [CANFrame(id: 0x581, data: thx("80 00 30 00 21 00 00 08"))]
            case "40 ff 47 00 00 00 00 00": return [CANFrame(id: 0x581, data: thx("80 ff 47 00 00 00 02 06"))]
            case "2b 00 18 05 40 00 00 00": return [CANFrame(id: 0x581, data: thx("60 00 18 05 00 00 00 00"))]
            default:
                if f.data[0] == 0x23 || f.data[0] == 0x2F || f.data[0] == 0x2B { return [CANFrame(id: 0x581, data: [0x60, f.data[1], f.data[2], f.data[3], 0, 0, 0, 0])] }
                return [CANFrame(id: 0x581, data: [0x80, f.data[1], f.data[2], f.data[3], 0x00, 0x00, 0x02, 0x06])]
            }
        default: return []
        }
    }

    static func makeClient() async throws -> (ECUClient, ScriptedTransport) {
        let t = ScriptedTransport(responder: Self.script)
        let c = ECUClient(transport: t)
        await c.start()
        return (c, t)
    }

    @Test func testIdentifyAndUnlock() async throws {
        let (c, _) = try await Self.makeClient()
        let info = try await c.identify()
        #expect(info.name == "36-Y480-12SCAX0")
        #expect(info.serialHex == "A605170F006F6959")
        #expect(info.model == .miniX); #expect(info.node == 1)
        #expect(info.productCode == 19335681)
        #expect(try await c.unlock())
    }

    @Test func testExpeditedReadAndLicence() async throws {
        let (c, _) = try await Self.makeClient(); _ = try await c.identify()
        #expect(try await c.read(0x1018, 0x0B).uintLE == 0x000B_FFFF)
        #expect(try await c.read(0x1018, 0x07).uintLE == 135)
        #expect(Licence.names(0x000B_FFFF, node: 1).count == 19)
        #expect(Licence.names(0x000B_FFFF, node: 1).contains("Fuel3D"))
    }

    @Test func testBlockUploadWithIndexlessEndResponse() async throws {
        let (c, t) = try await Self.makeClient(); _ = try await c.identify()
        let sn = try await c.read(0x1018, 0x0A)
        #expect(sn.hex == "a6 05 17 0f 00 6f 69 59")
        // every SDO request must have gone out as DLC 8
        #expect(t.sent.filter { $0.id == 0x601 }.allSatisfy { $0.data.count == 8 })
        #expect(t.sent.contains { $0.id == 0x601 && $0.data[0] == 0xA1 })   // A1 sent, ECU not left busy
    }

    @Test func testAbortsAreTyped() async throws {
        let (c, _) = try await Self.makeClient(); _ = try await c.identify()
        #expect(try await c.probe(0x3000, 0) == .error(.busy))
        #expect(try await c.probe(0x47FF, 0) == .error(.abort(code: 0x0602_0000)))
    }

    @Test func testProbeManyPipelined() async throws {
        let (c, _) = try await Self.makeClient(); _ = try await c.identify()
        let r = try await c.probeMany([(0x1018, 0x0B), (0x1018, 0x07), (0x47FF, 0), (0x1018, 0x0A)], window: 4)
        #expect(r[UInt32(0x1018) << 8 | 0x0B] == .value(thx("ff ff 0b 00")))
        #expect(r[UInt32(0x1018) << 8 | 0x07] == .value(thx("87 00")))
        #expect(r[UInt32(0x47FF) << 8] == .error(.abort(code: 0x0602_0000)))
        #expect(r[UInt32(0x1018) << 8 | 0x0A] == .big(size: 8))
    }

    @Test func testStreamMappingAndDecode() async throws {
        let (c, t) = try await Self.makeClient(); _ = try await c.identify()
        let slots = [(0x4001, 1), (0x4006, 1), (0x4009, 1), (0x4014, 1), (0x4016, 2), (0x4019, 2), (0x401B, 2), (0x4020, 2)]
            .map { StreamSlot(index: UInt16($0.0), size: $0.1) }
        try await c.startStream(slots)
        // mapping entry 1 as the app writes it: 23 00 1a 01 08 00 01 40
        #expect(t.sent.contains { $0.id == 0x601 && $0.data.hex == "23 00 1a 01 08 00 01 40" })
        #expect(t.sent.contains { $0.id == 0x601 && $0.data.hex == "2f 00 1a 00 08 00 00 00" })
        // real sample from dumps/20261021-224811/stream.log
        t.inject(CANFrame(id: 0x181, data: thx("01 20 11 48 5f 02 00 04")))
        t.inject(CANFrame(id: 0x181, data: thx("82 14 00 28 00 0c")))
        for await ev in c.events {
            if case .sample(let s) = ev { #expect(s.values == [32, 17, 72, 95, 512, 1044, 40, 12]) /* big-endian; SDO read of 0x4019 gave bytes 14 04 (LE) = 1044 too */; break }
        }
    }
}
