import SwiftUI

/// Settings: the Claude API key (Keychain only) and a connectivity test.
struct SettingsView: View {
    var session: ECUSession? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saved = KeychainStore.get(KeychainStore.claudeKey) != nil
    @State private var testResult: String?
    @State private var testing = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        keyCard
                        if let w = session?.watch { watchCard(w) }
                        infoCard
                    }
                    .padding(Theme.Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .onTapGesture { keyFocused = false }
            #if os(iOS)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { keyFocused = false }.fontWeight(.semibold) } }
            #endif
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Claude API key").eyebrow()
            Text(saved ? "A key is stored in the iOS Keychain." : "No key yet. Create one at console.anthropic.com → API Keys, then paste it here.")
                .font(.caption).foregroundStyle(saved ? Theme.Palette.good : Theme.Palette.textDim)
            SecureField("sk-ant-…", text: $key)
                .focused($keyFocused)
                .submitLabel(.done)
                .onSubmit { keyFocused = false }
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Palette.text)
                .padding(10).background(Theme.Palette.surfaceHi, in: .rect(cornerRadius: Theme.Radius.sm))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            HStack(spacing: Theme.Space.sm) {
                Button("Save", systemImage: "key.fill") {
                    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !k.isEmpty else { return }
                    KeychainStore.set(k, for: KeychainStore.claudeKey); saved = true; key = ""; testResult = nil
                }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.accent).foregroundStyle(.black)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Test", systemImage: "antenna.radiowaves.left.and.right", action: test)
                    .buttonStyle(.bordered).tint(Theme.Palette.accent).disabled(!saved || testing)
                if saved {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        KeychainStore.delete(KeychainStore.claudeKey); saved = false; testResult = nil
                    }
                    .buttonStyle(.bordered).tint(Theme.Palette.bad)
                }
            }
            if testing { ProgressView().tint(Theme.Palette.accent) }
            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("OK") ? Theme.Palette.good : Theme.Palette.bad)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func watchCard(_ w: any WatchLink) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Garmin watch").eyebrow()
            Text(w.statusText).font(.caption).foregroundStyle(w.isReady ? Theme.Palette.good : Theme.Palette.textDim)
            HStack(spacing: Theme.Space.sm) {
                Button("Pair watch", systemImage: "applewatch") { w.pair() }.buttonStyle(.bordered).tint(Theme.Palette.accent)
                Button("Open MotoTune Ride", systemImage: "play.circle") { w.openWatchApp() }.buttonStyle(.bordered).tint(Theme.Palette.accent).disabled(!w.isPaired)
                Button("Refresh", systemImage: "arrow.clockwise") { w.refresh() }.buttonStyle(.bordered).tint(Theme.Palette.textDim).disabled(!w.isPaired)
            }
            Button("Send test data (random AFR / rpm)", systemImage: "paperplane") { w.sendTest() }
                .buttonStyle(.bordered).tint(Theme.Palette.warn).disabled(!w.isPaired)
            Text("Needs the Garmin Connect app and the MotoTune Ride watch app. The watch shows RPM · AFR · gear · pulls, vibrates on lean AFR, and a button press sends a feel marker here.")
                .font(.caption2).foregroundStyle(Theme.Palette.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("How the copilot connects").eyebrow()
            Text("Wi-Fi stays on the ECU bridge (no internet). The Claude call goes out over cellular, so keep mobile data on while tuning. The key never leaves the Keychain and is sent only to api.anthropic.com.")
                .font(.caption).foregroundStyle(Theme.Palette.textDim)
            Text("Model: claude-haiku-5-5 · structured JSON replies · each pass ≤ 3 % per cell")
                .font(.caption2).foregroundStyle(Theme.Palette.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func test() {
        guard let k = KeychainStore.get(KeychainStore.claudeKey) else { return }
        testing = true; testResult = nil
        Task {
            do { let m = try await ClaudeClient(apiKey: k).ping(); testResult = "OK — answered by \(m)" }
            catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}
