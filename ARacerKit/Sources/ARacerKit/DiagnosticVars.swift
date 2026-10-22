import Foundation

/// A broad set of live variables streamed while logging, so unmapped variables can be
/// identified later by correlating with RPM, throttle and temperature changes.
/// 64 objects (incl. the gauge-bound ids 87,130,144,973,1398 the official app monitors),
/// 95 payload bytes — within the TPDO limit of 64 objects / 512 bytes. Sizes from the real dump.
public enum DiagnosticVars {
    /// The confirmed tuning channels (same as the dashboard): small = few TPDO frames per sample
    /// = robust over moving Wi-Fi, and byte-sizes verified via per-variable SDO reads.
    public static var entries: [(UInt16, Int)] { KnownVariables.all.map { ($0.index, $0.size) } }

    public static var slots: [StreamSlot] {
        entries.map { index, size in
            let id = Int(index) - 0x4000
            return StreamSlot(index: index, size: size, name: KnownVariables.byID(id)?.name ?? "VAR \(id)")
        }
    }

    /// Total payload bytes per sample.
    public static var payloadBytes: Int { entries.reduce(0) { $0 + $1.1 } }

    /// Sidecar metadata so a binary log decodes losslessly.
    public static func sidecar(startedAt: Date) -> Data {
        let vars: [[String: Any]] = entries.map { index, size in
            let id = Int(index) - 0x4000
            return ["id": id, "index": Int(index), "size": size, "name": KnownVariables.byID(id)?.name ?? "VAR \(id)"]
        }
        let dict: [String: Any] = [
            "format": "mototune-log-v1",
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "record": "uint32 LE ms-since-start, then payload (vars in order, BIG-endian unsigned — TPDO stream byte order)",
            "payloadBytes": payloadBytes,
            "note": "AF2 wideband AFR only valid once engine temp (id 33 T_Eng) reaches ~45-60C; gate AFR on that.",
            "vars": vars,
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
