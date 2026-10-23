import Foundation

/// Road-dyno: detects full-throttle acceleration pulls from the live stream, records them in
/// detail, and turns each into a torque-proxy curve (dRPM/dt per RPM bin, in a fixed gear).
/// Comparing a pull before vs after a fuel change tells whether the change helped or hurt.
/// AFR is recorded as a SAFETY guard (lean warnings), not as the optimisation target.
@MainActor @Observable
public final class DynoEngine {
    public struct Sample: Sendable, Codable { public let t: Double; public let rpm: Int; public let tps: Int; public let vss: Int; public let afr: Double?; public var gear: Int? = nil }
    public struct BinAccel: Sendable, Codable, Identifiable { public let rpm: Int; public let accel: Double; public let n: Int; public var id: Int { rpm } }
    public struct Pull: Sendable, Identifiable, Codable {
        public let id: UUID
        public let startedAt: Date
        public let duration: Double
        public let rpmStart: Int, rpmEnd: Int
        public let gearRatio: Double?          // mean vss/rpm, groups pulls by gear once VSS is confirmed
        public let curve: [BinAccel]           // torque proxy: rpm/s per RPM bin
        public let minAFR: Double?, maxAFR: Double?
        public let sampleCount: Int
        public let mapLabel: String            // which fuel-map revision was active
        public var gear: Int? = nil            // gear position (id130 candidate) — pulls compare within one gear
    }

