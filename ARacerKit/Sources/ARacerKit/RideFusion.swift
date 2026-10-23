import Foundation

/// Fuse watch data (FIT: barometric altitude, GPS) with ECU pulls:
///  · road grade during each pull (the biggest confound of a road dyno) and the slope-corrected curve
///  · GPS speed vs ECU VSS (confirms the Speed scale without looking at the speedometer)
///  · a segment id per pull (same start point + same heading) so only like-for-like pulls are compared
public enum RideFusion {
    public struct PullContext: Sendable {
        public let pullID: UUID
        public let grade: Double?            // %, + = uphill, from barometric altitude over the pull
        public let gpsSpeedMean: Double?     // km/h
        public let vssMean: Double?          // km/h, app scale (raw/256)
        public let segment: String?          // "lat,lon@bearing" bucket
        public let corrected: [DynoEngine.BinAccel]   // curve with g·sinθ added back, in rpm/s
        public let samples: Int
    }

    static let g = 9.80665

    /// `offset` = seconds to add to FIT times to align with the phone clock (both are GPS/NTP-synced; usually 0).
    public static func annotate(pulls: [DynoEngine.Pull], rawSamples: [[DynoEngine.Sample]], fit: [FITReader.Sample], offset: TimeInterval = 0) -> [PullContext] {
        let means = rawSamples.map { raw -> (Double, Double) in
            raw.isEmpty ? (0, 0) : (raw.map { Double($0.rpm) }.reduce(0, +) / Double(raw.count), raw.map { Double($0.vss) / 256 }.reduce(0, +) / Double(raw.count))
        }
        return annotate(pulls: pulls, means: means, fit: fit, offset: offset)
    }
    /// Stored pulls carry their own means — no raw samples needed.
    public static func annotate(pulls: [DynoEngine.Pull], fit: [FITReader.Sample], offset: TimeInterval = 0) -> [PullContext] {
        annotate(pulls: pulls, means: pulls.map { ($0.meanRPM, $0.meanVSS) }, fit: fit, offset: offset)
    }

    static func annotate(pulls: [DynoEngine.Pull], means: [(rpm: Double, vss: Double)], fit: [FITReader.Sample], offset: TimeInterval) -> [PullContext] {
        guard !fit.isEmpty else { return [] }
        let times = fit.map { $0.time.timeIntervalSince1970 + offset }
        return zip(pulls, means).map { pull, m in
            let t0 = pull.startedAt.timeIntervalSince1970, t1 = t0 + pull.duration
            // FIT samples inside the pull, plus one on each side so a short pull still has two points
            var lo = times.firstIndex { $0 >= t0 } ?? times.count, hi = times.lastIndex { $0 <= t1 } ?? -1
            lo = max(0, lo - 1); hi = min(times.count - 1, hi + 1)
            guard lo <= hi else { return PullContext(pullID: pull.id, grade: nil, gpsSpeedMean: nil, vssMean: nil, segment: nil, corrected: pull.curve, samples: 0) }
            let win = Array(fit[lo...hi])
            // grade = Δaltitude / Δdistance (barometer over GPS distance); fall back to the device's own grade field
            var grade: Double?
            if let a0 = win.first?.altitude, let a1 = win.last?.altitude, let d0 = win.first?.distance, let d1 = win.last?.distance, d1 - d0 > 20 {
                grade = (a1 - a0) / (d1 - d0) * 100
            } else {
                let gs = win.compactMap(\.grade); if !gs.isEmpty { grade = gs.reduce(0, +) / Double(gs.count) }
            }
            let sp = win.compactMap(\.speed)
            let gps = sp.isEmpty ? nil : sp.reduce(0, +) / Double(sp.count) * 3.6
            let vss: Double? = m.vss > 0 ? m.vss : nil
            // slope correction in rpm/s: a_true = a_meas + g·sinθ · (rpm per m/s in this gear)
            var corrected = pull.curve
            if let grade, let gps, gps > 5, m.rpm > 0 {
                let theta = atan(grade / 100)
                let rpmPerMps = m.rpm / (gps / 3.6)
                corrected = pull.curve.map { DynoEngine.BinAccel(rpm: $0.rpm, accel: $0.accel + g * sin(theta) * rpmPerMps, n: $0.n) }
            }
            var segment: String?
            if let s = win.first, let e = win.last, let la0 = s.lat, let lo0 = s.lon, let la1 = e.lat, let lo1 = e.lon {
                let bearing = (atan2(sin((lo1 - lo0) * .pi / 180) * cos(la1 * .pi / 180),
                                     cos(la0 * .pi / 180) * sin(la1 * .pi / 180) - sin(la0 * .pi / 180) * cos(la1 * .pi / 180) * cos((lo1 - lo0) * .pi / 180)) * 180 / .pi + 360)
                    .truncatingRemainder(dividingBy: 360)
                // ~150 m buckets (0.0015° ≈ 165 m) and 45° heading buckets
                segment = String(format: "%.4f,%.4f@%d", (la0 / 0.0015).rounded() * 0.0015, (lo0 / 0.0015).rounded() * 0.0015, Int(bearing / 45) * 45)
            }
            return PullContext(pullID: pull.id, grade: grade.map { ($0 * 10).rounded() / 10 }, gpsSpeedMean: gps, vssMean: vss, segment: segment, corrected: corrected, samples: win.count)
        }
    }
}
