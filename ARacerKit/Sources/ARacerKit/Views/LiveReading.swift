import Foundation

/// One live value prepared for display: its slot, current value, and recent history.
/// Built in `LiveGrid` so each cell gets only its own data, not the whole session.
struct LiveReading: Identifiable {
    let id: UInt16          // the slot's CANopen index, stable across updates
    let slot: StreamSlot
    let value: UInt32?
    let history: [Double]
}
