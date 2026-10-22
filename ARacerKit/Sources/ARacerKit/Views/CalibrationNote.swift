import SwiftUI

/// How the numbers on screen were derived — scaling source, confidence, and whether the axes are confirmed.
struct CalibrationNote: View {
    let scaling: TableScaling?
    var axes: TableAxes? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("How these values were derived").eyebrow()
            if let scaling {
                Label(scaling.note, systemImage: scaling.confidence == "strong" ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.confidenceColor(scaling.confidence))
            } else {
                Label("Raw bytes — scale and unit not calibrated yet.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.Palette.warn)
            }
            if let axes {
                Label(axes.confirmed ? "Axes confirmed against the official app (TPS 0–100 × RPM 800–16000)."
                                     : "Axes inferred from the table shape — not yet matched to the official app.",
                      systemImage: axes.confirmed ? "checkmark.seal" : "questionmark.circle")
                    .font(.caption).foregroundStyle(axes.confirmed ? Theme.Palette.good : Theme.Palette.warn)
            }
            Text("From tuning knowledge and the ECU dump — never from the encrypted vendor file.")
                .font(.caption2).foregroundStyle(Theme.Palette.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card(padding: Theme.Space.md)
    }
}
