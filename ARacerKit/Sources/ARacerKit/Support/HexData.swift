import Foundation

extension Array where Element == UInt8 {
    /// Parse a hex string such as "a6 05" or "a605" into bytes.
    init(hexString: String) {
        let clean = hexString.replacing(" ", with: "")
        self = stride(from: 0, to: clean.count, by: 2).compactMap {
            let i = clean.index(clean.startIndex, offsetBy: $0)
            let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            return UInt8(clean[i..<j], radix: 16)
        }
    }
}
