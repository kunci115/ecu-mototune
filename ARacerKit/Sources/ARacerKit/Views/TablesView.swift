import SwiftUI

/// Tables tab: every calibration table the ECU exposes, grouped by what it tunes, each row
/// carrying a live preview of its contents (heat-map thumbnail, bar strip, or the scalar value).
public struct TablesView: View {
    public init() {}
    @State private var tables: [TableSummary] = TableSummary.load()
    @State private var selection: Int? = CommandLine.arguments.firstIndex(of: "--table").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(TableSummary.Category.allCases, id: \.self) { cat in
                    let group = tables.filter { $0.category == cat }
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { t in
                                TableRow(summary: t).tag(t.id)
                                    .listRowBackground(Theme.Palette.surface)
                                    .listRowSeparatorTint(Theme.Palette.border)
                                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 12))
                            }
                        } header: {
                            Text(cat.rawValue).eyebrow()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.bg)
            .navigationTitle("Tables")
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            if let t = tables.first(where: { $0.id == selection }) {
                TableDetail(summary: t).id(t.id)
            } else {
                ZStack {
                    Theme.Palette.bg.ignoresSafeArea()
                    ContentUnavailableView("Select a table", systemImage: "square.grid.3x3",
                                           description: Text("Pick a tuning table from the list."))
                }
            }
        }
        .tint(Theme.Palette.accent)
    }
}

/// One list row: icon, name, shape, and a content preview on the right.
struct TableRow: View {
    let summary: TableSummary

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 34, height: 34)
                .background(Theme.Palette.accent.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.sm))
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Palette.text)
                HStack(spacing: 6) {
                    Circle().fill(Theme.confidenceColor(summary.confidence)).frame(width: 6, height: 6)
                    Text(subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Palette.textDim)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            preview
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.name), \(subtitle)")
    }

    private var icon: String {
        switch summary.shape {
        case .scalar: summary.isBoolean ? "switch.2" : "number"
        case .vector: "chart.bar.xaxis"
        case .grid: "square.grid.3x3.fill"
        }
    }
    private var subtitle: String {
        switch summary.shape {
        case .scalar: "0x" + String(summary.table.index ?? 0, radix: 16, uppercase: true) + " · " + (summary.unit == "raw" ? "raw" : summary.unit)
        case .vector(let n): "\(n) points · \(summary.unit)"
        case .grid(let r, let c): "\(r) × \(c) · \(summary.unit)"
        }
    }

    @ViewBuilder private var preview: some View {
        switch summary.shape {
        case .scalar:
            if summary.isBoolean {
                let on = (summary.flat.first ?? 0) != 0
                Text(on ? "ON" : "OFF").font(.system(size: 11, weight: .bold)).tracking(0.6)
                    .foregroundStyle(on ? .black : Theme.Palette.textDim)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(on ? Theme.Palette.good : Theme.Palette.surfaceHi, in: Capsule())
            } else {
                Text(summary.scalarText).font(Theme.display(17, .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.Palette.text).lineLimit(1).minimumScaleFactor(0.7)
            }
        case .vector:
            MiniBars(values: summary.flat).frame(width: 72, height: 26)
        case .grid:
            MiniHeatmap(rows: summary.values).frame(width: 72, height: 40)
        }
    }
}
