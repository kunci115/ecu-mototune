import Foundation

/// A wrist companion the app can talk to. Implemented in the iOS target with Garmin's Connect IQ
/// SDK (binary, iOS-only); the cross-platform kit sees only this.
@MainActor
public protocol WatchLink: AnyObject {
    var statusText: String { get }      // "Forerunner 265 · connected · app installed"
    var isReady: Bool { get }
    var isPaired: Bool { get }
    func refresh()
    func pair()                         // opens the device picker (Garmin Connect) and returns via URL
    func openWatchApp()                 // asks the watch to launch MotoTune Ride
    func sendTest()                     // one fake snapshot, to prove the phone → watch → face path without the bike
}