    public private(set) var pulls: [Pull] = [] { didSet { refreshDerived() } }   // newest first, bounded
    public static let maxPulls = 300
    /// Derived once per pulls change (not per view render): distinct labels newest-first, and the
    /// current-vs-previous revision comparison.
    public private(set) var labels: [String] = []
    public private(set) var latestComparison: [LabelComparison] = []
    public private(set) var inPull = false
    public private(set) var livePullSamples = 0
    public var mapLabel = "base"               // set by the editor when a map is written
    @ObservationIgnored public var onPull: ((Pull) -> Void)?   // persistence hook (ECUSession → SwiftData)
    @ObservationIgnored public var onPullSamples: ((Pull, [Sample]) -> Void)?   // raw samples of a finished pull (fusion / replay)
    /// Restore pulls saved in earlier app runs so revision averages survive restarts.
    public func load(_ saved: [Pull]) { pulls = Array(saved.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxPulls)) }
    public static func makePull(startedAt: Date, duration: Double, rpmStart: Int, rpmEnd: Int, gearRatio: Double?, curve: [BinAccel], minAFR: Double?, maxAFR: Double?, sampleCount: Int, mapLabel: String, gear: Int? = nil) -> Pull {
        Pull(id: UUID(), startedAt: startedAt, duration: duration, rpmStart: rpmStart, rpmEnd: rpmEnd, gearRatio: gearRatio, curve: curve, minAFR: minAFR, maxAFR: maxAFR, sampleCount: sampleCount, mapLabel: mapLabel, gear: gear)
    }

    // Detection thresholds
    public var tpsThreshold = 70               // used only until a session max is learned
    public private(set) var tpsMaxSeen = 0     // id369 full-scale is not necessarily 100; learn it
    /// A pull = throttle at ≥85% of the largest TPS seen this session (min 20 so idle never counts).
    private var pullThreshold: Int { max(20, Int(Double(tpsMaxSeen) * 0.85)) }
    public var binRPM = 500
    private let minSamples = 12
    private var cur: [Sample] = []
    private var lastRPM = 0

    public init() {}

    public func ingest(_ values: [UInt32], slots: [StreamSlot], at time: Date) {
        func val(_ idx: UInt16) -> Int? {
            guard let i = slots.firstIndex(where: { $0.index == idx }), values.indices.contains(i) else { return nil }
            return Int(values[i])
        }
        guard let rpm = val(0x401A), let tps = val(0x4171) else { return }
        let vss = val(0x4033) ?? 0
        let afr = val(0x4037).map { Double($0) / 100 }
        let gear = val(0x4082)                  // id130 gear position (candidate)
        let t = time.timeIntervalSince1970
        if tps > tpsMaxSeen { tpsMaxSeen = tps }
        let throttleOn = tps >= pullThreshold
        if throttleOn && rpm >= lastRPM - 50 {
            if !inPull { inPull = true; cur = [] }
            cur.append(Sample(t: t, rpm: rpm, tps: tps, vss: vss, afr: afr, gear: gear))
            livePullSamples = cur.count
        } else if inPull {
            finishPull()
        }
        lastRPM = rpm
    }

    private func finishPull() {
        inPull = false; livePullSamples = 0
        defer { cur = [] }
        guard cur.count >= minSamples, let f = cur.first, let l = cur.last, l.rpm > f.rpm + 800 else { return }
        // dRPM/dt via central differences, then average per RPM bin
        var accum: [Int: (sum: Double, n: Int)] = [:]
        for i in 1..<cur.count - 1 {
            let dt = cur[i + 1].t - cur[i - 1].t
            guard dt > 0 else { continue }
            let a = Double(cur[i + 1].rpm - cur[i - 1].rpm) / dt
            let bin = (cur[i].rpm / binRPM) * binRPM
            accum[bin, default: (0, 0)].sum += a; accum[bin]!.n += 1
        }
        let curve = accum.keys.sorted().map { BinAccel(rpm: $0, accel: accum[$0]!.sum / Double(accum[$0]!.n), n: accum[$0]!.n) }
        let ratios = cur.filter { $0.vss > 0 && $0.rpm > 0 }.map { Double($0.vss) / Double($0.rpm) }
        let ratio = ratios.isEmpty ? nil : ratios.reduce(0, +) / Double(ratios.count)
        let afrs = cur.compactMap(\.afr)
        // gear = the mode of the samples' gear readings (nil when the variable isn't streamed)
        let gears = cur.compactMap(\.gear).filter { $0 > 0 }
        let gear = gears.isEmpty ? nil : Dictionary(gears.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }!.key
        let pull = Pull(id: UUID(), startedAt: Date(timeIntervalSince1970: f.t), duration: l.t - f.t,
                        rpmStart: f.rpm, rpmEnd: l.rpm, gearRatio: ratio, curve: curve,
                        minAFR: afrs.min(), maxAFR: afrs.max(), sampleCount: cur.count, mapLabel: mapLabel, gear: gear)
        pulls.insert(pull, at: 0)
        if pulls.count > Self.maxPulls { pulls.removeLast() }
        onPull?(pull)
        onPullSamples?(pull, cur)
    }

    /// Per-bin accel delta of `a` vs `b` (positive = a stronger). Only bins both have.
    public static func compare(_ a: Pull, _ b: Pull) -> [(rpm: Int, delta: Double, pct: Double)] {
        let bb = Dictionary(uniqueKeysWithValues: b.curve.map { ($0.rpm, $0.accel) })
        return a.curve.compactMap { x in
            guard let y = bb[x.rpm], y != 0 else { return nil }
            return (x.rpm, x.accel - y, (x.accel - y) / abs(y) * 100)
        }
    }

    /// Mean torque-proxy curve across ALL pulls with this map label, with per-bin spread (std).
    public func averagedCurve(label: String, gear: Int? = nil) -> [(rpm: Int, mean: Double, std: Double, n: Int)] {
        let group = pulls.filter { $0.mapLabel == label && (gear == nil || $0.gear == gear) }
        var acc: [Int: [Double]] = [:]
        for p in group { for b in p.curve { acc[b.rpm, default: []].append(b.accel) } }
        return acc.keys.sorted().map { k in
            let xs = acc[k]!; let m = xs.reduce(0, +) / Double(xs.count)
            let v = xs.count > 1 ? xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1) : 0
            return (k, m, v.squareRoot(), xs.count)
        }
    }

    public struct LabelComparison: Sendable { public let rpm: Int; public let pct: Double; public let significant: Bool; public let nA: Int; public let nB: Int }
    /// Compare two map revisions using all their pulls. `significant` = the gap exceeds the pull-to-pull noise.
    public func compare(label a: String, with b: String, gear: Int? = nil) -> [LabelComparison] {
        let ca = averagedCurve(label: a, gear: gear), cb = Dictionary(uniqueKeysWithValues: averagedCurve(label: b, gear: gear).map { ($0.rpm, $0) })
        return ca.compactMap { x in
            guard let y = cb[x.rpm], y.mean != 0 else { return nil }
            let pct = (x.mean - y.mean) / abs(y.mean) * 100
            let noise = (x.std + y.std) / abs(y.mean) * 100                // combined spread, in percent
            return LabelComparison(rpm: x.rpm, pct: pct, significant: abs(pct) > max(noise, 1.5), nA: x.n, nB: y.n)
        }
    }
    private func refreshDerived() {
        var seen = Set<String>(); var ls: [String] = []
        for p in pulls where seen.insert(p.mapLabel).inserted { ls.append(p.mapLabel) }
        labels = ls
        // compare within the gear of the newest pull when gear is known — dRPM/dt is only comparable in one gear
        latestComparison = ls.count >= 2 ? compare(label: ls[0], with: ls[1], gear: pulls.first?.gear) : []
    }

    /// Lean-danger check for a pull at high load (AFR above this at WOT risks detonation).
    public static let leanLimitWOT = 13.6
    public func clear() { pulls.removeAll() }
}
