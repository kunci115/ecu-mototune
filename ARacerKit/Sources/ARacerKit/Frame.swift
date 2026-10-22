import Foundation

/// One CAN frame as carried by the aRacer Wi-Fi bridge.
public struct CANFrame: Equatable, Sendable {
    public var id: UInt32
    public var data: [UInt8]
    public var extended: Bool
    public var rtr: Bool

    public init(id: UInt32, data: [UInt8], extended: Bool = false, rtr: Bool = false) {
        precondition(data.count <= 8)
        self.id = id; self.data = data; self.extended = extended; self.rtr = rtr
    }

    /// 19-byte bridge envelope: F8 01 C0 LEN(14) CANID(4, big-endian) FLAGS DLC DATA[8] CHK.
    /// CHK = (256 − sum(bytes[2..<18])) & 0xFF.  Mirrors x/AbstractC0521c.a() in the app.
    public func encoded() -> Data {
        var b: [UInt8] = [0xF8, 0x01, 0xC0, 14]
        b += [UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
        b += [(rtr ? 2 : 0) | (extended ? 1 : 0), UInt8(data.count)]
        b += data; b += [UInt8](repeating: 0, count: 8 - data.count)
        let sum = b[2..<18].reduce(0) { ($0 + Int($1)) & 0xFF }
        b.append(UInt8((256 - sum) & 0xFF))
        return Data(b)
    }
}

/// Byte-wise resynchronising parser, mirroring aRacerWiFiCANService.b().
/// Feed it TCP chunks of any size; it yields complete, checksum-verified frames.
public struct FrameDecoder: Sendable {
    private var buf: [UInt8] = []
    private var state = 0
    private var end = 255
    private var sum = 0

    public init() {}

    public mutating func feed(_ chunk: Data) -> [CANFrame] { feed([UInt8](chunk)) }

    public mutating func feed(_ chunk: [UInt8]) -> [CANFrame] {
        var out: [CANFrame] = []
        for b in chunk {
            let i = state
            if (i == 0 && b != 0xF8) || (i == 1 && b != 0x01) || (i == 2 && b != 0xC0) {
                reset(); continue
            }
            if i == 0 { buf.removeAll(keepingCapacity: true) }
            buf.append(b)
            if i == 3 {
                end = Int(b) + 4
            } else if i == end {
                if UInt8((256 - (sum & 0xFF)) & 0xFF) == b, let f = Self.frame(buf) { out.append(f) }
                reset(); continue
            }
            if i >= 2 { sum += Int(b) }
            state = i + 1
        }
        return out
    }

    private mutating func reset() { state = 0; end = 255; sum = 0; buf.removeAll(keepingCapacity: true) }

    private static func frame(_ raw: [UInt8]) -> CANFrame? {
        guard raw.count >= 18 else { return nil }
        var id = UInt32(raw[4]) << 24 | UInt32(raw[5]) << 16 | UInt32(raw[6]) << 8 | UInt32(raw[7])
        let ext = raw[8] & 1 != 0
        id &= ext ? 0x1FFF_FFFF : 0x7FF
        let dlc = min(Int(raw[9]), 8)
        return CANFrame(id: id, data: Array(raw[10..<10 + dlc]), extended: ext, rtr: raw[8] & 2 != 0)
    }
}
