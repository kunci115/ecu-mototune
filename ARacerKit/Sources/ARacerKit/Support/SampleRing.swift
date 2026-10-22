import Foundation

/// Fixed-capacity ring of stream samples in ONE flat buffer: O(1) push, no per-sample allocation,
/// no O(n) removeFirst. `series(slot:)` walks the ring once (O(capacity)) only when a chart asks.
public struct SampleRing: Sendable {
    public let capacity: Int
    public private(set) var stride: Int
    private var buf: [UInt32]
    private var head = 0            // next write position (in samples)
    public private(set) var count = 0

    public init(capacity: Int, stride: Int) {
        self.capacity = capacity; self.stride = max(1, stride)
        buf = [UInt32](repeating: 0, count: capacity * self.stride)
    }

    public mutating func reset(stride: Int) {
        self.stride = max(1, stride); buf = [UInt32](repeating: 0, count: capacity * self.stride); head = 0; count = 0
    }

    /// O(1): copies `values` (truncated/padded to `stride`) into the ring.
    public mutating func push(_ values: [UInt32]) {
        let base = head * stride
        for i in 0..<stride { buf[base + i] = i < values.count ? values[i] : 0 }
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Oldest→newest values of one slot. O(count).
    public func series(slot: Int) -> [Double] {
        guard slot < stride, count > 0 else { return [] }
        var out = [Double](); out.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for k in 0..<count { out.append(Double(buf[((start + k) % capacity) * stride + slot])) }
        return out
    }
}
