import SwiftUI

/// A key on the left (dim) and a monospaced value on the right.
struct LabeledRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).font(.system(size: 13)).foregroundStyle(Theme.Palette.textDim)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Palette.text)
        }
    }
}
