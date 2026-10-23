import Foundation
import SwiftData

/// Persistent tuning history so the copilot has memory across sessions — like a real tuner who
/// remembers what they changed last time and whether it worked. The AI reads this to learn.

@Model
public final class TuningSession {
    public var startedAt: Date
    public var endedAt: Date?
    public var notes: String              // the rider's "feel" notes
    public var ecuModel: String
    public var firmware: String
    public var samples: Int
    public var meanAbsAfrError: Double
    public var correctionMapJSON: Data    // [[Double?]] suggested % per RPM×TPS cell (nil = unvisited)
    public var sampleCountsJSON: Data     // [[Int]] samples per cell

    public init(startedAt: Date = .now, notes: String = "", ecuModel: String = "", firmware: String = "",
                samples: Int = 0, meanAbsAfrError: Double = 0,
                correctionMapJSON: Data = Data(), sampleCountsJSON: Data = Data()) {
        self.startedAt = startedAt; self.notes = notes; self.ecuModel = ecuModel; self.firmware = firmware
        self.samples = samples; self.meanAbsAfrError = meanAbsAfrError
        self.correctionMapJSON = correctionMapJSON; self.sampleCountsJSON = sampleCountsJSON
    }
}

@Model
public final class MapRevision {
    public var at: Date
    public var label: String
    public var source: String             // "ecu-read" | "manual" | "ai" | "backup"
    public var fuelMapJSON: Data          // [[Double]] % 11×18

    public init(at: Date = .now, label: String = "", source: String = "", fuelMapJSON: Data = Data()) {
        self.at = at; self.label = label; self.source = source; self.fuelMapJSON = fuelMapJSON
    }
}

@Model
public final class AISuggestion {
    public var at: Date
    public var rationale: String
    public var proposedJSON: Data         // proposed per-cell deltas
    public var applied: Bool
    public var outcomeAfrError: Double     // legacy (AFR-target era), unused
    public var label: String = ""          // map revision this suggestion became when applied
    public var decision: String = "pending" // pending | kept | reverted
    public var outcomeAccelPct: Double = 0  // measured accel change vs previous revision (the real verdict)
    public var outcomeKnown: Bool = false

    public init(at: Date = .now, rationale: String = "", proposedJSON: Data = Data(),
                applied: Bool = false, outcomeAfrError: Double = -1) {
        self.at = at; self.rationale = rationale; self.proposedJSON = proposedJSON
        self.applied = applied; self.outcomeAfrError = outcomeAfrError
    }
}

@Model
public final class AccelPull {
    public var at: Date
    public var duration: Double
    public var rpmStart: Int
    public var rpmEnd: Int
    public var gearRatio: Double
    public var minAFR: Double
    public var maxAFR: Double
    public var mapLabel: String
    public var curveJSON: Data            // [BinAccel]
    public var gear: Int = 0              // 0 = unknown
    public var meanRPM: Double = 0
    public var meanVSS: Double = 0
    public var gradeKnown: Bool = false   // watch fusion results
    public var grade: Double = 0
    public var segment: String = ""
    public var correctedJSON: Data = Data()
    public init(at: Date, duration: Double, rpmStart: Int, rpmEnd: Int, gearRatio: Double, minAFR: Double, maxAFR: Double, mapLabel: String, curveJSON: Data, gear: Int = 0) {
        self.at = at; self.duration = duration; self.rpmStart = rpmStart; self.rpmEnd = rpmEnd; self.gearRatio = gearRatio
        self.minAFR = minAFR; self.maxAFR = maxAFR; self.mapLabel = mapLabel; self.curveJSON = curveJSON; self.gear = gear
    }
}

public enum TuningDB {
    /// All model types, for the ModelContainer.
    public static let models: [any PersistentModel.Type] = [TuningSession.self, MapRevision.self, AISuggestion.self, AccelPull.self]

    /// A persistent container; falls back to in-memory if the store can't open.
    @MainActor public static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        if let c = try? ModelContainer(for: schema) { return c }
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Compact history for the AI payload: revisions, suggestions with their MEASURED verdict, rider notes.
    /// Deliberately carries no AFR-target error maps — the objective is acceleration, AFR is a guard.
    @MainActor
    public static func historyForAI(_ context: ModelContext, limit: Int = 10) -> [String: Any] {
        func fetch<T: PersistentModel>(_ type: T.Type, _ sort: [SortDescriptor<T>]) -> [T] {
            var d = FetchDescriptor<T>(sortBy: sort); d.fetchLimit = limit
            return (try? context.fetch(d)) ?? []
        }
        let iso = ISO8601DateFormatter()
        let sessions = fetch(TuningSession.self, [SortDescriptor(\.startedAt, order: .reverse)])
        let revisions = fetch(MapRevision.self, [SortDescriptor(\.at, order: .reverse)])
        let suggestions = fetch(AISuggestion.self, [SortDescriptor(\.at, order: .reverse)])
        return [
            "rider_notes_history": sessions.filter { !$0.notes.isEmpty }.map { ["at": iso.string(from: $0.startedAt), "notes": $0.notes] },
            "revisions": revisions.map { ["at": iso.string(from: $0.at), "label": $0.label, "source": $0.source] },
            "past_suggestions": suggestions.map { a -> [String: Any] in
                ["at": iso.string(from: a.at), "rationale": a.rationale, "decision": a.decision, "label": a.label,
                 "proposed": (try? JSONSerialization.jsonObject(with: a.proposedJSON)) ?? [:],
                 "measured_accel_pct_vs_previous": a.outcomeKnown ? a.outcomeAccelPct : NSNull()]
            },
        ]
    }

    /// The newest suggestion still waiting for a decision (the one whose cells are in the draft).
    @MainActor public static func pendingSuggestion(_ context: ModelContext) -> AISuggestion? {
        var d = FetchDescriptor<AISuggestion>(predicate: #Predicate { $0.decision == "pending" }, sortBy: [SortDescriptor(\.at, order: .reverse)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Close the loop: give every kept suggestion the acceleration verdict its revision earned.
    @MainActor public static func updateOutcomes(_ context: ModelContext, dyno: DynoEngine) {
        let labels = dyno.labels
        var fd = FetchDescriptor<AISuggestion>(predicate: #Predicate { $0.decision == "kept" && !$0.outcomeKnown }, sortBy: [SortDescriptor(\.at, order: .reverse)])
        fd.fetchLimit = 20
        let kept = (try? context.fetch(fd)) ?? []
        for s in kept {
            guard let i = labels.firstIndex(of: s.label), i + 1 < labels.count else { continue }
            let cmp = dyno.compare(label: labels[i], with: labels[i + 1])
            guard !cmp.isEmpty else { continue }
            s.outcomeAccelPct = cmp.map(\.pct).reduce(0, +) / Double(cmp.count); s.outcomeKnown = true
        }
        try? context.save()
    }
}
