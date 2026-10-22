import Foundation

/// How a table's RAW cell bytes become an engineering value, and what its axes are.
/// Established from DOMAIN KNOWLEDGE + the real dump, NOT from the encrypted definition:
///   · Target AFR raw 120–133 ÷10 = 12.0–13.3 AFR (owner: AFR runs 10 lean … 14 rich, floats ~12.8) ✓
///   · Spark raw 80–160 (2-byte) ÷10 = 8.0–16.0° advance ✓
///   · Fuel adjust centres on 0x80=128 → 100 % (multiplier)
/// `confidence`: strong = value range matches physics; medium = plausible, confirm by re-dump diff.
public struct TableScaling: Sendable {
    public enum Axis: String, Sendable { case tps = "TPS", rpm = "RPM", gear = "Gear", none = "" }
    public var cellBytes: Int
    public var scale: Double
    public var offset: Double
    public var unit: String
    public var decimals: Int
    public var rowAxis: Axis
    public var colAxis: Axis
    public var confidence: String
    public var note: String

    public func value(_ raw: Int) -> Double { Double(raw) * scale + offset }
    public func text(_ raw: Int) -> String { String(format: "%.\(decimals)f", value(raw)) }
}

public enum Scaling {
    /// Table id (index − 0x3000) → scaling. Tables not listed are shown raw.
    public static let byID: [Int: TableScaling] = [
        19:  .init(cellBytes: 1, scale: 100.0/128.0, offset: 0, unit: "%", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "strong", note: "0x80=128 → 100 (cocok app resmi)"),
        54:  .init(cellBytes: 1, scale: 0.1, offset: 0, unit: "AFR", decimals: 1, rowAxis: .tps, colAxis: .rpm, confidence: "strong", note: "÷10; cocok rentang AFR 10–14"),
        133: .init(cellBytes: 2, scale: 0.1, offset: 0, unit: "°",   decimals: 1, rowAxis: .tps, colAxis: .rpm, confidence: "strong", note: "÷10 derajat advance"),
        4:   .init(cellBytes: 2, scale: 100.0/128.0, offset: 0, unit: "%", decimals: 1, rowAxis: .tps, colAxis: .rpm, confidence: "medium", note: "0x80=128 → 100%; lebar kolom belum cocok ke ScaleData, konfirmasi via diff"),
        8:   .init(cellBytes: 2, scale: 1, offset: 0, unit: "rpm", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "strong", note: "terbaca 12000"),
        21:  .init(cellBytes: 1, scale: 100.0/128.0, offset: 0, unit: "%", decimals: 0, rowAxis: .none, colAxis: .rpm, confidence: "medium", note: "accel fuel, 128=100%"),
        41:  .init(cellBytes: 1, scale: 100.0/128.0, offset: 0, unit: "%", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "medium", note: "temp comp vs T_Eng, 9 breakpoints, 128=100%"),
        // ---- scalars / vectors read from the dump 2026-10-22; scaling by domain knowledge, flagged by confidence ----
        20:  .init(cellBytes: 1, scale: 10, offset: 800, unit: "rpm", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "low", note: "raw 90 → 1700 rpm (×10+800) matches measured idle 1698; confirm in official app"),
        37:  .init(cellBytes: 1, scale: 50, offset: 0, unit: "rpm", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "low", note: "VVA switch point: raw 146 → 7300 rpm (×50) plausible for Yamaha VVA; confirm"),
        28:  .init(cellBytes: 1, scale: 1, offset: 0, unit: "°C", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "medium", note: "fan-on temperature, raw 110 °C"),
        33:  .init(cellBytes: 1, scale: 1, offset: 0, unit: "raw", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "low", note: "speedo gain factor raw 67; unit unknown"),
        22:  .init(cellBytes: 1, scale: 1, offset: 0, unit: "on/off", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "strong", note: "decel fuel cut-off enable, 0 = off"),
        14:  .init(cellBytes: 1, scale: 1, offset: 0, unit: "on/off", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "strong", note: "AutoLearn enable, 0 = off (owner does not use it)"),
        1059: .init(cellBytes: 1, scale: 1, offset: 0, unit: "on/off", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "strong", note: "wideband closed-loop enable, 0 = off"),
        1283: .init(cellBytes: 1, scale: 1, offset: 0, unit: "on/off", decimals: 0, rowAxis: .none, colAxis: .none, confidence: "strong", note: "AF2 sensor heater, 1 = on"),
        72:  .init(cellBytes: 1, scale: 0.01, offset: 0, unit: "ms", decimals: 2, rowAxis: .none, colAxis: .none, confidence: "medium", note: "injector dead time vs battery voltage, 17 points, falling 1.95→0.16: ×0.01 ms assumed"),
        61:  .init(cellBytes: 1, scale: 1, offset: 0, unit: "raw", decimals: 0, rowAxis: .tps, colAxis: .rpm, confidence: "low", note: "constant 135 everywhere; crank-degree injection end angle? unit unconfirmed"),
        1309: .init(cellBytes: 2, scale: 1, offset: 0, unit: "raw", decimals: 0, rowAxis: .none, colAxis: .rpm, confidence: "low", note: "19 words, all zero on this ECU (unused / unlicensed)"),
    ]
    public static func cellBytes(id: Int, fallback: Int) -> Int { byID[id]?.cellBytes ?? fallback }
}
