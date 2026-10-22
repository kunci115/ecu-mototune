import Foundation

/// Editable Fuel Adjust map (0x3004) with a pending DRAFT overlay.
/// Values are percent (128 raw = 100%). Base = what the ECU currently holds; draft = staged changes
/// not yet written. The copilot and manual edits both stage into `draft`; one Write commits all.
@MainActor @Observable
public final class FuelMap {
    public let tps: [Int]
    public let rpm: [Int]
    public private(set) var base: [[Double]]        // current (ECU/dump) values, %
    public private(set) var draft: [[Double?]]       // staged new values, nil = unchanged
    public var step: Double = 2.0                    // +/- increment (like aRacer's step box)
    public let minPct = 50.0, maxPct = 160.0         // absolute clamp
    /// Full raw ECU rows (112 B each) as last read; nil while base still comes from the dump.
    public private(set) var rawRows: [[UInt8]]?
    public private(set) var source = "dump"
    public var isLive: Bool { rawRows != nil }
    public static let index: UInt16 = 0x3004

    public init(base: [[Double]], tps: [Int], rpm: [Int]) {
        self.base = base; self.tps = tps; self.rpm = rpm
        self.draft = base.map { $0.map { _ in nil } }
    }

    /// The value to show in a cell (draft if staged, else base).
    public func value(_ r: Int, _ c: Int) -> Double { draft[r][c] ?? base[r][c] }
    public func isChanged(_ r: Int, _ c: Int) -> Bool { draft[r][c] != nil && draft[r][c] != base[r][c] }
    public func delta(_ r: Int, _ c: Int) -> Double { value(r, c) - base[r][c] }

    /// Nudge a set of cells by ±step (manual + / − on a selection or block).
    public func nudge(_ cells: [(Int, Int)], by amount: Double) {
        for (r, c) in cells {
            let v = min(maxPct, max(minPct, value(r, c) + amount))
            draft[r][c] = v
        }
    }

    /// Stage an absolute value into a cell (used by AI suggestions), clamped per-pass and absolute.
    public func stage(_ r: Int, _ c: Int, to newValue: Double, maxStep: Double = 5.0) {
        let cur = base[r][c]
        let limited = min(cur + maxStep, max(cur - maxStep, newValue))   // gradual: never jump > maxStep per pass
        draft[r][c] = min(maxPct, max(minPct, limited))
    }

    public func clearDraft() { draft = base.map { $0.map { _ in nil } } }
    public var changedRows: [Int] { draft.indices.filter { r in draft[r].indices.contains { isChanged(r, $0) } } }
    public var changedCells: [(row: Int, col: Int, from: Double, to: Double)] {
        var out: [(Int, Int, Double, Double)] = []
        for r in draft.indices { for c in draft[r].indices where isChanged(r, c) { out.append((r, c, base[r][c], value(r, c))) } }
        return out
    }

    // MARK: live ECU rows
    public static func rawCell(_ pct: Double) -> UInt16 { UInt16(max(0, min(65535, (pct * 128.0 / 100.0).rounded()))) }
    public static func decodeRow(_ b: [UInt8], cols: Int) -> [Double]? {
        guard b.count >= cols * 2 else { return nil }
        return (0..<cols).map { c in Double(Int(b[c * 2]) | Int(b[c * 2 + 1]) << 8) * 100.0 / 128.0 }
    }

    /// Replace the base with rows read from the ECU (one raw 0x3004 sub-index row per TPS row). Drops the draft.
    public func load(rawRows rows: [[UInt8]], source: String = "ecu") {
        guard rows.count == tps.count else { return }
        var grid: [[Double]] = []
        for r in rows { guard let d = Self.decodeRow(r, cols: rpm.count) else { return }; grid.append(d) }
        base = grid; rawRows = rows; self.source = source; clearDraft()
    }

    /// The raw row to send for a changed TPS row: the ECU's own bytes with only the displayed cells patched,
    /// so the undisplayed tail (cols 18–55) is written back byte-identical.
    public func patchedRow(_ r: Int) -> [UInt8]? {
        guard var row = rawRows?[r] else { return nil }
        for c in rpm.indices where isChanged(r, c) {
            let v = Self.rawCell(value(r, c)); row[c * 2] = UInt8(v & 0xFF); row[c * 2 + 1] = UInt8(v >> 8)
        }
        return row
    }
    public var changedCount: Int { draft.enumerated().reduce(0) { acc, row in acc + row.element.enumerated().filter { $0.element != nil && $0.element != base[row.offset][$0.offset] }.count } }

    /// Commit the draft into base (after a successful ECU write / for preview).
    /// Load the Fuel Adjust base map from the bundled dump, cropped to its display axes.
    public static func fromCatalog() -> FuelMap? {
        guard let axes = Axes.byID[4],
              let t = loadCatalog().first(where: { $0.id == 4 }), let vh = t.values_hex else { return nil }
        var grid: [[Double]] = []
        for r in 0..<axes.tps.count {
            guard let hex = vh[String(r)] else { break }
            let b = [UInt8](hexString: hex)
            var row: [Double] = []
            for c in 0..<axes.rpm.count {
                let o = c * 2
                guard o + 1 < b.count else { break }
                row.append(Double(Int(b[o]) | Int(b[o+1]) << 8) * 100.0 / 128.0)
            }
            if row.count == axes.rpm.count { grid.append(row) }
        }
        guard grid.count == axes.tps.count else { return nil }
        return FuelMap(base: grid, tps: axes.tps, rpm: axes.rpm)
    }

    public func commit() {
        for r in base.indices { for c in base[r].indices { if let d = draft[r][c] { base[r][c] = d } } }
        clearDraft()
    }
}
