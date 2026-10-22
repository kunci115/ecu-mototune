import SwiftUI
import ARacerKit

// iOS entry point. Reuses the cross-platform SwiftUI views that live in the app code
// shared with the macOS dashboard. Live connection pins to the Wi-Fi interface so the
// phone keeps cellular for the internet (fixes the official app's dropouts).
@main
struct ARacerXTuneApp: App {
    @State private var session = ECUSession(slots: KnownVariables.defaultSlots) {
        let t = NWTransport(wifiOnly: false)   // let iOS route 192.168.88.x via Wi-Fi; cellular stays for internet
        try await t.connect()
        return t
    }
    @State private var demo = ECUSession(slots: KnownVariables.defaultSlots) { DemoECU.make() }
    @State private var useDemo = CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["MOTOTUNE_DEMO"] != nil
    private let container = TuningDB.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView(live: useDemo ? demo : session)
        }
        .modelContainer(container)
    }
}
