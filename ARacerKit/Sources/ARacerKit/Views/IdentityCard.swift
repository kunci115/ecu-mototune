import SwiftUI

/// Bridge and ECU identity read over SDO.
struct IdentityCard: View {
    let session: ECUSession
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("ECU").eyebrow()
            VStack(spacing: Theme.Space.sm) {
                LabeledRow(key: "Bridge", value: session.info?.name ?? "–")
                LabeledRow(key: "Model", value: session.info.map { "\($0.model?.rawValue ?? "?")  ·  node \($0.node ?? 0)" } ?? "–")
                LabeledRow(key: "Serial", value: session.info?.serialHex ?? "–")
                LabeledRow(key: "Firmware", value: session.identity?.firmware ?? "–")
                if let state = session.nmtState { LabeledRow(key: "Status", value: nmtLabel(state)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
    private func nmtLabel(_ s: UInt8) -> String {
        switch s { case 5: "operational"; case 0x7F: "pre-operational"; default: "state " + String(s, radix: 16, uppercase: true) }
    }
}
