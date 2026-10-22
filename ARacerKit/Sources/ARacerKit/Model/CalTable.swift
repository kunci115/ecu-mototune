import Foundation

/// One tuning table as read from the ECU dump. Values are RAW; axis labels and cell scaling
/// come from `Scaling`/domain knowledge, never from the encrypted vendor definition file.
struct CalTable: Decodable, Identifiable {
    var name: String
    var id: Int
    var index: Int?
    var present: Bool
    var rows: Int?
    var rowlen: Int?
    var cell: Int?
    var cols: Int?
    var kind: String?
    var licence_bit: Int?
    var screen: String?
    var values_hex: [String: String]?

    /// Decode every stored row into integers, reading 1- or 2-byte little-endian cells.
    func grid(cell cs: Int) -> [[Int]] {
        guard let values_hex else { return [] }
        return values_hex.keys.compactMap { Int($0) }.sorted().map { sub in
            let bytes = [UInt8](hexString: values_hex[String(sub)] ?? "")
            if cs == 2 {
                return stride(from: 0, to: bytes.count - 1, by: 2).map { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
            }
            return bytes.map(Int.init)
        }
    }
}
