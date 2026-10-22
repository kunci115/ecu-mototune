import SwiftUI

/// Start/stop background logging of the live stream to a CSV file.
struct RecordControl: View {
    let session: ECUSession

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            if session.isLogging {
                Image(systemName: "record.circle.fill").foregroundStyle(Theme.Palette.bad).symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording \(session.logCount) samples").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.text)
                    if let name = session.logName { Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Palette.textDim) }
                }
                Spacer()
                Button("Stop", systemImage: "stop.fill") { Task { await session.stopLogging() } }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.bad)
            } else {
                Button("Record Log", systemImage: "record.circle") { Task { await session.startLogging() } }
                    .buttonStyle(.bordered).tint(Theme.Palette.bad)
                    .disabled(session.state != .connected)
                Spacer()
                if let name = session.logName {
                    Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Palette.textFaint).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.sm)
    }
}
