import SwiftUI

/// One table: identity card, stats strip, and the content drawn in the form that fits it —
/// a big value for scalars, bars for vectors, an axis heat-map or 3D surface for grids.
struct TableDetail: View {
    let summary: TableSummary
    @State private var showScaled = true
    @State private var show3D = false

    private var rows: [[Double]] { showScaled ? summary.values : summary.raw.map { $0.map(Double.init) } }
    private var decimals: Int { showScaled ? summary.decimals : 0 }
    private var isGrid: Bool { if case .grid = summary.shape { true } else { false } }

    var body: some View {
        ZStack {
            Theme.Palette.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    TableDetailHeader(summary: summary, showScaled: $showScaled, show3D: $show3D)
                    if !summary.isFlat || isGrid { statsStrip }
                    content
                    CalibrationNote(scaling: summary.scaling, axes: summary.axes)
                }
                .padding(Theme.Space.lg)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(summary.name)
    }

    private var statsStrip: some View {
        HStack(spacing: Theme.Space.sm) {
            stat("Min", summary.min); stat("Mean", summary.mean); stat("Max", summary.max)
            if isGrid {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scale").eyebrow()
                    LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map(Theme.heat), startPoint: .leading, endPoint: .trailing)
                        .frame(height: 10).clipShape(Capsule())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .card(padding: Theme.Space.md)
    }
    private func stat(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).eyebrow()
            Text(v, format: .number.precision(.fractionLength(summary.decimals)))
                .font(Theme.display(18, .semibold)).monospacedDigit().foregroundStyle(Theme.Palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch summary.shape {
        case .scalar:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Value").eyebrow()
                if summary.isBoolean {
                    let on = (summary.flat.first ?? 0) != 0
                    HStack(spacing: Theme.Space.sm) {
                        Circle().fill(on ? Theme.Palette.good : Theme.Palette.textFaint).frame(width: 12, height: 12)
                        Text(on ? "Enabled" : "Disabled").font(Theme.display(28, .bold)).foregroundStyle(Theme.Palette.text)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(rows.first?.first ?? 0, format: .number.precision(.fractionLength(decimals)))
                            .font(Theme.display(40, .bold)).monospacedDigit().foregroundStyle(Theme.Palette.text)
                        if showScaled, summary.unit != "raw" { Text(summary.unit).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Palette.textDim) }
                    }
                }
                Text("raw \(summary.raw.first?.first ?? 0)" + (summary.scaling.map { " · ×\($0.scale)" + ($0.offset != 0 ? " + \(Int($0.offset))" : "") } ?? ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Palette.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading).card()
        case .vector:
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(summary.isFlat ? "All points at \(summary.scalarLike(decimals: decimals, rows: rows)) — untouched" : "Points").eyebrow()
                VectorBars(values: rows.first ?? [], decimals: decimals, unit: summary.unit)
            }
            .frame(maxWidth: .infinity, alignment: .leading).card()
        case .grid:
            if show3D {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Surface3DView(rows: rows, unit: showScaled ? summary.unit : "raw")
                        .frame(height: 320)
                        .accessibilityLabel("3D surface of \(summary.name). Drag to rotate.")
                    Text("Drag to rotate · height and colour follow the value").font(.caption).foregroundStyle(Theme.Palette.textDim)
                }
                .card(padding: Theme.Space.md)
            } else if let axes = summary.axes {
                AxisGrid(rows: rows, decimals: decimals, tps: axes.tps, rpm: axes.rpm, confirmed: axes.confirmed)
                    .card(padding: Theme.Space.sm)
            } else {
                ScrollView([.horizontal, .vertical]) { GridBody(display: rows, decimals: decimals) }
                    .card(padding: Theme.Space.sm)
            }
        }
    }
}

extension TableSummary {
    func scalarLike(decimals: Int, rows: [[Double]]) -> String {
        String(format: "%.\(decimals)f", rows.first?.first ?? 0) + (unit == "raw" ? "" : " \(unit)")
    }
}
