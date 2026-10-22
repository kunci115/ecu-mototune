import SwiftUI

/// Snapshot-diff variable identification: read all variables at idle, then while holding throttle,
/// and rank which ones moved. Reveals TPS/MAP/AFR/load without the encrypted file.
struct IdentifyView: View {
    let session: ECUSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.bg.ignoresSafeArea()
                VStack(spacing: Theme.Space.lg) {
                    steps
                    if session.identifyBusy { ProgressView("Reading all variables…").tint(Theme.Palette.accent) }
                    if !session.movers.isEmpty { results } else { Spacer() }
                }
                .padding(Theme.Space.lg)
            }
            .navigationTitle("Identify Variables")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") { session.clearSnapshots() }.disabled(session.snapIdle == nil)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("How").eyebrow()
            Text("With the engine idling, tap Capture Idle. Then hold the throttle steady at one opening and tap Capture Throttle. The variables that change most are candidates for TPS, MAP, AFR and load.")
                .font(.system(size: 13)).foregroundStyle(Theme.Palette.textDim)
            HStack(spacing: Theme.Space.md) {
                snapButton("Capture Idle", done: session.snapIdle != nil) { Task { await session.captureSnapshot(idle: true) } }
                snapButton("Capture Throttle", done: session.snapThrottle != nil) { Task { await session.captureSnapshot(idle: false) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func snapButton(_ title: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(done ? Theme.Palette.good : Theme.Palette.accent)
        .foregroundStyle(.black)
        .disabled(session.identifyBusy || session.state != .connected)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Biggest Movers").eyebrow()
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(session.movers.prefix(30)) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.text)
                                Text(String(format: "0x%04X · id %d", m.index, Int(m.index) - 0x4000))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.Palette.textFaint)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(m.idle) → \(m.throttle)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Palette.textDim)
                                Text(m.delta > 0 ? "+\(m.delta)" : "\(m.delta)")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(m.delta > 0 ? Theme.Palette.good : Theme.Palette.bad)
                            }
                        }
                        .padding(.vertical, 7).padding(.horizontal, Theme.Space.md)
                        .background(Theme.Palette.surface)
                    }
                }
                .clipShape(.rect(cornerRadius: Theme.Radius.md))
            }
            Text("Saved as identify-….json — pull it to confirm the ids.")
                .font(.system(size: 11)).foregroundStyle(Theme.Palette.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
