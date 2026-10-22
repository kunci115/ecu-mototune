import SwiftUI

/// A tuning table drawn like the official app: RPM across the top, TPS down the left,
/// heat-mapped cells. `rows` is already cropped to tps.count × rpm.count.
struct AxisGrid: View {
    let rows: [[Double]]
    let decimals: Int
    let tps: [Int]
    let rpm: [Int]
    var confirmed: Bool = true

    private let cellW: CGFloat = 52
    private let cellH: CGFloat = 28

    var body: some View {
        let flat = rows.flatMap(\.self)
        let lo = flat.min() ?? 0, hi = flat.max() ?? 1
        ScrollView([.horizontal, .vertical]) {
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    corner("TPS\\RPM")
                    ForEach(rpm, id: \.self) { header("\($0)") }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                    GridRow {
                        header(ri < tps.count ? "\(tps[ri])" : "")
                        ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                            Text(v, format: .number.precision(.fractionLength(decimals)))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(width: cellW, height: cellH)
                                .background(heat(v, lo, hi), in: .rect(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }

    private func corner(_ s: String) -> some View {
        VStack(spacing: 0) {
            Text("RPM →").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.Palette.accent)
            Text("TPS ↓").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.Palette.accent)
        }
        .frame(width: cellW, height: cellH).background(Theme.Palette.surfaceHi, in: .rect(cornerRadius: 4))
        .accessibilityLabel("RPM across, TPS down")
    }
    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.Palette.accent)
            .frame(width: cellW, height: cellH).background(Theme.Palette.surfaceHi, in: .rect(cornerRadius: 4))
    }
    private func heat(_ v: Double, _ lo: Double, _ hi: Double) -> Color {
        guard hi > lo else { return Theme.Palette.surfaceHi }
        return Theme.heat((v - lo) / (hi - lo))
    }
}
