import SwiftUI

/// Edit the Fuel Adjust map with a staged DRAFT: tap cells to select, +/- by a step, bulk by row/col,
/// review the before→after diff, then Write (gated until the ECU write path is hardware-tested).
public struct FuelEditorView: View {
    let map: FuelMap?
    let session: ECUSession?
    @State private var selected: Set<Int> = []
    @State private var confirmWrite = false
    @Environment(\.dismiss) private var dismiss
    public init(map: FuelMap?, session: ECUSession? = nil) { self.map = map; self.session = session }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.bg.ignoresSafeArea()
                if let map {
                    VStack(spacing: Theme.Space.md) {
                        controls(map)
                        FuelGrid(map: map, selected: $selected)
                        Spacer(minLength: 0)
                    }.padding(Theme.Space.lg)
                } else {
                    ContentUnavailableView("No map", systemImage: "square.grid.3x3")
                }
            }
            .navigationTitle("Fuel Adjust")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .tint(Theme.Palette.accent)
    }

    private func controls(_ map: FuelMap) -> some View {
        VStack(spacing: Theme.Space.sm) {
            HStack {
                Text("Step").eyebrow()
                Picker("Step", selection: Binding(get: { map.step }, set: { map.step = $0 })) {
                    ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { Text("\($0, format: .number)%").tag($0) }
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Text("\(selected.count) sel · \(map.changedCount) changed").font(.caption).foregroundStyle(Theme.Palette.textDim)
            }
            HStack(spacing: Theme.Space.sm) {
                Button { nudge(map, +map.step) } label: { Label("Raise", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.good).foregroundStyle(.black)
                Button { nudge(map, -map.step) } label: { Label("Lower", systemImage: "minus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.bad).foregroundStyle(.black)
                Button("Clear") { map.clearDraft(); selected.removeAll() }.buttonStyle(.bordered).tint(Theme.Palette.textDim)
            }.disabled(selected.isEmpty && map.changedCount == 0)
            let canWrite = session?.state == .connected && map.isLive && map.changedCount > 0 && !(session?.writeBusy ?? true)
            Button { confirmWrite = true } label: {
                Label(map.isLive ? "Write to ECU" : "Write to ECU (connect first)", systemImage: map.isLive ? "arrow.down.to.line" : "lock.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(Theme.Palette.warn).disabled(!canWrite)
            if let session, !session.writeLog.isEmpty {
                ForEach(Array(session.writeLog.suffix(3).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                        .foregroundStyle(line.hasPrefix("✗") ? Theme.Palette.bad : line.hasPrefix("✓") ? Theme.Palette.good : Theme.Palette.textDim)
                }
            }
        }
        .card(padding: Theme.Space.md)
        .confirmationDialog("Write \(map.changedCount) cell(s) to the ECU?", isPresented: $confirmWrite, titleVisibility: .visible) {
            Button("Backup, write and verify", role: .destructive) { Task { await session?.writeFuelDraft(source: "manual") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(map.changedCells.prefix(8).map { "TPS \(map.tps[$0.row]) · \(map.rpm[$0.col]) rpm: \(String(format: "%.1f → %.1f", $0.from, $0.to))" }.joined(separator: "\n"))
        }
    }

    private func nudge(_ map: FuelMap, _ amount: Double) {
        let cols = map.rpm.count
        map.nudge(selected.map { ($0 / cols, $0 % cols) }, by: amount)
    }
}

struct FuelGrid: View {
    let map: FuelMap
    @Binding var selected: Set<Int>
    private let cellW: CGFloat = 50, cellH: CGFloat = 28

    var body: some View {
        let cols = map.rpm.count
        ScrollView([.horizontal, .vertical]) {
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    head("TPS\\RPM")
                    ForEach(map.rpm, id: \.self) { head("\($0)") }
                }
                ForEach(Array(map.tps.enumerated()), id: \.offset) { r, tpsVal in
                    GridRow {
                        head("\(tpsVal)")
                        ForEach(0..<cols, id: \.self) { c in
                            let id = r * cols + c
                            cell(map, r, c, selected: selected.contains(id))
                                .onTapGesture { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ map: FuelMap, _ r: Int, _ c: Int, selected: Bool) -> some View {
        let changed = map.isChanged(r, c)
        let d = map.delta(r, c)
        return Text(map.value(r, c), format: .number.precision(.fractionLength(1)))
            .font(.system(size: 11, weight: changed ? .bold : .medium, design: .monospaced))
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: cellW, height: cellH)
            .background(bg(changed, d), in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.Palette.accent, lineWidth: selected ? 2 : 0))
    }
    private func bg(_ changed: Bool, _ d: Double) -> Color {
        if changed { return (d >= 0 ? Theme.Palette.good : Theme.Palette.bad).opacity(0.85) }
        return Theme.Palette.surfaceHi
    }
    private func head(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Theme.Palette.textDim)
            .frame(width: cellW, height: cellH).background(Theme.Palette.surfaceHi, in: .rect(cornerRadius: 3))
    }
}
