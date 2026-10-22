import Foundation

public enum SDOError: Error, Equatable, Sendable {
    case abort(code: UInt32)            // CANopen abort code, e.g. 0x06020000 object does not exist
    case busy                           // 0x08000021: ECU still had a segmented/block transfer open
    case unexpected([UInt8])
    case timeout
    case notConnected
    case sizeMismatch

    public var isNoSuchObject: Bool { self == .abort(code: 0x0602_0000) }
    public var isNoSuchSubIndex: Bool { self == .abort(code: 0x0609_0011) }

    static func from(abortData d: [UInt8]) -> SDOError {
        let code = UInt32(d[4]) | UInt32(d[5]) << 8 | UInt32(d[6]) << 16 | UInt32(d[7]) << 24
        return code == 0x0800_0021 ? .busy : .abort(code: code)
    }
}

/// Result of an expedited probe: value if ≤4 bytes, or the size the ECU declared for a big object.
public enum ProbeResult: Equatable, Sendable {
    case value([UInt8])
    case big(size: Int)
    case error(SDOError)
}

extension UInt16 {
    var lo: UInt8 { UInt8(self & 0xFF) }
    var hi: UInt8 { UInt8(self >> 8) }
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
    public var uintLE: UInt32 { enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    public var uintBE: UInt32 { reduce(0) { $0 << 8 | UInt32($1) } }
}
