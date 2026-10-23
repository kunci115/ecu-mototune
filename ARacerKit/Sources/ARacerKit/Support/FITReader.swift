import Foundation

/// Minimal reader for Garmin FIT activity files (the public FIT protocol, no SDK dependency).
/// Decodes `record` messages (global 20): timestamp, GPS position, altitude (barometric on watches
/// that have it), speed, distance, heart rate, temperature, grade. Developer fields are skipped.
public struct FITReader {
    public struct Sample: Sendable, Equatable {
        public var time: Date
        public var lat: Double?          // degrees
        public var lon: Double?          // degrees
        public var altitude: Double?     // metres
        public var speed: Double?        // m/s
        public var distance: Double?     // metres, cumulative
        public var heartRate: Int?
        public var temperature: Double?  // °C
        public var grade: Double?        // %, if the device recorded one
    }

    public enum Error: Swift.Error { case notFIT, truncated }

    static let epoch = Date(timeIntervalSince1970: 631_065_600)   // 1989-12-31 00:00:00 UTC
    private struct FieldDef { let num: Int; let size: Int; let base: UInt8 }
    private struct MessageDef { let global: Int; let littleEndian: Bool; let fields: [FieldDef]; let devBytes: Int }

    /// All `record` samples in time order.
    public static func records(from data: Data) throws -> [Sample] {
        let b = [UInt8](data)
        guard b.count >= 14, b[8] == 0x2E, b[9] == 0x46, b[10] == 0x49, b[11] == 0x54 else { throw Error.notFIT }   // ".FIT"
        let headerSize = Int(b[0])
        let dataSize = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        var p = headerSize
        let end = min(b.count, headerSize + dataSize)
        var defs: [Int: MessageDef] = [:]
        var lastTimestamp: UInt32 = 0
        var out: [Sample] = []

        func u(_ at: Int, _ n: Int, _ le: Bool) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { let byte = UInt64(b[at + i]); v |= le ? byte << (8 * UInt64(i)) : byte << (8 * UInt64(n - 1 - i)) }
            return v
        }
        func value(_ at: Int, _ f: FieldDef, _ le: Bool) -> Double? {
            switch f.base & 0x1F {
            case 0x00, 0x02, 0x0A: let v = b[at]; return (v == 0xFF || (f.base == 0x0A && v == 0)) ? nil : Double(v)
            case 0x01: let v = Int8(bitPattern: b[at]); return v == 0x7F ? nil : Double(v)
            case 0x03: let v = Int16(truncatingIfNeeded: u(at, 2, le)); return v == 0x7FFF ? nil : Double(v)
            case 0x04, 0x0B: let v = UInt16(u(at, 2, le)); return (v == 0xFFFF || (f.base == 0x8B && v == 0)) ? nil : Double(v)
            case 0x05: let v = Int32(truncatingIfNeeded: u(at, 4, le)); return v == 0x7FFF_FFFF ? nil : Double(v)
            case 0x06, 0x0C: let v = UInt32(u(at, 4, le)); return (v == 0xFFFF_FFFF || (f.base == 0x8C && v == 0)) ? nil : Double(v)
            case 0x08: return Double(Float(bitPattern: UInt32(u(at, 4, le))))
            case 0x09: return Double(bitPattern: u(at, 8, le))
            default: return nil
            }
        }

        func decode(_ d: MessageDef, at start: Int, timestamp: UInt32?) throws -> Int {
            var q = start
            let total = d.fields.reduce(0) { $0 + $1.size } + d.devBytes
            guard start + total <= end else { throw Error.truncated }
            if d.global == 20 {
                var s = Sample(time: epoch)
                var ts = timestamp
                for f in d.fields {
                    let v = value(q, f, d.littleEndian); q += f.size
                    guard let v else { continue }
                    switch f.num {
                    case 253: ts = UInt32(v); lastTimestamp = UInt32(v)
                    case 0: s.lat = v * 180 / 2_147_483_648
                    case 1: s.lon = v * 180 / 2_147_483_648
                    case 2: if s.altitude == nil { s.altitude = v / 5 - 500 }
                    case 78: s.altitude = v / 5 - 500
                    case 6: if s.speed == nil { s.speed = v / 1000 }
                    case 73: s.speed = v / 1000
                    case 5: s.distance = v / 100
                    case 3: s.heartRate = Int(v)
                    case 13: s.temperature = v
                    case 9: s.grade = v / 100
                    default: break
                    }
                }
                if let ts { s.time = epoch.addingTimeInterval(Double(ts)); out.append(s) }
            } else {
                for f in d.fields {                                  // keep the clock for compressed headers
                    if f.num == 253, let v = value(q, f, d.littleEndian) { lastTimestamp = UInt32(v) }
                    q += f.size
                }
            }
            return start + total
        }
        while p < end {
            let h = b[p]; p += 1
            if h & 0x80 != 0 {                                    // compressed-timestamp data header
                let local = Int((h >> 5) & 0x3), offset = UInt32(h & 0x1F)
                guard let d = defs[local] else { throw Error.truncated }
                lastTimestamp = (lastTimestamp & ~0x1F) | offset + ((offset < lastTimestamp & 0x1F) ? 0x20 : 0)
                p = try decode(d, at: p, timestamp: lastTimestamp)
                continue
            }
            let local = Int(h & 0x0F)
            if h & 0x40 != 0 {                                    // definition message
                guard p + 5 <= end else { throw Error.truncated }
                let le = b[p + 1] == 0
                let global = Int(u(p + 2, 2, le)); let n = Int(b[p + 4]); p += 5
                var fields: [FieldDef] = []
                for _ in 0..<n { guard p + 3 <= end else { throw Error.truncated }; fields.append(.init(num: Int(b[p]), size: Int(b[p + 1]), base: b[p + 2])); p += 3 }
                var dev = 0
                if h & 0x20 != 0 { guard p < end else { throw Error.truncated }; let m = Int(b[p]); p += 1; for _ in 0..<m { dev += Int(b[p + 1]); p += 3 } }
                defs[local] = MessageDef(global: global, littleEndian: le, fields: fields, devBytes: dev)
            } else {                                              // normal data message
                guard let d = defs[local] else { throw Error.truncated }
                p = try decode(d, at: p, timestamp: nil)
            }
        }

        return out
    }

    public static func records(url: URL) throws -> [Sample] { try records(from: Data(contentsOf: url)) }
}
