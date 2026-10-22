import SwiftUI

/// Tiny heat-map thumbnail of a grid table (one Canvas, no per-cell views).
struct MiniHeatmap: View {
    let rows: [[Double]]
    var body: some View {
        Canvas { ctx, size in
            guard let w = rows.first?.count, w > 0 else { return }
            let flat = rows.flatMap { $0 }
            let lo = flat.min() ?? 0, hi = flat.max() ?? 1, span = max(hi - lo, 1e-9)
            let cw = size.width / CGFloat(w), ch = size.height / CGFloat(rows.count)
            for (r, row) in rows.enumerated() {
                for (c, v) in row.enumerated() {
                    let rect = CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch, width: cw + 0.5, height: ch + 0.5)
                    ctx.fill(Path(rect), with: .color(Theme.heat((v - lo) / span)))
                }
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Palette.borderHi, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Small bar strip for a 1-D vector table.
struct MiniBars: View {
    let values: [Double]
    var body: some View {
        Canvas { ctx, size in
            guard !values.isEmpty else { return }
            let lo = values.min() ?? 0, hi = values.max() ?? 1, span = max(hi - lo, 1e-9)
            let bw = size.width / CGFloat(values.count)
            for (i, v) in values.enumerated() {
                let f = (v - lo) / span
                let h = max(2, size.height * (0.25 + 0.75 * f))
                let rect = CGRect(x: CGFloat(i) * bw + 1, y: size.height - h, width: bw - 2, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Theme.heat(f)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Full-width bar chart for a vector table with its values labelled.
struct VectorBars: View {
    let values: [Double]
    let decimals: Int
    let unit: String
    var body: some View {
        let lo = values.min() ?? 0, hi = values.max() ?? 1, span = max(hi - lo, 1e-9)
        HStack(alignment: .bottom, spacing: Theme.Space.xs) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                VStack(spacing: 4) {
                    Text(v, format: .number.precision(.fractionLength(decimals)))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Palette.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.heat((v - lo) / span))
                        .frame(height: 24 + 96 * ((v - lo) / span))
                    Text("\(i)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.Palette.textFaint)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
