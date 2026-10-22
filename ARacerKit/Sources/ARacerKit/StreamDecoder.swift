import Foundation

/// One object mapped into TPDO1: CANopen index (0x4000+var id or 0x3000+table id) and byte size.
public struct StreamSlot: Equatable, Sendable {
    public var index: UInt16
    public var size: Int          // 1, 2 or 4
    public var name: String
    public init(index: UInt16, size: Int, name: String = "") { self.index = index; self.size = size; self.name = name }
    /// 0x1A00 entry as the app writes it: (index << 16) | (bytes * 8)
    public var mappingWord: UInt32 { UInt32(index) << 16 | UInt32(size * 8) }
}

public struct StreamSample: Sendable, Equatable {
    public var timestamp: Date
    public var raw: [UInt8]
    public var values: [UInt32]   // one per slot, BIG-endian unsigned (the app parses the sample with a default-order Java ByteBuffer)
}

/// Multi-byte values in the stream are big-endian, unlike SDO payloads (little-endian); A4/a.java reads the
/// reassembled sample with ByteBuffer.allocate(512) (Java default BIG_ENDIAN) → max sample 512 bytes.
/// Reassembles 0x180+node chunks (byte 0 = seq, bit 7 = last) into samples and splits them by the mapping.
public struct StreamDecoder: Sendable {
    public var slots: [StreamSlot]
    private var chunks: [[UInt8]] = []
    private var expect = 1

    public init(slots: [StreamSlot]) { self.slots = slots }

    public mutating func feed(_ data: [UInt8], at time: Date = Date()) -> StreamSample? {
        guard let b0 = data.first else { return nil }
        let seq = Int(b0 & 0x7F), last = b0 & 0x80 != 0
        if seq != expect { chunks.removeAll(); expect = 1; if seq != 1 { return nil } }
        chunks.append(Array(data.dropFirst()))
        expect = seq + 1
        guard last else { return nil }
        let raw = chunks.flatMap { $0 }
        chunks.removeAll(); expect = 1
        var values: [UInt32] = []; var p = 0
        for s in slots {
            guard p + s.size <= raw.count else { break }
            values.append(Array(raw[p..<p + s.size]).uintBE); p += s.size
        }
        return StreamSample(timestamp: time, raw: raw, values: values)
    }
}
