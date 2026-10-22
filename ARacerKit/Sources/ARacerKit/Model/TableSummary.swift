import Foundation

/// A catalog table decoded ONCE for display: scaled values, shape, category, confidence, stats.
/// Built when the Tables tab appears (18 tables) so list rows and previews never re-decode hex.
struct TableSummary: Identifiable {
    enum Category: String, CaseIterable { case fuel = "Fuel", ignition = "Ignition", airFuel = "Air / Fuel", engine = "Engine" }
    enum Shape { case scalar, vector(Int), grid(rows: Int, cols: Int) }

    let table: CalTable
    let scaling: TableScaling?
    let axes: TableAxes?
    let values: [[Double]]      // scaled, cropped to the display axes when known
    let raw: [[Int]]
    let shape: Shape
    let category: Category

    var id: Int { table.id }
    var name: String { table.name }
    var unit: String { scaling?.unit ?? "raw" }
    var confidence: String { scaling?.confidence ?? "none" }
    var isBoolean: Bool { scaling?.unit == "on/off" }
    var flat: [Double] { values.flatMap { $0 } }
    var min: Double { flat.min() ?? 0 }
    var max: Double { flat.max() ?? 0 }
    var mean: Double { flat.isEmpty ? 0 : flat.reduce(0, +) / Double(flat.count) }
    var isFlat: Bool { max - min < 1e-9 }
    var decimals: Int { scaling?.decimals ?? 0 }

    /// Scalar engineering value as text ("12000 rpm", "On", "1700 rpm").
    var scalarText: String {
        guard case .scalar = shape, let v = flat.first else { return "" }
        if isBoolean { return v != 0 ? "On" : "Off" }
        return String(format: "%.\(decimals)f", v) + (unit == "raw" ? "" : " \(unit)")
    }

    static func category(for id: Int) -> Category {
        switch id {
        case 19, 4, 21, 41, 72, 61: .fuel
        case 133, 37: .ignition
        case 54, 14, 1059, 1283, 22: .airFuel
        default: .engine
        }
    }

    init(_ t: CalTable) {
        table = t
        let s = Scaling.byID[t.id]; scaling = s
        axes = Axes.byID[t.id]
        let cellBytes = t.kind == "scalar" ? (t.rowlen ?? 1) : (s?.cellBytes ?? 1)
        var g = t.grid(cell: cellBytes)
        if let axes { g = g.prefix(axes.tps.count).map { Array($0.prefix(axes.rpm.count)) } }
        raw = g
        values = g.map { $0.map { s?.value($0) ?? Double($0) } }
        switch t.kind {
        case "scalar": shape = .scalar
        case "vector": shape = .vector(g.first?.count ?? 0)
        default: shape = .grid(rows: g.count, cols: g.first?.count ?? 0)
        }
        category = Self.category(for: t.id)
    }

    static func load() -> [TableSummary] { loadCatalog().filter(\.present).map(TableSummary.init) }
}
