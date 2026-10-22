import SwiftUI

/// A single live reading as a telemetry tile: name, big mono value, unit, accent sparkline.
struct LiveValueCell: View {
    let reading: LiveReading
    private var known: KnownVariable? { KnownVariables.byID(Int(reading.slot.index) - 0x4000) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 4) {
                Text(reading.slot.name).eyebrow().lineLimit(1)
                if let c = known?.confidence, c != .strong {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(c == .guess ? Theme.Palette.warn : Theme.Palette.textDim)
                        .accessibilityLabel(c == .guess ? "scale not confirmed" : "candidate, not yet confirmed")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(valueText)
                    .font(Theme.display(27, .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.Palette.text).contentTransition(.numericText())
                if let unit = known?.unit, !unit.isEmpty {
                    Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Palette.textDim)
                }
            }
            Sparkline(values: reading.history)
                .frame(height: 30).foregroundStyle(Theme.Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Space.md)
    }

    private var valueText: String {
        guard let value = reading.value else { return "–" }
        let d = known?.display(value) ?? Double(value)
        return d.formatted(.number.precision(.fractionLength(known?.decimals ?? 0)))
    }
}
