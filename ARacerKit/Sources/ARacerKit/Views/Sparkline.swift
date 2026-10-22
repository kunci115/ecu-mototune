import SwiftUI

/// A minimal line chart of recent values, normalized to its own min/max. Uses the foreground tint.
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
                let span = max(hi - lo, 1)
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * Double(i) / Double(values.count - 1)
                    let y = geo.size.height * (1 - (v - lo) / span)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
