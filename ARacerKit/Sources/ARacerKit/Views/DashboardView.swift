import SwiftUI

/// Live tab: status bar, record control, ECU identity, licence, and the live-value grid.
struct DashboardView: View {
    let session: ECUSession
    @State private var showIdentify = false

    var body: some View {
        ZStack {
            Theme.Palette.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                ConnectionHeader(session: session)
                if let err = session.lastError, session.state != .connected {
                    Text(err).font(.system(size: 11)).foregroundStyle(Theme.Palette.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.sm)
                        .textSelection(.enabled)
                }
                HStack(spacing: Theme.Space.md) {
                    RecordControl(session: session)
                    Button { showIdentify = true } label: {
                        Image(systemName: "wand.and.stars").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.bordered).tint(Theme.Palette.accent)
                    .disabled(session.state != .connected)
                    .padding(.trailing, Theme.Space.lg)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        IdentityCard(session: session)
                        if !session.slots.isEmpty {
                            Text("Live Data").eyebrow()
                            LiveGrid(session: session)
                        }
                    }
                    .padding(Theme.Space.lg)
                }
            }
        }
        .sheet(isPresented: $showIdentify) { IdentifyView(session: session) }
    }
}
