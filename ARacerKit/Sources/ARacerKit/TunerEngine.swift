import Foundation

/// On-connect copilot core: learns an AFR-error / fuel-correction map per RPM×TPS cell while riding.
/// Advisory only — never writes to the ECU. Correction = mean(AFR_actual / AFR_target) − 1 (positive = add fuel).
@MainActor @Observable
public final class TunerEngine {
    public struct Cell: Sendable, Equatable {
        public var count = 0
        public var ratioSum = 0.0
        public var ratioSumSq = 0.0
        public var afrSum = 0.0
        /// Mean measured AFR in this cell (absolute, for the lean guard).
        public var meanAFR: Double? { count > 0 ? afrSum / Double(count) : nil }
        /// Mean AFR_actual/AFR_target − 1, in percent; nil if never visited.
        public var correctionPct: Double? { count > 0 ? (ratioSum / Double(count) - 1) * 100 : nil }
        /// Spread of the ratio (percent). Large = noisy cell, trust less.
        public var stdPct: Double? {
            guard count > 1 else { return nil }
            let m = ratioSum / Double(count); let v = max(0, ratioSumSq / Double(count) - m * m)
            return v.squareRoot() * 100
        }
        /// 0…1 confidence from sample count (saturates at 30).
        public var confidence: Double { min(Double(count) / 30, 1) }
    }

    // Reuse the confirmed fuel-adjust axes (TPS rows × RPM cols).
    public let tps = Axes.byID[4]?.tps ?? [0, 2, 4, 6, 8, 10, 15, 20, 25, 30, 40]
    public let rpm = Axes.byID[4]?.rpm ?? [800, 1600, 2400, 3200, 4000, 4800]

    public private(set) var cells: [[Cell]]
    public private(set) var liveRPM: Int?
    public private(set) var liveTPS: Int?
    public private(set) var liveAFR: Double?
    public private(set) var liveTarget: Double?
    public private(set) var liveTemp: Int?
    public private(set) var active: (row: Int, col: Int)?
    public private(set) var samplesLearned = 0
    public private(set) var rejectedTransient = 0
    private var recent: [(rpm: Int, tps: Int)] = []     // short history for steady-state + lag alignment
    private let lagSamples = 2                          // ~125 ms at 16 Hz: AFR lags the cell it belongs to
    private let steadyWindow = 5                        // ~300 ms of stable throttle required

    public var warm: Bool { (liveTemp ?? 0) >= 50 }
    public var error: Double? { if let a = liveAFR, let t = liveTarget { a - t } else { nil } }

    public init() {
        cells = Array(repeating: Array(repeating: Cell(), count: rpm.count), count: tps.count)
    }

    public func reset() {
        cells = Array(repeating: Array(repeating: Cell(), count: rpm.count), count: tps.count)
        samplesLearned = 0
    }

    /// Feed one live sample (values in `slots` order).
    public func ingest(_ values: [UInt32], slots: [StreamSlot]) {
        func val(_ index: UInt16) -> Int? {
            guard let i = slots.firstIndex(where: { $0.index == index }), values.indices.contains(i) else { return nil }
            return Int(values[i])
        }
        liveRPM = val(0x401A)                 // RPM id26
        liveTPS = val(0x4171)                 // TPS id369
        liveTemp = val(0x4021)                // T_Eng id33
        if let a = val(0x4037) { liveAFR = Double(a) / 100 }     // AFR id55
        if let t = val(0x4306) { liveTarget = Double(t) / 100 }  // AFR Target id774

        guard warm, let r = liveRPM, let tp = liveTPS,
              let afr = liveAFR, let tgt = liveTarget,
              afr >= 9, afr <= 22, tgt >= 9, tgt <= 20, tgt > 0 else { active = nil; return }
        recent.append((r, tp)); if recent.count > steadyWindow + lagSamples { recent.removeFirst() }   // fixed 7-element window: O(1)
        // steady-state gate: throttle stable (±2) over the window and RPM not jumping → no accel/decel transient
        let window = recent.suffix(steadyWindow)
        guard window.count == steadyWindow,
              (window.map(\.tps).max()! - window.map(\.tps).min()!) <= 2,
              (window.map(\.rpm).max()! - window.map(\.rpm).min()!) <= 400 else { rejectedTransient += 1; active = nil; return }
        // lag alignment: bin the AFR to the cell from ~125 ms earlier
        let src = recent.count > lagSamples ? recent[recent.count - 1 - lagSamples] : recent.last!
        let row = nearest(src.tps, tps), col = nearest(src.rpm, rpm)
        // outlier rejection: skip readings >25% away from the cell's running mean once it has data
        let ratio = afr / tgt
        if cells[row][col].count >= 5, let m = Optional(cells[row][col].ratioSum / Double(cells[row][col].count)), abs(ratio - m) / m > 0.25 {
            rejectedTransient += 1; return
        }
        active = (row, col)
        cells[row][col].count += 1
        cells[row][col].ratioSum += ratio
        cells[row][col].ratioSumSq += ratio * ratio
        cells[row][col].afrSum += afr
        samplesLearned += 1
    }

    public func correctionMap() -> [[Double?]] { cells.map { $0.map { $0.correctionPct } } }
    public func sampleCounts() -> [[Int]] { cells.map { $0.map { $0.count } } }
    public var meanAbsError: Double {
        let vals = cells.flatMap { $0.compactMap { $0.correctionPct } }
        return vals.isEmpty ? 0 : vals.map { abs($0) }.reduce(0, +) / Double(vals.count)
    }

    private func nearest(_ v: Int, _ axis: [Int]) -> Int {
        var best = 0, bd = Int.max
        for (i, a) in axis.enumerated() { let d = abs(a - v); if d < bd { bd = d; best = i } }
        return best
    }
}
