import Foundation
#if canImport(Network)
import Network
#endif

/// Byte transport to the bridge. `incoming` ends when the connection is lost.
public protocol Transport: AnyObject, Sendable {
    func send(_ data: Data) async throws
    var incoming: AsyncStream<Data> { get }
    func close()
}

public enum TransportError: Error, Sendable { case closed, timeout, failed(String) }

#if canImport(Network)
/// TCP via Network.framework, pinned to the Wi-Fi interface so the phone keeps using
/// cellular for everything else and never routes ECU traffic over it.
public final class NWTransport: Transport, @unchecked Sendable {
    public static let defaultHost = "192.168.88.88"
    public static let defaultPort: UInt16 = 6666

    private let conn: NWConnection
    private let cont: AsyncStream<Data>.Continuation
    public let incoming: AsyncStream<Data>

    public init(host: String = defaultHost, port: UInt16 = defaultPort, wifiOnly: Bool = true) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        if wifiOnly { params.requiredInterfaceType = .wifi }   // keep cellular free for the internet
        // The ECU bridge Wi-Fi has no internet; do NOT prohibit expensive/constrained paths
        // or iOS leaves the path unsatisfied and the connection hangs in .waiting forever.
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        var c: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { c = $0 }
        cont = c
    }

    /// Resolves once the TCP connection is ready, throws if it fails.
    public func connect(timeout: Duration = .seconds(10)) async throws {
        final class Box: @unchecked Sendable {
            var cont: CheckedContinuation<Void, Error>?
            let once = Once()
        }
        let box = Box()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            box.cont = k
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if box.once.first() { box.cont?.resume() }
                    self?.receiveLoop()
                case .failed(let e):
                    if box.once.first() { box.cont?.resume(throwing: TransportError.failed(e.localizedDescription)) }
                    self?.cont.finish()
                case .cancelled:
                    if box.once.first() { box.cont?.resume(throwing: TransportError.closed) }
                    self?.cont.finish()
                case .waiting(let e):
                    // No usable path yet (e.g. local-network permission pending, or Wi-Fi not joined).
                    // Leave it to the timeout below so we fail and retry instead of hanging.
                    _ = e
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "aracer.nw"))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if box.once.first() {
                    self?.conn.cancel()
                    box.cont?.resume(throwing: TransportError.timeout)
                }
            }
        }
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.cont.yield(data) }
            if isComplete || error != nil { self.cont.finish(); return }
            self.receiveLoop()
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in
                if let e { k.resume(throwing: TransportError.failed(e.localizedDescription)) } else { k.resume() }
            })
        }
    }

    public func close() { conn.cancel(); cont.finish() }
}

private final class Once: @unchecked Sendable {
    private var fired = false; private let lock = NSLock()
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}
#endif

/// In-memory transport for tests: `responder` maps each sent frame to the frames the ECU would answer.
public final class ScriptedTransport: Transport, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    private let responder: @Sendable (CANFrame) -> [CANFrame]
    private var decoder = FrameDecoder()
    public private(set) var sent: [CANFrame] = []

    public init(responder: @escaping @Sendable (CANFrame) -> [CANFrame]) {
        var c: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { c = $0 }
        cont = c
        self.responder = responder
    }
    public func send(_ data: Data) async throws {
        for f in decoder.feed(data) {
            sent.append(f)
            for r in responder(f) { cont.yield(r.encoded()) }
        }
    }
    /// Push an unsolicited frame (heartbeat, PDO).
    public func inject(_ f: CANFrame) { cont.yield(f.encoded()) }
    public func close() { cont.finish() }
}
