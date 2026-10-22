import SwiftUI

/// A table rendered as a heat-map grid of numbers.
struct GridBody: View {
    let display: [[Double]]
    let decimals: Int

    var body: some View {
        let flat = display.flatMap(\.self)
        let lo = flat.min() ?? 0
        let hi = flat.max() ?? 1
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(display.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        Text(value, format: .number.precision(.fractionLength(decimals)))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 46, height: 26)
                            .background(heat(value, lo, hi), in: .rect(cornerRadius: 4))
                    }
                }
            }
        }
    }

    private func heat(_ v: Double, _ lo: Double, _ hi: Double) -> Color {
        guard hi > lo else { return Theme.Palette.surfaceHi }
        return Theme.heat((v - lo) / (hi - lo))
    }
}
