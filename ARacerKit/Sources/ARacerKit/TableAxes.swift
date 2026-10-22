import Foundation

/// Displayed axis breakpoints for a table, recovered by matching our raw dump to the official
/// app's on-screen grid (NOT from the encrypted file). The ECU stores more rows/cols than shown;
/// the display is the top-left crop of `rows.count` × `cols` cells.
public struct TableAxes: Sendable {
    public var tps: [Int]     // rows, top to bottom
    public var rpm: [Int]     // columns, left to right
    public var confirmed: Bool = true   // true = matched to official screenshots; false = inferred from row count
}

public enum Axes {
    /// 20 RPM columns: every grid table in the dump is 20 cells wide and rows 15–16 of Fuel Adjust carry
    /// real data out to column 19 — so the axis runs 800…16000, not 14400 (2026-10-22 dump re-read).
    static let rpm20 = (1...20).map { $0 * 800 }
    /// 17 TPS rows: Fuel Adjust rows 0–16 hold real data (17–24 are 100 % padding) and AFR/Injection/Spark
    /// all have exactly 17 sub-indices. Rows 0–10 match the official grid (0…40); 50…100 are inferred —
    /// Confirmed by the owner from the official app (last row 100, last column 16000).
    static let tps17 = [0, 2, 4, 6, 8, 10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100]
    /// Table id → axes.
    public static let byID: [Int: TableAxes] = [
        4:   .init(tps: tps17, rpm: rpm20),                      // Fuel adjust: 0–100 × 800–16000 confirmed by owner 2026-10-22
        54:  .init(tps: tps17, rpm: rpm20, confirmed: false),   // Target AFR: 17×20 raw; official showed 9 labels — verify
        61:  .init(tps: tps17, rpm: rpm20, confirmed: false),   // Injection angle
        133: .init(tps: tps17, rpm: rpm20, confirmed: false),   // Spark 3D
    ]
}
