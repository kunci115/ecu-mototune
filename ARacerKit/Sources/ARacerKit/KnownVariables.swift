import Foundation

/// A variable whose identity we established WITHOUT decrypting the vendor definition file:
/// only from cleartext in the app (gauge bindings `dVar.p(id)`, behaviour in the code,
/// `ScaleData.xml`, SharedPreferences channel defaults). `confidence` says how sure we are.
public struct KnownVariable: Sendable {
    public enum Confidence: String, Sendable { case strong, guess, candidate }   // candidate = inferred from log statistics, unconfirmed
    public var id: Int
    public var name: String
    public var unit: String
    public var size: Int
    public var confidence: Confidence
    public var source: String
    public var scale: Double = 1
    public var decimals: Int = 0
    public var offset: Double = 0
    public var inDefaultStream = true
    /// The live value scaled for display.
    public func display(_ raw: UInt32) -> Double { Double(raw) * scale + offset }
    public var index: UInt16 { UInt16(0x4000 + id) }
}

public enum KnownVariables {
    /// Anchors proven from app code / cleartext assets. Not a full dictionary; the full
    /// name↔id map lives in the encrypted ControlFile and is deliberately not reproduced here.
    public static let all: [KnownVariable] = [
        .init(id: 26,  name: "RPM",        unit: "rpm", size: 2, confidence: .strong, source: "p(26)+official; idle 1698", scale: 1,    decimals: 0),
        .init(id: 55,  name: "AFR",        unit: "AFR", size: 2, confidence: .strong, source: "id55 ride: idle 12.60 = official AFR_WBO2 (AF2; valid when warm)", scale: 0.01, decimals: 1),
        .init(id: 774, name: "AFR Target", unit: "AFR", size: 2, confidence: .strong, source: "id774 ride: 13.30 idle -> richer under load = official AFR_Target", scale: 0.01, decimals: 1),
        .init(id: 33,  name: "T_Eng",      unit: "°C",  size: 1, confidence: .strong, source: "id33; 92-101C on ride", scale: 1, decimals: 0),
        .init(id: 51,  name: "Speed",      unit: "km/h", size: 2, confidence: .guess,  source: "VSS: raw/256 (8.8 fixed-point) matches owner's 20-40 km/h ride; confirm vs speedometer", scale: 1.0/256.0, decimals: 0),
        .init(id: 369, name: "TPS",        unit: "%",   size: 1, confidence: .strong, source: "confirmed live: tracks throttle, 0 at idle (id369); axis 0–100 confirmed", scale: 1, decimals: 0),
        // ---- candidates from the 64-var ride log statistics (2026-10-22). Verify before trusting. ----
        .init(id: 130, name: "Gear",       unit: "",    size: 1, confidence: .candidate, source: "0–6 integer, official gauge-bound, rises with rpm (r=0.40): gear position, 0=neutral", scale: 1, decimals: 0),
        .init(id: 23,  name: "BPW",        unit: "ms",  size: 2, confidence: .candidate, source: "0–343, mean 248, 0 during decel cut, r_rpm 0.50: injector pulse width ×0.01 ms", scale: 0.01, decimals: 2),
        .init(id: 25,  name: "Battery",    unit: "V",   size: 2, confidence: .candidate, source: "1044–1208, rises with rpm (r=0.80, charging): ×0.01 V", scale: 0.01, decimals: 2, inDefaultStream: false),
        .init(id: 1,   name: "T_Air",      unit: "°C",  size: 1, confidence: .candidate, source: "steady ≈32 while T_Eng 92–101: intake/ambient air temp", scale: 1, decimals: 0, inDefaultStream: false),
        .init(id: 58,  name: "TempComp",   unit: "%",   size: 1, confidence: .candidate, source: "131–134, r_T_Eng −0.95: temperature fuel compensation, 128=100 %", scale: 100.0/128.0, decimals: 1, inDefaultStream: false),
        .init(id: 45,  name: "CrankPeriod", unit: "µs", size: 2, confidence: .candidate, source: "8134–25640, ∝ 1/rpm (r=−0.63; 7660 rpm → 7832 µs/rev): revolution period", scale: 1, decimals: 0, inDefaultStream: false),
    ]

    public static func byID(_ id: Int) -> KnownVariable? { all.first { $0.id == id } }

    /// Cleartext variable names shipped in ScaleData.xml, for reference / the "rename" picker.
    /// These are names only; their numeric ids are not known without the encrypted file.
    public static let scaleDataNames = [
        "RPM", "Eng_AP", "dTPS", "T_Eng", "P_Atm", "Volt", "TPSX", "TPS_Pct", "Gear",
        "Vacuum", "O2ErrorVolt", "RPMError", "IACAirFlow", "IACCommDuty", "T_Air",
        "BPW", "VSS", "GearNum", "TC_Level", "Angle", "AngularV", "APS_Pct",
    ]

    /// Default dashboard/stream set: lean on purpose (≤ 2 TPDO frames). Diagnostics-only vars stay out.
    public static var defaultSlots: [StreamSlot] {
        all.filter(\.inDefaultStream).map { StreamSlot(index: $0.index, size: $0.size, name: $0.name) }
    }
}
