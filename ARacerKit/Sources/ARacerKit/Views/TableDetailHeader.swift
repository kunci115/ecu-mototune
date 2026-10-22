import SwiftUI

/// Identity card for a table: name, address chips, confidence badge, and the view controls.
struct TableDetailHeader: View {
    let summary: TableSummary
    @Binding var showScaled: Bool
    @Binding var show3D: Bool

    private var isGrid: Bool { if case .grid = summary.shape { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.category.rawValue).eyebrow()
                    Text(summary.name).font(Theme.display(22, .bold)).foregroundStyle(Theme.Palette.text)
                }
                Spacer()
                confidenceBadge
            }
            HStack(spacing: 6) {
                chip("0x" + String(summary.table.index ?? 0, radix: 16, uppercase: true))
                chip(shapeText)
                if let b = summary.table.licence_bit { chip("licence \(b)") }
                if summary.unit != "raw" { chip(summary.unit) }
            }
            if summary.scaling != nil || isGrid {
                HStack(spacing: Theme.Space.sm) {
                    if summary.scaling != nil {
                        Picker("Values", selection: $showScaled) { Text("Scaled").tag(true); Text("Raw").tag(false) }
                            .pickerStyle(.segmented).frame(maxWidth: 160)
                    }
                    if isGrid {
                        Picker("View", selection: $show3D) { Text("Grid").tag(false); Text("3D").tag(true) }
                            .pickerStyle(.segmented).frame(maxWidth: 140)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var shapeText: String {
        switch summary.shape {
        case .scalar: "scalar"
        case .vector(let n): "\(n) pts"
        case .grid(let r, let c): "\(r) × \(c)"
        }
    }
    private func chip(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Palette.textDim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.Palette.surfaceHi, in: Capsule())
    }
    private var confidenceBadge: some View {
        let c = summary.confidence
        return HStack(spacing: 5) {
            Image(systemName: c == "strong" ? "checkmark.seal.fill" : c == "none" ? "questionmark.circle" : "exclamationmark.triangle.fill")
            Text(c == "none" ? "uncalibrated" : c)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.confidenceColor(c))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.confidenceColor(c).opacity(0.14), in: Capsule())
        .accessibilityLabel("Calibration confidence \(c)")
    }
}
