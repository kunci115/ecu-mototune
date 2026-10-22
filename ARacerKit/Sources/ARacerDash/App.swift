import SwiftUI
import AppKit
import ARacerKit

@main
struct ARacerDashApp: App {
    @State private var session = ECUSession(slots: KnownVariables.defaultSlots) {
        let t = NWTransport(wifiOnly: false); try await t.connect(); return t
    }
    @State private var demo = ECUSession(slots: KnownVariables.defaultSlots) { DemoECU.make() }
    @State private var useDemo = CommandLine.arguments.contains("--demo")
    private let container = TuningDB.makeContainer()

    init() {
        NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate()
        // --snapshot <file.png>: render our own window to a PNG after it settles, then quit.
        // Uses the view's own cacheDisplay — no Screen Recording permission involved.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(i + 1) {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let win = NSApp.windows.first(where: { $0.isVisible }), let view = win.contentView {
                    let target = win.sheets.first?.contentView ?? view
                    if let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) {
                        target.cacheDisplay(in: target.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup("aRacer Dash") {
            RootView(live: useDemo ? demo : session)
                .frame(minWidth: 860, minHeight: 600)
        }
        .modelContainer(container)
    }
}
