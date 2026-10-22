import SwiftUI
import SwiftData

/// Road-dyno tab: full-throttle pulls detected automatically, torque-proxy curve per RPM,
/// and a before/after comparison between the two latest pulls.
public struct DynoView: View {
    let session: ECUSession
    @Environment(\.modelContext) private var context
    public init(session: ECUSession) { self.session = session }
    private var d: DynoEngine { session.dyno }

    public var body: some View {
        ZStack {
            Theme.Palette.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    status
                    if let latest = d.pulls.first {
                        Text("Latest pull · torque proxy (rpm/s per RPM)").eyebrow()
                        AccelChart(curve: latest.curve).frame(height: 160).card(padding: Theme.Space.md)
                        if d.pulls.count >= 2 { comparison(latest, d.pulls[1]) }
                    } else {
                        Text("Hold full throttle in one gear on flat road. Pulls are detected automatically.")
                            .font(.caption).foregroundStyle(Theme.Palette.textDim)
                    }
                    pullList
                }
                .padding(Theme.Space.lg)
            }
        }
    }

    private var status: some View {
        HStack {
            Circle().fill(d.inPull ? Theme.Palette.bad : Theme.Palette.textFaint).frame(width: 10, height: 10)
            Text(d.inPull ? "Recording pull · \(d.livePullSamples) samples" : "Waiting for full throttle · TPS max seen \(d.tpsMaxSeen)")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text)
            Spacer()
            Button("Save", systemImage: "externaldrive.fill.badge.plus", action: savePulls)
                .buttonStyle(.bordered).tint(Theme.Palette.accent).disabled(d.pulls.isEmpty)
            Button("Clear") { d.clear() }.buttonStyle(.bordered).tint(Theme.Palette.textDim).disabled(d.pulls.isEmpty)
        }
        .card(padding: Theme.Space.md)
    }

    private func comparison(_ a: DynoEngine.Pull, _ b: DynoEngine.Pull) -> some View {
        let diffs = DynoEngine.compare(a, b)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Latest vs previous · \(a.mapLabel) vs \(b.mapLabel)").eyebrow()
            if diffs.isEmpty {
                Text("No overlapping RPM bins yet.").font(.caption).foregroundStyle(Theme.Palette.textDim)
            } else {
                ForEach(diffs, id: \.rpm) { x in
                    HStack {
                        Text("\(x.rpm)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Palette.textDim).frame(width: 56, alignment: .leading)
                        Text(String(format: "%+.1f%%", x.pct)).font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(x.pct > 1 ? Theme.Palette.good : x.pct < -1 ? Theme.Palette.bad : Theme.Palette.textDim)
                        Spacer()
                    }
                }
                let mean = diffs.map(\.pct).reduce(0, +) / Double(diffs.count)
                Text(String(format: "Overall %+.1f%% · %@", mean, mean > 1 ? "better" : mean < -1 ? "worse" : "no clear change"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(mean > 1 ? Theme.Palette.good : mean < -1 ? Theme.Palette.bad : Theme.Palette.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var pullList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Pulls").eyebrow()
            ForEach(d.pulls) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.rpmStart) → \(p.rpmEnd) rpm · \(p.duration, format: .number.precision(.fractionLength(1)))s")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Palette.text)
                        Text("map \(p.mapLabel)" + (p.gear.map { " · gear \($0)" } ?? "") + (p.gearRatio.map { String(format: " · ratio %.3f", $0) } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(Theme.Palette.textDim)
                    }
                    Spacer()
                    if let mx = p.maxAFR {
                        Text(String(format: "AFR %.1f–%.1f", p.minAFR ?? 0, mx)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(mx > DynoEngine.leanLimitWOT ? Theme.Palette.bad : Theme.Palette.textDim)
                    }
                }
                .padding(Theme.Space.md).background(Theme.Palette.surface, in: .rect(cornerRadius: Theme.Radius.sm))
            }
        }
    }

    private func savePulls() {
        let enc = JSONEncoder()
        for p in d.pulls {
            context.insert(AccelPull(at: p.startedAt, duration: p.duration, rpmStart: p.rpmStart, rpmEnd: p.rpmEnd,
                                     gearRatio: p.gearRatio ?? 0, minAFR: p.minAFR ?? 0, maxAFR: p.maxAFR ?? 0,
                                     mapLabel: p.mapLabel, curveJSON: (try? enc.encode(p.curve)) ?? Data()))
        }
        try? context.save()
    }
}

/// Bar chart of torque proxy per RPM bin.
struct AccelChart: View {
    let curve: [DynoEngine.BinAccel]
    var body: some View {
        GeometryReader { g in
            let maxA = max(curve.map(\.accel).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(curve) { b in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.Palette.accent.opacity(0.85))
                            .frame(height: max(4, g.size.height * 0.78 * CGFloat(b.accel / maxA)))
                        Text("\(b.rpm / 1000)k").font(.system(size: 9)).foregroundStyle(Theme.Palette.textFaint)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
