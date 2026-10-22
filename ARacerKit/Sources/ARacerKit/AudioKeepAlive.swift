import Foundation
#if os(iOS)
import AVFoundation

/// Keeps the app running while the screen is locked by holding a silent, looping audio session.
/// Held for the whole ECU session (tuner/dyno learn in the background too); `.mixWithOthers` so it never interrupts the rider's music.
final class AudioKeepAlive {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(data: Self.silentWAV())
        player?.numberOfLoops = -1
        player?.volume = 0
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// ~0.5 s of silent 8 kHz mono 16-bit PCM in a WAV container.
    private static func silentWAV() -> Data {
        let sampleRate = 8000, seconds = 1, channels = 1, bits = 16
        let dataBytes = sampleRate * seconds * channels * bits / 8
        var d = Data()
        func put(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        put("RIFF"); u32(UInt32(36 + dataBytes)); put("WAVE")
        put("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * bits / 8))
        u16(UInt16(channels * bits / 8)); u16(UInt16(bits))
        put("data"); u32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))
        return d
    }
}
#else
final class AudioKeepAlive { func start() {}; func stop() {} }
#endif
