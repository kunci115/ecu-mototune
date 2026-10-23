import Foundation
import SwiftUI
import ARacerKit
import ConnectIQ

/// Garmin Connect IQ bridge (iOS only). Pairs a watch through Garmin Connect, pushes a 1 Hz ECU
/// snapshot to the MotoTune Ride watch app, and receives feel markers + heart rate back.
@MainActor @Observable
final class GarminLink: NSObject, WatchLink, IQDeviceEventDelegate, IQAppMessageDelegate, IQUIOverrideDelegate {
    static let urlScheme = "mototune-ciq"
    static let watchAppUUID = UUID(uuidString: "414C7FCB-2468-4064-9889-627F8BB07A13")!   // = manifest id of garmin/MotoTuneRide
    private static let devicesKey = "garmin.devices"

    private(set) var statusText = "No watch paired"
    private(set) var isReady = false
    var isPaired: Bool { app != nil }
    func refresh() { refreshAppStatus() }
    private(set) var lastMarkerAt: Date?
    private var devices: [IQDevice] = []
    private var app: IQApp?
    private var pushTask: Task<Void, Never>?
    private weak var session: ECUSession?
    private var lastSend = Date.distantPast
    private var sendInFlight = false

    func start(session: ECUSession) {
        self.session = session
        session.watch = self
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: self)
        if let data = UserDefaults.standard.data(forKey: Self.devicesKey),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, IQDevice.self], from: data) as? [IQDevice] {
            attach(saved)
        }
        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.pushSnapshot()
            }
        }
    }

    // MARK: WatchLink
    func pair() { ConnectIQ.sharedInstance().showDeviceSelection() }
    func openWatchApp() {
        guard let app else { return }
        ConnectIQ.sharedInstance().openAppRequest(app) { [weak self] result in
            Task { @MainActor in self?.statusText = result == .success ? "Opening MotoTune Ride on the watch…" : "Could not open the watch app (\(result.rawValue))" }
        }
    }

    func sendTest() {
        guard let app else { statusText = "Pair a watch first"; return }
        let afr = Int.random(in: 110...145), rpm = Int.random(in: 1800...9800)
        let fake: [String: Any] = ["rpm": rpm, "afr": afr, "tgt": 125, "tps": Int.random(in: 5...100), "gear": Int.random(in: 1...6), "pulls": 2, "map": "test",
                                   "lean": afr >= 136 ? 1 : 0, "ecu": 1, "spd": rpm / 90, "bpw": 246]
        statusText = "Sending test: AFR \(Double(afr) / 10) · \(rpm) rpm…"
        ConnectIQ.sharedInstance().sendMessage(fake, to: app, progress: nil) { [weak self] result in
            Task { @MainActor in
                if result == .success { self?.isReady = true }
                self?.statusText = result == .success ? "Delivered: AFR \(Double(afr) / 10) · \(rpm) rpm — check the watch face" : "Send failed: \(Self.describe(result))"
            }
        }
    }
    private static func describe(_ r: IQSendMessageResult) -> String {
        switch r {
        case .success: "ok"
        case .failure_AppNotFound: "MotoTune Ride not found on the watch"
        case .failure_DeviceNotAvailable: "watch not reachable"
        case .failure_DeviceIsBusy: "watch busy"
        case .failure_Timeout: "timeout"
        case .failure_UnsupportedType: "unsupported message"
        default: "error \(r.rawValue)"
        }
    }

    /// Garmin Connect returns the chosen devices through our URL scheme.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == Self.urlScheme else { return false }
        let list = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice] ?? []
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: list as NSArray, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.devicesKey)
        }
        attach(list)
        return true
    }

    private func attach(_ list: [IQDevice]) {
        ConnectIQ.sharedInstance().unregister(forAllDeviceEvents: self)
        ConnectIQ.sharedInstance().unregister(forAllAppMessages: self)
        devices = list; app = nil; isReady = false
        guard let device = list.first else { statusText = "No watch paired"; return }
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        let a = IQApp(uuid: Self.watchAppUUID, store: Self.watchAppUUID, device: device)
        app = a
        ConnectIQ.sharedInstance().register(forAppMessages: a, delegate: self)
        statusText = "\(device.friendlyName ?? device.modelName ?? "Garmin") · checking…"
        refreshAppStatus()
    }

    private func refreshAppStatus() {
        guard let app, let device = devices.first else { return }
        let status = ConnectIQ.sharedInstance().getDeviceStatus(device)
        guard status == .connected else { isReady = false; statusText = "\(device.friendlyName ?? "Watch") · \(Self.describe(status))"; return }
        ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                let installed = st?.isInstalled ?? false
                self.isReady = installed
                self.statusText = "\(device.friendlyName ?? "Watch") · connected · " + (installed ? "MotoTune Ride v\(st?.version ?? 0)" : (st == nil ? "app status timed out" : "MotoTune Ride not reported (sideloaded apps often aren't) — try Send test"))
            }
        }
    }

    private static func describe(_ s: IQDeviceStatus) -> String {
        switch s {
        case .connected: "connected"
        case .notConnected: "not connected"
        case .notFound: "not found"
        case .bluetoothNotReady: "Bluetooth off"
        default: "invalid"
        }
    }

    // MARK: phone → watch, 1 Hz, only when something is live and the previous send finished
    private func pushSnapshot() {
        guard let app, let session, session.state == .connected, !sendInFlight,
              Date().timeIntervalSince(lastSend) >= 1 else { return }
        sendInFlight = true; lastSend = Date()
        ConnectIQ.sharedInstance().sendMessage(session.watchSnapshot, to: app, progress: nil) { [weak self] result in
            Task { @MainActor in
                self?.sendInFlight = false
                if result == .failure_AppNotFound || result == .failure_DeviceNotAvailable { self?.refreshAppStatus() }
            }
        }
    }

    // MARK: delegates
    nonisolated func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        Task { @MainActor in self.refreshAppStatus() }
    }
    nonisolated func deviceCharacteristicsDiscovered(_ device: IQDevice) {}
    nonisolated func needsToInstallConnectMobile() {
        Task { @MainActor in self.statusText = "Install the Garmin Connect app first"; ConnectIQ.sharedInstance().showAppStoreForConnectMobile() }
    }
    nonisolated func receivedMessage(_ message: Any, from app: IQApp) {
        Task { @MainActor in
            guard let d = message as? [String: Any] else { return }
            let hr = (d["hr"] as? NSNumber).map { Int(truncating: $0) }.flatMap { $0 > 0 ? $0 : nil }
            if let t = d["mark"] as? NSNumber {
                let at = Date(timeIntervalSince1970: TimeInterval(truncating: t))
                self.session?.addWatchMarker(at: at, hr: hr); self.lastMarkerAt = at
            } else {
                self.session?.updateWatch(hr: hr, recording: ((d["rec"] as? NSNumber)?.intValue ?? 0) == 1)
            }
        }
    }
}
