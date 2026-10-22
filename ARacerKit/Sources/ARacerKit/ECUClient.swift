import Foundation

public enum ECUEvent: Sendable, Equatable {
    case heartbeat(state: UInt8)          // 0x7F pre-operational, 0x05 operational
    case sample(StreamSample)
    case frame(CANFrame)                  // anything not handled
    case connectionLost
}

/// Protocol client for one aRacer ECU behind the Wi-Fi bridge.
/// All SDO transactions are serialised; frames that are not an awaited reply go to `events`.
public actor ECUClient {
    public let transport: Transport
    public private(set) var info: BridgeInfo?
    public private(set) var node: UInt8?
    public private(set) var streamDecoder = StreamDecoder(slots: [])
    public nonisolated let events: AsyncStream<ECUEvent>
    private let eventCont: AsyncStream<ECUEvent>.Continuation

    /// A registered expectation for one frame. Registration is synchronous so a reply can never
    /// arrive before the waiter exists (it does in tests, and on a fast bridge).
    public final class Pending: @unchecked Sendable {
        let id = UUID(); let pred: @Sendable (CANFrame) -> Bool
        var result: Result<CANFrame, Error>?; var cont: CheckedContinuation<CANFrame, Error>?
        init(_ pred: @escaping @Sendable (CANFrame) -> Bool) { self.pred = pred }
        func settle(_ r: Result<CANFrame, Error>) { if let c = cont { cont = nil; c.resume(with: r) } else if result == nil { result = r } }
    }
    private var waiters: [Pending] = []
    /// Frames that arrived with no waiter yet (e.g. the three bridge-name frames after one ack).
    private var inbox: [CANFrame] = []
    private var rxTask: Task<Void, Never>?
    private var lockQueue: [CheckedContinuation<Void, Never>] = []
    private var locked = false
    public private(set) var staleFrames = 0
    public var log: (@Sendable (String) -> Void)?

    public init(transport: Transport) {
        self.transport = transport
        var c: AsyncStream<ECUEvent>.Continuation!
        events = AsyncStream { c = $0 }
        eventCont = c
    }

    /// Start consuming the transport. Call once after the transport is connected.
    public func start() {
        guard rxTask == nil else { return }
        rxTask = Task { [transport] in
            var dec = FrameDecoder()
            for await chunk in transport.incoming {
                for f in dec.feed(chunk) { self.handle(f) }
            }
            self.lost()
        }
    }

    public func close() { transport.close(); rxTask?.cancel() }

    private func lost() {
        for w in waiters { w.settle(.failure(SDOError.notConnected)) }
        waiters.removeAll()
        eventCont.yield(.connectionLost)
    }

    private func handle(_ f: CANFrame) {
        if let i = waiters.firstIndex(where: { $0.pred(f) }) {
            waiters.remove(at: i).settle(.success(f)); return
        }
        if let n = node, f.id == 0x700 + UInt32(n), let s = f.data.first { eventCont.yield(.heartbeat(state: s)); return }
        if let n = node, f.id == 0x180 + UInt32(n) {
            if let s = streamDecoder.feed(f.data) { eventCont.yield(.sample(s)) }
            return
        }
        inbox.append(f); if inbox.count > 256 { inbox.removeFirst() }
        eventCont.yield(.frame(f))
    }

    // MARK: primitives

    public func send(_ id: UInt32, _ data: [UInt8]) async throws {
        var d = data
        if let n = node, id == 0x600 + UInt32(n), d.count < 8 { d += [UInt8](repeating: 0, count: 8 - d.count) }  // ECU aborts short SDO frames
        try await transport.send(CANFrame(id: id, data: d).encoded())
    }

    /// Register interest in the first frame matching `pred`. Synchronous: do this before sending.
    public func expect(timeout: Duration = .seconds(1.5), _ pred: @escaping @Sendable (CANFrame) -> Bool) -> Pending {
        let p = Pending(pred)
        if let i = inbox.firstIndex(where: pred) { p.settle(.success(inbox.remove(at: i))); return p }
        waiters.append(p)
        Task { try? await Task.sleep(for: timeout); self.expire(p) }
        return p
    }
    private func expire(_ p: Pending) {
        if let i = waiters.firstIndex(where: { $0 === p }) { waiters.remove(at: i).settle(.failure(SDOError.timeout)) }
    }
    /// Await a registered expectation.
    public func result(_ p: Pending) async throws -> CANFrame {
        if let r = p.result { return try r.get() }
        return try await withCheckedThrowingContinuation { p.cont = $0 }
    }
    public func waitFrame(timeout: Duration = .seconds(1.5), _ pred: @escaping @Sendable (CANFrame) -> Bool) async throws -> CANFrame {
        try await result(expect(timeout: timeout, pred))
    }
    /// Register, send, await.
    public func exchange(_ id: UInt32, _ data: [UInt8], timeout: Duration = .seconds(1.5),
                         _ pred: @escaping @Sendable (CANFrame) -> Bool) async throws -> CANFrame {
        let p = expect(timeout: timeout, pred)
        try await send(id, data)
        return try await result(p)
    }

    private func acquire() async {
        if locked { await withCheckedContinuation { lockQueue.append($0) } } else { locked = true }
        if let n = node {                                   // a reply left over from a timed-out request must not satisfy a new one
            let before = inbox.count; inbox.removeAll { $0.id == 0x580 + UInt32(n) }; staleFrames += before - inbox.count
        }
    }
    private func release() {
        if let c = lockQueue.first { lockQueue.removeFirst(); c.resume() } else { locked = false }
    }
    /// Run one SDO transaction exclusively.
    public func transaction<T: Sendable>(_ body: @Sendable (isolated ECUClient) async throws -> T) async throws -> T {
        await acquire(); defer { release() }
        return try await body(self)
    }

    // MARK: bridge handshake (§4 of PROTOCOL.md)

    public func identify() async throws -> BridgeInfo {
        try await transaction { c in
            var name = [UInt8](repeating: 0, count: 15), serial = [UInt8](repeating: 0, count: 8)
            let v = try await c.exchange(0x681, [0x00]) { $0.id == 0x6A1 }
            var info = BridgeInfo(bridgeVersion: v.data[0], bridgeSub: v.data.count > 1 ? v.data[1] : 0, name: "", productCode: 0, serial: [])
            try await c.send(0x682, [0xD1])
            loop: while true {
                let f = try await c.waitFrame { $0.id == 0x6A2 || $0.id == 0x6A0 }
                let d = f.data
                switch d[0] {
                case 0xD2: name.replaceSubrange(0..<7, with: d[1..<8])
                case 0xD3: name.replaceSubrange(7..<14, with: d[1..<8])
                case 0xD4:
                    name[14] = d[1]
                    info.name = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    try await c.send(0x682, [0xC1])
                case 0xC2:
                    info.productCode = UInt32(d[1]) << 24 | UInt32(d[2]) << 16 | UInt32(d[3]) << 8 | UInt32(d[4])
                    try await c.send(0x682, [0xB1])
                case 0xB2: serial.replaceSubrange(0..<7, with: d[1..<8])
                case 0xB3:
                    serial[7] = d[1]; info.serial = serial
                    if let (m, n) = ECUModel.from(serialByte: serial[0]) { info.model = m; info.node = n }
                    break loop
                default: break
                }
            }
            c.info = info; c.node = info.node
            return info
        }
    }

    /// Calibration-key unlock, bridge version 7 only. Default key is the app's default 888888.
    public func unlock(key: UInt32 = 888_888) async throws -> Bool {
        try await transaction { c in
            let r = try await c.exchange(0x680, [0x88, 0x00, UInt8(key >> 16 & 0xFF), UInt8(key >> 8 & 0xFF), UInt8(key & 0xFF)]) { $0.id == 0x6A0 }
            return r.data.count >= 2 && r.data[0] == 0x89 && r.data[1] == 0
        }
    }

    /// NMT start (CAN id 0, [01 00]). Moves the ECU to operational; required before the live stream.
    public func nmtStart() async throws { try await send(0x000, [0x01, 0x00]) }

    // MARK: SDO (§5)

    private var req: UInt32 { 0x600 + UInt32(node ?? 0) }
    private var rsp: UInt32 { 0x580 + UInt32(node ?? 0) }

    /// Expedited read (≤4 bytes). A bigger object returns `.big(size:)` after releasing the segmented offer.
    public func probe(_ index: UInt16, _ sub: UInt8 = 0) async throws -> ProbeResult {
        guard node != nil else { throw SDOError.notConnected }
        return try await transaction { c in try await c.probeUnlocked(index, sub) }
    }
    private func probeUnlocked(_ index: UInt16, _ sub: UInt8) async throws -> ProbeResult {
        let r = rsp
        let f = try await exchange(req, [0x40, index.lo, index.hi, sub]) { $0.id == r && sdoMatches($0, index, sub) }
        return try await interpretProbe(f.data, index, sub)
    }
    private func interpretProbe(_ d: [UInt8], _ index: UInt16, _ sub: UInt8) async throws -> ProbeResult {
        let b0 = d[0]
        if b0 == 0x80 { return .error(SDOError.from(abortData: d)) }
        guard b0 >> 5 == 2 else { return .error(.unexpected(d)) }
        if b0 & 2 != 0 {
            let n = b0 & 1 != 0 ? Int(b0 >> 2 & 3) : 0
            return .value(Array(d[4..<(8 - n)]))
        }
        let size = b0 & 1 != 0 ? Int(Array(d[4..<8]).uintLE) : 0
        try await send(req, [0x80, index.lo, index.hi, sub])          // release the segmented offer (ECU stays silent)
        return .big(size: size)
    }

    /// Read any object: expedited, or block upload when the ECU declares more than 4 bytes.
    public func read(_ index: UInt16, _ sub: UInt8 = 0) async throws -> [UInt8] {
        switch try await probe(index, sub) {
        case .value(let v): return v
        case .big(let size): return try await readBlock(index, sub, size: size)
        case .error(let e): throw e
        }
    }

    /// SDO block upload straight to A4 (2 round trips + segments). Verified on hardware 2026-10-21.
    public func readBlock(_ index: UInt16, _ sub: UInt8, size hint: Int = 0) async throws -> [UInt8] {
        guard node != nil else { throw SDOError.notConnected }
        return try await transaction { c in
            do { return try await c.readBlockUnlocked(index, sub, hint) }
            catch let e as SDOError where e == .timeout || e == .busy {
                try? await c.send(c.req, [0x80, index.lo, index.hi, sub]); throw e
            }
        }
    }
    private func readBlockUnlocked(_ index: UInt16, _ sub: UInt8, _ hint: Int) async throws -> [UInt8] {
        let r = rsp
        let initR = try await exchange(req, [0xA4, index.lo, index.hi, sub, 0x7F, 0x00]) { $0.id == r && sdoMatches($0, index, sub) }
        if initR.data[0] == 0x80 { throw SDOError.from(abortData: initR.data) }
        guard initR.data[0] >> 5 == 6 else { throw SDOError.unexpected(initR.data) }
        var size = hint
        if initR.data[0] & 2 != 0 { size = Int(Array(initR.data[4..<8]).uintLE) }
        try await send(req, [0xA3])
        var segs: [[UInt8]] = []; var seq = 0
        while true {
            let f = try await waitFrame(timeout: .seconds(2)) { $0.id == r }
            if f.data[0] == 0x80 { throw SDOError.from(abortData: f.data) }
            segs.append(Array(f.data.dropFirst())); seq += 1
            if f.data[0] & 0x80 != 0 { break }
            if seq == 127 { try await send(req, [0xA2, 127, 0x7F]); seq = 0 }
        }
        // end response carries no index on this ECU (e.g. D9 00 00 …): match by command specifier
        let end = try await exchange(req, [0xA2, UInt8(seq), 0x7F]) { $0.id == r && ($0.data[0] >> 5 == 6 && $0.data[0] & 3 == 1 || $0.data[0] == 0x80) }
        if end.data[0] == 0x80 { throw SDOError.from(abortData: end.data) }
        let pad = Int(end.data[0] >> 2 & 7)
        try await send(req, [0xA1])
        var data = segs.flatMap { $0 }
        data.removeLast(min(pad, data.count))
        if size > 0 && data.count > size { data.removeLast(data.count - size) }
        return data
    }

    /// SDO BLOCK DOWNLOAD — writes >4 bytes to an object (e.g. a table row). Verified against
    /// l1/d.java states 208→209→210. Caller is responsible for backup + readback verification.
    public func writeBlock(_ index: UInt16, _ sub: UInt8, _ data: [UInt8]) async throws {
        guard node != nil else { throw SDOError.notConnected }
        try await transaction { c in try await c.writeBlockUnlocked(index, sub, data) }
    }
    private func writeBlockUnlocked(_ index: UInt16, _ sub: UInt8, _ data: [UInt8]) async throws {
        let r = rsp
        let n = (data.count + 6) / 7
        // 1. initiate: 0xC6, index, sub, size (LE32)
        let size = (0..<4).map { UInt8(UInt32(data.count) >> (8 * UInt32($0)) & 0xFF) }
        let initR = try await exchange(req, [0xC6, index.lo, index.hi, sub] + size, timeout: .seconds(2)) { $0.id == r }
        if initR.data[0] == 0x80 { throw SDOError.from(abortData: initR.data) }
        guard Int(initR.data[4]) >= n else { throw SDOError.unexpected(initR.data) }   // block size must hold all segments
        // 2. send all segments: [seq(1..n), 7 data bytes]
        for i in 0..<n {
            var chunk = Array(data[(i * 7)..<min((i + 1) * 7, data.count)])
            while chunk.count < 7 { chunk.append(0) }
            try await send(req, [UInt8(i + 1)] + chunk)
        }
        // 3. ack: (b0 & 3)==2 and byte1 == segment count
        let ack = try await waitFrame(timeout: .seconds(2)) { $0.id == r }
        if ack.data[0] == 0x80 { throw SDOError.from(abortData: ack.data) }
        guard ack.data[0] & 3 == 2, ack.data[1] == UInt8(n) else { throw SDOError.unexpected(ack.data) }
        // 4. end: 0xC1 | (pad << 2), reply (b0 & 3)==1
        let pad = (7 - data.count % 7) % 7
        let end = try await exchange(req, [UInt8(0xC1 | (pad << 2))], timeout: .seconds(2)) { $0.id == r }
        if end.data[0] == 0x80 { throw SDOError.from(abortData: end.data) }
        guard end.data[0] & 3 == 1 else { throw SDOError.unexpected(end.data) }
    }

        /// Expedited write (1–4 bytes). The app writes these on every connect (stream on/off, mapping);
    /// anything else must be confirmed by the user first - this client never decides to write on its own.
    public func write(_ index: UInt16, _ sub: UInt8, _ value: UInt32, size: Int) async throws {
        precondition((1...4).contains(size))
        guard node != nil else { throw SDOError.notConnected }
        try await transaction { c in
            let r = c.rsp
            let cs = UInt8(0x23 | ((4 - size) << 2))
            let payload = (0..<4).map { UInt8(value >> (8 * UInt32($0)) & 0xFF) }
            let f = try await c.exchange(c.req, [cs, index.lo, index.hi, sub] + payload) { $0.id == r && sdoMatches($0, index, sub) }
            if f.data[0] == 0x80 { throw SDOError.from(abortData: f.data) }
            guard f.data[0] >> 5 == 3 else { throw SDOError.unexpected(f.data) }
        }
    }

    /// Pipelined expedited reads: keeps `window` requests in flight. Busy answers are retried.
    public func probeMany(_ keys: [(UInt16, UInt8)], window: Int = 16) async throws -> [UInt32: ProbeResult] {
        guard node != nil else { throw SDOError.notConnected }
        return try await transaction { c in try await c.probeManyUnlocked(keys, window) }
    }
    private func probeManyUnlocked(_ keys: [(UInt16, UInt8)], _ window: Int) async throws -> [UInt32: ProbeResult] {
        var results: [UInt32: ProbeResult] = [:]
        var queue = keys; var busyTries: [UInt32: Int] = [:]
        var inflight: [(UInt32, Pending)] = []
        let r = rsp
        func key(_ i: UInt16, _ s: UInt8) -> UInt32 { UInt32(i) << 8 | UInt32(s) }
        while !queue.isEmpty || !inflight.isEmpty {
            while !queue.isEmpty && inflight.count < window {
                let (i, s) = queue.removeFirst()
                inflight.append((key(i, s), expect(timeout: .seconds(1)) { $0.id == r && sdoMatches($0, i, s) }))
                try await send(req, [0x40, i.lo, i.hi, s])
            }
            let (k, p) = inflight.removeFirst()                // ECU answers in order
            let (i, s) = (UInt16(k >> 8), UInt8(k & 0xFF))
            do {
                let res = try await interpretProbe(try await result(p).data, i, s)
                if case .error(.busy) = res {
                    if inflight.count < window / 2 { busyTries[k, default: 0] += 1 }
                    if busyTries[k, default: 0] < 3 { queue.append((i, s)) } else { results[k] = res }
                } else { results[k] = res }
            } catch SDOError.timeout {
                busyTries[k, default: 0] += 1
                if busyTries[k]! < 3 { queue.insert((i, s), at: 0) } else { results[k] = .error(.timeout) }
            }
        }
        return results
    }

    /// Pipelined read of sub-0 of many variable indices → index: little-endian value (expedited only).
    public func readVariableWord(_ indices: [UInt16], window: Int = 24) async throws -> [UInt16: Int] {
        let res = try await probeMany(indices.map { ($0, 0) }, window: window)
        var out: [UInt16: Int] = [:]
        for (key, r) in res {
            if case .value(let bytes) = r { out[UInt16(key >> 8)] = Int(bytes.uintLE) }
        }
        return out
    }

    // MARK: identity (§6)

    public func readIdentity() async throws -> ECUIdentity {
        var id = ECUIdentity()
        func u32(_ sub: UInt8) async throws -> UInt32 { (try? await read(0x1018, sub).uintLE) ?? 0 }
        id.productCode = try await u32(2); id.tableID = try await u32(5)
        id.verV = UInt16(try await u32(6)); id.verS = UInt16(try await u32(7)); id.verC = UInt16(try await u32(8)); id.verA = UInt16(try await u32(9))
        id.ecuSerial = (try? await read(0x1018, 0x0A)) ?? []
        id.ownedFunctions = try await u32(0x0B); id.trialFunctions = try await u32(0x0C)
        id.factoryFunctions = try await u32(0x0D); id.orderSerial = try await u32(0x0E)
        id.deviceName = String(decoding: (try? await read(0x1008, 0)) ?? [], as: UTF8.self)
        return id
    }

    // MARK: live stream (§7)

    /// Write the TPDO1 mapping and start streaming, exactly in the app's order.
    public func startStream(_ slots: [StreamSlot]) async throws {
        precondition(slots.count <= 64)
        try await write(0x1800, 5, 0, size: 2)
        try await write(0x1A00, 0, 0, size: 1)
        for (n, s) in slots.enumerated() { try await write(0x1A00, UInt8(n + 1), s.mappingWord, size: 4) }
        try await write(0x1A00, 0, UInt32(slots.count), size: 1)
        streamDecoder = StreamDecoder(slots: slots)
        try await write(0x1800, 5, 64, size: 2)
    }

    public func stopStream() async throws { try await write(0x1800, 5, 0, size: 2) }

    /// Full connect sequence as the app does it: identify → unlock → NMT start → identity.
    public func connectSequence(key: UInt32 = 888_888) async throws -> (BridgeInfo, ECUIdentity) {
        start()
        let info = try await identify()
        guard info.node != nil else { throw SDOError.notConnected }
        if info.bridgeVersion == 7 { _ = try await unlock(key: key) }
        try await nmtStart()
        let ident = try await readIdentity()
        return (info, ident)
    }
}

/// True when an SDO reply carries this index/sub in bytes 1–3.
@inline(__always) func sdoMatches(_ f: CANFrame, _ index: UInt16, _ sub: UInt8) -> Bool {
    f.data.count >= 4 && f.data[1] == index.lo && f.data[2] == index.hi && f.data[3] == sub
}
