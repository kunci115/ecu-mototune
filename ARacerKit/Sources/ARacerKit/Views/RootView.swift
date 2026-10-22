import SwiftUI

/// Top-level cross-platform UI shared by the macOS dashboard and the iOS app.
public struct RootView: View {
    let live: ECUSession
    @Environment(\.modelContext) private var context
    /// `--tab live|tuner|dyno|tables` picks the start tab (used for automated screenshots).
    @State private var tab: String = CommandLine.arguments.firstIndex(of: "--tab").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "live"
    public init(live: ECUSession) { self.live = live }

    public var body: some View {
        TabView(selection: $tab) {
            DashboardView(session: live)
                .tabItem { Label("Live", systemImage: "gauge.open.with.lines.needle.33percent") }.tag("live")
            TunerView(session: live)
                .tabItem { Label("Tuner", systemImage: "slider.horizontal.3") }.tag("tuner")
            DynoView(session: live)
                .tabItem { Label("Dyno", systemImage: "chart.bar.xaxis") }.tag("dyno")
            TablesView()
                .tabItem { Label("Tables", systemImage: "square.grid.3x3.fill") }.tag("tables")
        }
        .tint(Theme.Palette.accent)
        .preferredColorScheme(.dark)
        .onAppear { live.db = context; live.connect() }
    }
}
