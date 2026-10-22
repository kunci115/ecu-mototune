import Foundation
import SwiftData

/// The AI copilot: packs everything the app measured (fuel map + draft, per-cell AFR statistics,
/// averaged pull curves per map revision, past suggestions and outcomes, rider notes) into one
/// Claude call and stages the returned cell deltas into the shared FuelMap draft — in bulk, gradual
/// (≤ maxStep per pass), never written to the ECU by itself.
@MainActor @Observable
public final class Copilot {
    public enum State: Equatable { case idle, thinking, done(String), failed(String) }
    public private(set) var state: State = .idle
    public private(set) var lastRationale = ""
    public private(set) var lastCautions: [String] = []
    public private(set) var lastChanges = 0
    public private(set) var lastUsage = ""
    public private(set) var lastRejected: [String] = []
    public var maxStep = 3.0            // % per pass — "pelan-pelan", re-measured before the next pass

    public init() {}

    public var hasKey: Bool { !(KeychainStore.get(KeychainStore.claudeKey) ?? "").isEmpty }

    static let system = """
    You are an expert motorcycle EFI tuner working on an aRacer RC MiniX ECU through a rider's phone app.
    Objective: maximise measured engine acceleration (torque proxy = dRPM/dt per RPM bin during full-throttle pulls in a fixed gear). \
    You tune the Fuel Adjust table (percent, 100 = unchanged; rows = TPS %, columns = RPM) directly, like an experienced human tuner — \
    NOT by chasing an AFR target. AFR is a safety guard only: never propose removing fuel from a cell whose measured AFR at high throttle \
    is already above 13.6, and treat AFR cells with few samples or high std as unreliable. Every proposal must be judged by the next pulls, \
    so change few cells, by small amounts (the app clamps each cell to ±maxStep per pass), and keep neighbouring cells smooth. \
    Prefer cells that the pulls actually visited; leave idle/low-TPS cells alone unless the rider's notes point there. \
    If the measured comparison between revisions is within noise, say so and either propose a different region or propose nothing. \
    Reply only with the JSON schema given. Deltas are in percent points relative to the CURRENT base value.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "rationale": ["type": "string"],
            "changes": ["type": "array", "items": [
                "type": "object",
                "properties": ["tps": ["type": "integer"], "rpm": ["type": "integer"], "delta_pct": ["type": "number"], "reason": ["type": "string"]],
                "required": ["tps", "rpm", "delta_pct", "reason"], "additionalProperties": false]],
            "cautions": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["rationale", "changes", "cautions"], "additionalProperties": false,
    ]

    /// Build the measurement payload the model reasons over.
    func payload(map: FuelMap, tuner: TunerEngine, dyno: DynoEngine, notes: String, history: [String: Any]) -> [String: Any] {
        func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        var afrCells: [[String: Any]] = []
        for (r, row) in tuner.cells.enumerated() {
            for (c, cell) in row.enumerated() where cell.count >= 3 {
                afrCells.append(["tps": tuner.tps[r], "rpm": tuner.rpm[c], "n": cell.count,
                                 "afr_vs_target_pct": r1(cell.correctionPct ?? 0), "std_pct": r1(cell.stdPct ?? 0)])
            }
        }
        var revisions: [[String: Any]] = []
        for label in dyno.labels {
            let curve = dyno.averagedCurve(label: label)
            let pulls = dyno.pulls.filter { $0.mapLabel == label }
            revisions.append(["label": label, "pulls": pulls.count,
                              "max_afr_in_pulls": pulls.compactMap(\.maxAFR).max().map(r1) as Any,
                              "accel_rpm_per_s": curve.map { ["rpm": $0.rpm, "mean": r1($0.mean), "std": r1($0.std), "n": $0.n] }])
        }
        var comparison: [String: Any] = [:]
        if dyno.labels.count >= 2 {
            let cmp = dyno.latestComparison
            comparison = ["current": dyno.labels[0], "previous": dyno.labels[1],
                          "bins": cmp.map { ["rpm": $0.rpm, "pct": r1($0.pct), "significant": $0.significant] }]
        }
        return [
            "axes": ["tps_rows": map.tps, "rpm_cols": map.rpm],
            "fuel_adjust_base": map.base.map { $0.map(r1) },
            "staged_draft": map.draft.map { $0.map { $0.map(r1) as Any } },
            "max_step_pct": maxStep,
            "afr_cells": afrCells,
            "tps_max_seen": dyno.tpsMaxSeen,
            "revisions": revisions,
            "latest_comparison": comparison,
            "rider_notes": notes,
            "history": history,
        ]
    }

    public struct Change: Equatable { public let row: Int, col: Int, delta: Double, reason: String }

    /// Hard safety filter on the model's proposal — the prompt asks for this, the code enforces it.
    static func filter(_ raw: [[String: Any]], map: FuelMap, tuner: TunerEngine, dyno: DynoEngine) -> (accepted: [Change], rejected: [String]) {
        var acc: [Change] = [], rej: [String] = []
        let pullRange: ClosedRange<Int>? = dyno.pulls.isEmpty ? nil :
            (dyno.pulls.map(\.rpmStart).min()! - dyno.binRPM)...(dyno.pulls.map(\.rpmEnd).max()! + dyno.binRPM)
        for ch in raw {
            guard let t = ch["tps"] as? Int, let r = ch["rpm"] as? Int, let d = (ch["delta_pct"] as? NSNumber)?.doubleValue,
                  let row = map.tps.firstIndex(of: t), let col = map.rpm.firstIndex(of: r) else { rej.append("unknown cell \(ch)"); continue }
            let reason = ch["reason"] as? String ?? ""
            if d == 0 { continue }
            let cell = tuner.cells[row][col]
            if d < 0, cell.count >= 3, let afr = cell.meanAFR, afr > DynoEngine.leanLimitWOT, t >= 10 {
                rej.append("TPS \(t)/\(r) rpm: refused to cut fuel in a cell already lean (AFR \(String(format: "%.1f", afr)))"); continue
            }
            if let pr = pullRange, !pr.contains(r) {
                rej.append("TPS \(t)/\(r) rpm: outside the RPM range any pull measured"); continue
            }
            acc.removeAll { $0.row == row && $0.col == col }
            acc.append(Change(row: row, col: col, delta: d, reason: reason))
        }
        return (acc, rej)
    }

    /// Ask Claude for the next gradual pass and stage it into the draft.
    public func suggest(map: FuelMap, tuner: TunerEngine, dyno: DynoEngine, notes: String, context: ModelContext) async {
        guard let key = KeychainStore.get(KeychainStore.claudeKey), !key.isEmpty else { state = .failed(ClaudeClient.Error.noKey.localizedDescription); return }
        state = .thinking
        TuningDB.updateOutcomes(context, dyno: dyno)      // give past suggestions their measured verdict first
        let client = ClaudeClient(apiKey: key)
        let body = payload(map: map, tuner: tuner, dyno: dyno, notes: notes, history: TuningDB.historyForAI(context))
        do {
            let user = "Measurements (JSON):\n" + String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
                + "\n\nPropose the next pass of Fuel Adjust changes."
            let reply = try await client.structured(system: Self.system, user: user, schema: Self.schema)
            guard let obj = try JSONSerialization.jsonObject(with: reply.json) as? [String: Any] else { throw ClaudeClient.Error.noJSON }
            let (changes, rejected) = Self.filter(obj["changes"] as? [[String: Any]] ?? [], map: map, tuner: tuner, dyno: dyno)
            map.clearDraft()
            for ch in changes { map.stage(ch.row, ch.col, to: map.base[ch.row][ch.col] + ch.delta, maxStep: maxStep) }
            let applied = changes.count
            lastRejected = rejected
            lastRationale = obj["rationale"] as? String ?? ""
            lastCautions = obj["cautions"] as? [String] ?? []
            lastChanges = applied
            lastUsage = "\(reply.model) · \(reply.inputTokens) in / \(reply.outputTokens) out"
            context.insert(AISuggestion(rationale: lastRationale, proposedJSON: reply.json, applied: false))
            try? context.save()
            state = .done("\(applied) cells staged")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
