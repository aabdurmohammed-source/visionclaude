import AVFoundation
import UIKit

/// Keeps the app alive in the background by looping inaudible audio (the app declares the
/// "audio" background mode). Without this iOS suspends the app a few seconds after the
/// screen locks and the WebSocket to the Claude channel dies.
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    private var wanted = false

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionDisturbed),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(sessionDisturbed),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    func start() {
        wanted = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ensurePlaying()
            self.watchdog?.invalidate()
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.ensurePlaying()
            }
        }
    }

    func stop() {
        wanted = false
        DispatchQueue.main.async { [weak self] in
            self?.watchdog?.invalidate()
            self?.watchdog = nil
            self?.player?.stop()
            self?.player = nil
        }
    }

    @objc private func sessionDisturbed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.ensurePlaying()
        }
    }

    private func ensurePlaying() {
        guard wanted else { return }
        if let p = player, p.isPlaying { return }
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord && session.category != .playback {
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            }
            try session.setActive(true)
            let p = try AVAudioPlayer(data: BackgroundKeepAlive.silentWAV())
            p.numberOfLoops = -1
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            player = p
            print("[KeepAlive] silent audio loop running")
        } catch {
            print("[KeepAlive] could not start: \(error)")
        }
    }

    /// One second of 8 kHz 16-bit mono silence as a WAV file.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
