import SwiftUI
import SwiftData

/// Tuner = the performance loop: change a region of Fuel Adjust → do pulls → compare acceleration
/// vs baseline → Keep or Revert. AFR is shown only as a safety guard, never as the target.
public struct TunerView: View {
    let session: ECUSession
    @Environment(\.modelContext) private var context
    @State private var showEditor = CommandLine.arguments.contains("--editor")
    @State private var showSettings = CommandLine.arguments.contains("--settings")
    @State private var notes = ""
    @State private var confirmWrite = false
    @FocusState private var notesFocused: Bool
    public init(session: ECUSession) { self.session = session }

    private var d: DynoEngine { session.dyno }
    private var map: FuelMap? { session.fuelMap }

    public var body: some View {
        ZStack {
            Theme.Palette.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    stepChange
                    aiCard
                    stepMeasure
                    stepDecide
                    safety
                    notesBar
                }
                .padding(Theme.Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onTapGesture { notesFocused = false }          // tap anywhere outside the field → keyboard down
        #if os(iOS)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { notesFocused = false }.fontWeight(.semibold) } }
        #endif
        .sheet(isPresented: $showEditor) { FuelEditorView(map: map, session: session) }
        .sheet(isPresented: $showSettings) { SettingsView(session: session) }
    }

    // 1 — change
    private var stepChange: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("1 · Change").eyebrow()
            HStack {
                Text(map.map { "\($0.changedCount) cells staged · map \(d.mapLabel)" } ?? "no map")
                    .font(.system(size: 13)).foregroundStyle(Theme.Palette.text)
                Spacer()
                Button("Edit Fuel Map", systemImage: "square.grid.3x3") { showEditor = true }
                    .buttonStyle(.bordered).tint(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }


    // AI copilot: fills the same draft in bulk, gradual, from everything measured
    private var aiCard: some View {
        let ai = session.copilot
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("AI Suggest").eyebrow()
                Spacer()
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.Palette.textDim)
            }
            if !ai.hasKey {
                Text("Add a Claude API key in Settings to enable the copilot.").font(.caption).foregroundStyle(Theme.Palette.textDim)
            }
            HStack(spacing: Theme.Space.sm) {
                Button {
                    guard let map else { return }
                    Task { await ai.suggest(map: map, tuner: session.tuner, dyno: d, notes: notes, context: context) }
                } label: {
                    if ai.state == .thinking { ProgressView().tint(.black) } else { Label("Suggest next pass", systemImage: "sparkles") }
                }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.accent).foregroundStyle(.black)
                .disabled(!ai.hasKey || map == nil || ai.state == .thinking)
                Text("≤ \(Int(ai.maxStep)) % per cell · stages into the draft, never writes")
                    .font(.caption2).foregroundStyle(Theme.Palette.textFaint)
            }
            switch ai.state {
            case .idle: EmptyView()
            case .thinking: Text("Thinking over \(d.pulls.count) pulls, \(session.tuner.samplesLearned) AFR samples…").font(.caption).foregroundStyle(Theme.Palette.textDim)
            case .failed(let m): Label(m, systemImage: "xmark.octagon").font(.caption).foregroundStyle(Theme.Palette.bad)
            case .done(let m):
                Label(m, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.Palette.good)
                if !ai.lastRationale.isEmpty { Text(ai.lastRationale).font(.system(size: 13)).foregroundStyle(Theme.Palette.text) }
                ForEach(ai.lastCautions, id: \.self) { c in
                    Label(c, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.Palette.warn)
                }
                ForEach(ai.lastRejected, id: \.self) { r in
                    Label("Blocked: \(r)", systemImage: "hand.raised").font(.caption).foregroundStyle(Theme.Palette.bad)
                }
                Text(ai.lastUsage).font(.caption2).foregroundStyle(Theme.Palette.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    // 2 — measure: average ALL pulls per map revision, claim a change only above pull-to-pull noise
    private var stepMeasure: some View {
        let labels = d.labels
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("2 · Measure  ·  \(d.pulls.count) pulls").eyebrow()
            if labels.count >= 2 {
                let cur = labels[0], prev = labels[1]
                let cmp = d.latestComparison
                if cmp.isEmpty {
                    Text("Revisions don't share RPM bins yet — pull in the same gear.").font(.caption).foregroundStyle(Theme.Palette.textDim)
                } else {
                    let mean = cmp.map(\.pct).reduce(0, +) / Double(cmp.count)
                    let sig = cmp.filter(\.significant).count
                    let nA = cmp.first?.nA ?? 0, nB = cmp.first?.nB ?? 0
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%+.1f%%", mean)).font(Theme.display(28, .bold)).monospacedDigit()
                            .foregroundStyle(sig > 0 && mean > 0 ? Theme.Palette.good : sig > 0 && mean < 0 ? Theme.Palette.bad : Theme.Palette.textDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sig == 0 ? "Within noise — not a real change yet" : mean > 0 ? "Faster, beyond noise in \(sig) of \(cmp.count) RPM bins" : "Slower, beyond noise in \(sig) of \(cmp.count) RPM bins")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.text)
                            Text("\(cur) (\(nA) pulls) vs \(prev) (\(nB) pulls) · more pulls = tighter noise").font(.caption).foregroundStyle(Theme.Palette.textDim)
                        }
                    }
                    ForEach(cmp, id: \.rpm) { x in
                        HStack {
                            Text("\(x.rpm)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Palette.textFaint).frame(width: 48, alignment: .leading)
                            Text(String(format: "%+.1f%%", x.pct)).font(.system(size: 12, weight: x.significant ? .bold : .regular, design: .monospaced))
                                .foregroundStyle(!x.significant ? Theme.Palette.textFaint : x.pct > 0 ? Theme.Palette.good : Theme.Palette.bad)
                            if !x.significant { Text("noise").font(.caption2).foregroundStyle(Theme.Palette.textFaint) }
                            Spacer()
                        }
                    }
                }
            } else {
                Text("Do 3–5 full-throttle pulls in one gear with the current map (baseline). After Keep, pull again — the two revisions are averaged and compared here.")
                    .font(.caption).foregroundStyle(Theme.Palette.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    // 3 — decide: apply the draft to the ECU (backup → write → verify) or throw it away
    private var stepDecide: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("3 · Decide").eyebrow()
            HStack(spacing: Theme.Space.sm) {
                Button("Apply to ECU", systemImage: "arrow.down.to.line") { confirmWrite = true }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.good).foregroundStyle(.black)
                    .disabled((map?.changedCount ?? 0) == 0 || session.state != .connected || !(map?.isLive ?? false) || session.writeBusy)
                Button("Revert", systemImage: "arrow.uturn.backward") { session.revertDraft() }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.bad).foregroundStyle(.black)
                    .disabled((map?.changedCount ?? 0) == 0 || session.writeBusy)
            }
            Text(map?.isLive == true ? "Map read live from ECU (\(d.mapLabel)). Apply = backup, write changed rows, read back, verify."
                                     : "Map is from the dump — connect so it is read live before any write.")
                .font(.caption2).foregroundStyle(Theme.Palette.textFaint)
            if session.writeBusy { ProgressView().tint(Theme.Palette.accent) }
            ForEach(Array(session.writeLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("✗") ? Theme.Palette.bad : line.hasPrefix("✓") ? Theme.Palette.good : Theme.Palette.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
        .confirmationDialog("Write \(map?.changedCount ?? 0) cell(s) in \(map?.changedRows.count ?? 0) row(s) to the ECU?", isPresented: $confirmWrite, titleVisibility: .visible) {
            Button("Backup, write and verify", role: .destructive) {
                Task { await session.writeFuelDraft(source: session.copilot.lastChanges > 0 ? "ai" : "manual") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((map?.changedCells ?? []).prefix(8).map { "TPS \(map!.tps[$0.row]) · \(map!.rpm[$0.col]) rpm: \(String(format: "%.1f → %.1f", $0.from, $0.to))" }.joined(separator: "\n")
                 + ((map?.changedCount ?? 0) > 8 ? "\n…" : ""))
        }
    }

    // AFR as a safety guard only
    private var safety: some View {
        let t = session.tuner
        return HStack(spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AFR (guard)").eyebrow()
                Text(t.liveAFR.map { String(format: "%.1f", $0) } ?? "–").font(Theme.display(22, .semibold)).monospacedDigit()
                    .foregroundStyle((t.liveAFR ?? 0) > DynoEngine.leanLimitWOT && (t.liveTPS ?? 0) >= 30 ? Theme.Palette.bad : Theme.Palette.text)
            }
            if let p = d.pulls.first, let mx = p.maxAFR {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last pull max").eyebrow()
                    Text(String(format: "%.1f", mx)).font(Theme.display(22, .semibold)).monospacedDigit()
                        .foregroundStyle(mx > DynoEngine.leanLimitWOT ? Theme.Palette.bad : Theme.Palette.good)
                }
                if mx > DynoEngine.leanLimitWOT {
                    Label("Lean at full throttle — do not add power here", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.Palette.bad)
                }
            }
            Spacer()
        }
        .card()
    }

    private var notesBar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
        if !session.watchMarkers.isEmpty {
            Text("\(session.watchMarkers.count) feel marker(s) from the watch · last \(session.watchMarkers.last!.at.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(Theme.Palette.accent)
        }
        HStack(spacing: Theme.Space.sm) {
            TextField("Feel notes (e.g. flat spot at 4k)", text: $notes, axis: .vertical)
                .focused($notesFocused)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.Palette.text)
                .padding(8).background(Theme.Palette.surfaceHi, in: .rect(cornerRadius: Theme.Radius.sm))
            Button("Save Session", systemImage: "externaldrive.fill.badge.plus", action: saveSession)
                .buttonStyle(.bordered).tint(Theme.Palette.accent)
        }
        }
    }

    private func saveSession() {
        let enc = JSONEncoder(); let t = session.tuner
        let marks = session.watchMarkers.map { "mark @" + $0.at.formatted(date: .omitted, time: .standard) + ($0.hr.map { " hr \($0)" } ?? "") }
        let allNotes = marks.isEmpty ? notes : notes + "\n" + marks.joined(separator: "\n")
        context.insert(TuningSession(notes: allNotes, ecuModel: session.info?.model?.rawValue ?? "", firmware: session.identity?.firmware ?? "",
                                     samples: t.samplesLearned, meanAbsAfrError: t.meanAbsError,
                                     correctionMapJSON: (try? enc.encode(t.correctionMap())) ?? Data(),
                                     sampleCountsJSON: (try? enc.encode(t.sampleCounts())) ?? Data()))
        try? context.save(); notes = ""
    }
}
