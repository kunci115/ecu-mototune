import Foundation

/// Replays the real RC MiniX handshake and feeds synthetic live data so the UI runs without the bike.
public func hx(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

public enum DemoECU {
    public static func make() -> Transport {
        let t = ScriptedTransport { f in
            let sub = f.data.count > 3 ? f.data[3] : 0
            switch (f.id, f.data.first ?? 0) {
            case (0x681, 0x00): return [CANFrame(id: 0x6A1, data: hx("07 3c 00 00 01 47 00 04"))]
            case (0x682, 0xD1): return [CANFrame(id: 0x6A2, data: hx("d2 33 36 2d 59 34 38 30")), CANFrame(id: 0x6A2, data: hx("d3 2d 31 32 53 43 41 58")), CANFrame(id: 0x6A2, data: hx("d4 30 00"))]
            case (0x682, 0xC1): return [CANFrame(id: 0x6A2, data: hx("c2 01 27 0a 01"))]
            case (0x682, 0xB1): return [CANFrame(id: 0x6A2, data: hx("b2 a6 05 17 0f 00 6f 69")), CANFrame(id: 0x6A2, data: hx("b3 59"))]
            case (0x680, 0x88): return [CANFrame(id: 0x6A0, data: hx("89 00"))]
            case (0x601, 0x40):
                let idx = UInt16(f.data[1]) | UInt16(f.data[2]) << 8
                func exp(_ v: [UInt8]) -> [CANFrame] { [CANFrame(id: 0x581, data: [UInt8(0x43 | (4 - v.count) << 2), f.data[1], f.data[2], sub] + v + [UInt8](repeating: 0, count: 4 - v.count))] }
                switch (idx, sub) {
                case (0x1018, 2): return exp(hx("a6 00 00 00")); case (0x1018, 5): return exp(hx("01 0a 27 01"))
                case (0x1018, 6): return exp(hx("01 00")); case (0x1018, 7): return exp(hx("87 00"))
                case (0x1018, 8): return exp(hx("11 00")); case (0x1018, 9): return exp(hx("01 00"))
                case (0x1018, 0x0A): return [CANFrame(id: 0x581, data: hx("41 18 10 0a 08 00 00 00"))]
                case (0x1018, 0x0B): return exp(hx("ff ff 0b 00")); case (0x1018, 0x0C): return exp(hx("00 00 00 00"))
                case (0x1018, 0x0D): return exp(hx("0c 41 00 00")); case (0x1018, 0x0E): return exp(hx("f3 bf 0b 00"))
                case (0x1008, 0): return [CANFrame(id: 0x581, data: hx("41 08 10 00 0a 00 00 00"))]
                default: return [CANFrame(id: 0x581, data: [0x80, f.data[1], f.data[2], sub, 0, 0, 0x02, 0x06])]
                }
            case (0x601, 0xA4):
                let idx = UInt16(f.data[1]) | UInt16(f.data[2]) << 8
                return [CANFrame(id: 0x581, data: [0xC2, f.data[1], f.data[2], sub, idx == 0x1008 ? 10 : 8, 0, 0, 0])]
            case (0x601, 0xA3): return [CANFrame(id: 0x581, data: hx("01 a6 05 17 0f 00 6f 69")), CANFrame(id: 0x581, data: hx("82 59 00 00 00 00 00 00"))]
            case (0x601, 0xA2): return [CANFrame(id: 0x581, data: hx("d9 00 00 00 00 00 00 00"))]
            case (0x601, 0x23), (0x601, 0x2B), (0x601, 0x2F): return [CANFrame(id: 0x581, data: [0x60, f.data[1], f.data[2], sub, 0, 0, 0, 0])]
            default: return []
            }
        }
        // Live data for the default (known-variable) slot set, big-endian, chunked at 7 bytes.
        let slots = KnownVariables.defaultSlots
        Task.detached {
            var n = 0; let t0 = Date()
            while true {
                try? await Task.sleep(for: .milliseconds(62)); n += 1
                let ph = Date().timeIntervalSince(t0)
                var raw: [UInt8] = []
                for s in slots {
                    let v: UInt32
                    switch Int(s.index) - 0x4000 {
                    case 26:  v = UInt32(2500 + 2000 * (1 + sin(ph * 0.8)))             // RPM 2500–6500
                    case 51:  v = UInt32((12 + 18 * (1 + sin(ph * 0.5))) * 256)           // VSS raw/256 → 12–48 km/h
                    case 33:  v = 88                                                      // T_Eng °C
                    case 55:  v = UInt32(1280 + 60 * sin(ph * 2.3) + 25 * sin(ph * 7.1))  // AFR 12.2–13.7 (noisy, like a real wideband)
                    case 774: v = UInt32(1250 + 50 * (sin(ph * 0.8) > 0 ? 1 : 0))         // AFR target steps with the cell
                    case 369: v = UInt32(12 + 26 * (1 + sin(ph * 0.8)) / 2)               // TPS 12–38 %
                    case 130: v = 3                                                       // gear
                    case 23:  v = UInt32(180 + 120 * (1 + sin(ph * 0.8)) / 2)             // BPW 1.8–3.0 ms
                    default:  v = UInt32((1 + sin(ph + Double(s.index))) * 30)
                    }
                    for i in (0..<s.size).reversed() { raw.append(UInt8(v >> (8 * UInt32(i)) & 0xFF)) }  // big-endian
                }
                var chunks: [[UInt8]] = stride(from: 0, to: raw.count, by: 7).map { Array(raw[$0..<min($0 + 7, raw.count)]) }
                if chunks.isEmpty { chunks = [[]] }
                for (i, c) in chunks.enumerated() {
                    let b0 = UInt8(i + 1) | (i == chunks.count - 1 ? 0x80 : 0)
                    t.inject(CANFrame(id: 0x181, data: [b0] + c))
                }
                if n % 16 == 0 { t.inject(CANFrame(id: 0x701, data: [0x05])) }
            }
        }
        return t
    }
}
