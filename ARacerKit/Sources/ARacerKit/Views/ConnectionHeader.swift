import SwiftUI

/// Brand + connection status + connect/disconnect, styled as a telemetry status bar.
struct ConnectionHeader: View {
    let session: ECUSession

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MOTOTUNE").font(Theme.display(16, .bold)).tracking(1.5).foregroundStyle(Theme.Palette.text)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                        .shadow(color: statusColor.opacity(0.8), radius: 4)
                    Text(session.state.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Palette.textDim)
                    if session.state == .connected {
                        Text("· \(session.sampleRate, format: .number.precision(.fractionLength(0))) Hz")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.Palette.textFaint)
                    }
                }
            }
            Spacer()
            Button(action: toggleConnection) {
                Label(session.state == .idle ? "Connect" : "Disconnect",
                      systemImage: session.state == .idle ? "bolt.horizontal.fill" : "bolt.horizontal")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(session.state == .idle ? Theme.Palette.accent : Theme.Palette.surfaceHi)
            .foregroundStyle(session.state == .idle ? Color.black : Theme.Palette.text)
        }
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: Theme.Palette.good
        case .connecting: Theme.Palette.warn
        case .lost: Theme.Palette.bad
        case .idle: Theme.Palette.textFaint
        }
    }
    private func toggleConnection() {
        if session.state == .idle { session.connect() } else { session.disconnect() }
    }
}
