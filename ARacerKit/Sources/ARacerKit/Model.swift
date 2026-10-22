import Foundation

public enum ECUModel: String, Sendable {
    case miniX = "RC MiniX", superX = "RC SuperX", superXPro = "RC SuperX Pro"
    case familyB6 = "family B6", familyB3 = "family B3", familyB5 = "family B5"

    /// Model and CANopen node id from the first byte of the bridge serial.
    public static func from(serialByte b: UInt8) -> (ECUModel, UInt8)? {
        switch b {
        case 0xA6: return (.miniX, 1)
        case 0xA3: return (.superX, 2)
        case 0xA4: return (.superXPro, 4)
        case 0xA5: return (.superXPro, 5)
        case 0xB6: return (.familyB6, 33)
        case 0xB3: return (.familyB3, 34)
        case 0xB5: return (.familyB5, 37)
        default: return nil
        }
    }
}

public struct BridgeInfo: Sendable, Equatable {
    public var bridgeVersion: UInt8
    public var bridgeSub: UInt8
    public var name: String
    public var productCode: UInt32
    public var serial: [UInt8]
    public var model: ECUModel?
    public var node: UInt8?
    public var serialHex: String { serial.map { String(format: "%02X", $0) }.joined() }
}

/// 0x1018 fields the app reads on connect (sub-index → name, size).
public struct ECUIdentity: Sendable, Equatable {
    public var productCode: UInt32 = 0, tableID: UInt32 = 0
    public var verV: UInt16 = 0, verS: UInt16 = 0, verC: UInt16 = 0, verA: UInt16 = 0
    public var ecuSerial: [UInt8] = []
    public var ownedFunctions: UInt32 = 0, trialFunctions: UInt32 = 0, factoryFunctions: UInt32 = 0
    public var orderSerial: UInt32 = 0
    public var deviceName: String = ""
    public var firmware: String { String(format: "%02d.%03d.%02d.%02d", verV, verS, verC, verA) }
    public init() {}
}

public enum Licence {
    public static let miniXBits: [Int: String] = [
        0: "FuelBase", 1: "EngVehSetting", 2: "Fuel3D", 3: "Spark3D", 4: "InjAngle", 5: "FuelComp",
        6: "BackFire", 7: "AutoTune", 8: "TagAFR", 9: "NBCLC", 10: "LaunchControl", 11: "PitLimit",
        12: "QuickShifter", 13: "TSC", 14: "RButton", 15: "HPower", 16: "HighIdle", 17: "ExupD3Control",
        18: "TSCPlus", 20: "ServiceInterval"]
    public static let miniXXBits: [Int: String] = [
        0: "EngVehSettings", 3: "AutoTune2", 4: "RideModeMatrix", 5: "RealTimePower", 6: "ServiceAlert",
        7: "ECUDynamicLED", 8: "YAMAHA_eBoostAdv", 9: "InjectionTiming", 10: "BackFire_Motion",
        12: "NBO2CL", 13: "EXUP", 14: "TractionPlus", 16: "InjectorCal"]

    public static func names(_ word: UInt32, node: UInt8?) -> [String] {
        let table = [33, 34, 37].contains(Int(node ?? 0)) ? miniXXBits : miniXBits
        return (0..<32).filter { word >> UInt32($0) & 1 == 1 }.map { table[$0] ?? "bit\($0)" }
    }
}

/// Object-dictionary addressing used by the app's definition files.
public enum ObjectIndex {
    public static func table(_ id: Int) -> UInt16 { UInt16(0x3000 + id) }
    public static func variable(_ id: Int) -> UInt16 { UInt16(0x4000 + id) }
}
