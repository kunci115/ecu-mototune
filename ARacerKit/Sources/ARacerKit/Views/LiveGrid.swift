import SwiftUI

/// Adaptive grid of live values from the TPDO stream.
struct LiveGrid: View {
    let session: ECUSession
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(readings) { LiveValueCell(reading: $0) }
        }
    }

    /// Pair each slot with its current value and history so cells stay decoupled from the session.
    private var readings: [LiveReading] {
        session.slots.enumerated().map { index, slot in
            LiveReading(
                id: slot.index,
                slot: slot,
                value: session.latest.flatMap { $0.values.indices.contains(index) ? $0.values[index] : nil },
                history: session.history.series(slot: index)
            )
        }
    }
}
