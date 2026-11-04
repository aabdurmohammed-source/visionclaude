import Foundation
import AVFoundation
import Speech
import AudioToolbox

/// Thread-safe holder for the recognition request the audio tap feeds.
final class HandsFreeAudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
}

/// Always-on, hands-free listener: waits for "hey claude" (or "claude ..."), then captures what
/// you say until you pause and hands it to `onCommand`. The audio engine stays running while
/// paused so iOS never has to restart the mic from the background.
///
/// After Claude finishes speaking there is a short follow-up window where you can just talk
/// without saying the wake phrase again.
@MainActor
final class HandsFreeListener: NSObject, ObservableObject {
    enum Phase { case stopped, paused, waiting, capturing }

    @Published private(set) var phase: Phase = .stopped
    /// What the recognizer currently hears (shown on screen so you can see it working).
    /// While armed and silent it shows a "listening" hint so you can tell it is on.
    @Published private(set) var heardText: String = ""
    var onCommand: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let feed = HandsFreeAudioFeed()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engineRunning = false
    private var configObserver: NSObjectProtocol?

    private var rollTimer: Timer?
    private var silenceTimer: Timer?
    private var awakeTimer: Timer?
    private var restartToken = 0
    private var errorStreak = 0
    private var capturedCommand = ""
    private var followUpUntil = Date.distantPast

    private let armedHint = "Listening for \u{201C}hey claude\u{201D}\u{2026}"

    private let pauseThreshold: TimeInterval = 1.6
    private let wakePhrases = ["hey claude", "okay claude", "ok claude", "hi claude",
                               "hey cloud", "hey clod", "hey claud", "hey clawed", "hey claudia",
                               "hey clyde", "a claude", "hey cod", "hey clock"]

    // MARK: - Control

    /// After Claude finishes speaking, accept the next thing you say without the wake phrase.
    func openFollowUp(seconds: TimeInterval = 8) {
        followUpUntil = Date().addingTimeInterval(seconds)
    }

    /// Start (or resume) listening for the wake phrase.
    func setActive(_ active: Bool) {
        if !active {
            pause()
            return
        }
        guard phase != .waiting, phase != .capturing else { return }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.setActive(true) }
            }
            return
        default:
            print("[HandsFree] speech recognition not authorized")
            heardText = "Speech recognition not allowed - enable it in iPhone Settings"
            return
        }

        do {
            try startEngine()
        } catch {
            print("[HandsFree] engine start failed: \(error) - retrying")
            heardText = "Mic not ready - retrying\u{2026}"
            scheduleRestart(after: 2.0, forceActivate: true)
            return
        }
        phase = .waiting
        beginRecognition()
        print("[HandsFree] listening for wake phrase")
    }

    /// Stop recognizing but keep the mic engine hot (used while Claude thinks / speaks).
    func pause() {
        guard phase != .stopped else { return }
        phase = .paused
        invalidateTimers()
        endRecognition()
        heardText = ""
    }

    /// Full teardown (mic off).
    func stop() {
        guard phase != .stopped else { return }
        phase = .stopped
        invalidateTimers()
        endRecognition()
        stopEngine()
        heardText = ""
    }

    // MARK: - Engine

    private func startEngine() throws {
        guard !engineRunning else { return }
        try? AudioSessionManager.shared.configureForVoiceChat()
        engine.reset()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(domain: "HandsFree", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio input not ready"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format,
                         block: HandsFreeListener.makeTap(feed: feed))
        engine.prepare()
        try engine.start()
        engineRunning = true

        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleConfigChange() }
            }
        }
    }

    private nonisolated static func makeTap(feed: HandsFreeAudioFeed) -> AVAudioNodeTapBlock {
        return { buffer, _ in feed.append(buffer) }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
    }

    /// Route changed (glasses connected, category switched, ...): rebuild the engine and carry on.
    private func handleConfigChange() {
        guard phase != .stopped else { return }
        print("[HandsFree] audio config changed")
        let wasListening = (phase == .waiting || phase == .capturing)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
        endRecognition()
        // While Claude is speaking (paused) the player may switch the audio category;
        // don't fight it - the engine is rebuilt when we go back to waiting.
        if phase == .paused { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.phase != .stopped else { return }
            do {
                try self.startEngine()
                if wasListening || self.phase == .waiting || self.phase == .capturing {
                    self.phase = .waiting
                    self.beginRecognition()
                }
            } catch {
                print("[HandsFree] engine restart failed: \(error)")
                self.scheduleRestart(after: 2.0, forceActivate: true)
            }
        }
    }

    // MARK: - Recognition

    private func beginRecognition() {
        guard phase == .waiting || phase == .capturing else { return }
        endRecognition()
        heardText = (phase == .waiting) ? armedHint : ""
        guard let recognizer, recognizer.isAvailable else {
            heardText = "Speech recognizer unavailable - retrying\u{2026}"
            scheduleRestart(after: 2.0)
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        currentRequest = req
        feed.set(req)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.handleResult(text: text, isFinal: isFinal, failed: failed, request: req)
            }
        }

        rollTimer?.invalidate()
        rollTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rollIfIdle() }
        }
    }

    private func endRecognition() {
        feed.set(nil)
        currentRequest = nil
        task?.cancel()
        task = nil
        rollTimer?.invalidate()
        rollTimer = nil
    }

    private func rollIfIdle() {
        if phase == .waiting { beginRecognition() }
        else if phase == .capturing {
            rollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.rollIfIdle() }
            }
        }
    }

    private func handleResult(text: String?, isFinal: Bool, failed: Bool,
                              request: SFSpeechAudioBufferRecognitionRequest) {
        guard request === currentRequest else { return }   // stale callback

        if failed {
            errorStreak += 1
            if phase == .capturing && !capturedCommand.isEmpty {
                finishCommand()
            } else {
                phase = (phase == .capturing) ? .waiting : phase
                scheduleRestart(after: min(0.3 * Double(errorStreak), 3.0))
            }
            return
        }
        guard let text else { return }
        errorStreak = 0
        let norm = HandsFreeListener.normalize(text)
        if (phase == .waiting || phase == .capturing) && !norm.isEmpty { heardText = text }

        switch phase {
        case .waiting:
            if let rest = commandAfterWake(norm) {
                enterCapturing(initial: rest)
            } else if Date() < followUpUntil && !norm.isEmpty {
                // Follow-up window after Claude spoke: no wake phrase needed.
                enterCapturing(initial: norm)
            } else if isFinal {
                beginRecognition()
            }
        case .capturing:
            capturedCommand = commandAfterWake(norm) ?? norm
            if !capturedCommand.isEmpty { resetSilenceTimer() }
            if isFinal { finishCommand() }
        default:
            break
        }
    }

    // MARK: - Wake phrase + command capture

    private func enterCapturing(initial: String) {
        phase = .capturing
        followUpUntil = .distantPast
        capturedCommand = initial
        AudioServicesPlaySystemSound(1113)   // short "I heard you" cue
        print("[HandsFree] wake phrase heard")
        if !initial.isEmpty { resetSilenceTimer() }
        awakeTimer?.invalidate()
        awakeTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .capturing, self.capturedCommand.isEmpty else { return }
                print("[HandsFree] nothing said after wake phrase - going back to waiting")
                self.phase = .waiting
                self.beginRecognition()
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: pauseThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishCommand() }
        }
    }

    private func finishCommand() {
        guard phase == .capturing else { return }
        let cmd = capturedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        silenceTimer?.invalidate(); silenceTimer = nil
        awakeTimer?.invalidate(); awakeTimer = nil
        guard !cmd.isEmpty else { return }
        capturedCommand = ""
        phase = .waiting
        beginRecognition()           // fresh request; the view model pauses us while Claude works
        print("[HandsFree] command: \(cmd)")
        onCommand?(cmd)
    }

    private func commandAfterWake(_ norm: String) -> String? {
        var best: Range<String.Index>?
        for p in wakePhrases {
            if let r = norm.range(of: p), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        if let r = best { return String(norm[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        if norm == "claude" { return "" }
        if norm.hasPrefix("claude ") { return String(norm.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private nonisolated static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Helpers

    private func invalidateTimers() {
        silenceTimer?.invalidate(); silenceTimer = nil
        awakeTimer?.invalidate(); awakeTimer = nil
        rollTimer?.invalidate(); rollTimer = nil
        restartToken += 1
        capturedCommand = ""
    }

    private func scheduleRestart(after delay: TimeInterval, forceActivate: Bool = false) {
        restartToken += 1
        let token = restartToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.restartToken == token else { return }
            if forceActivate {
                if self.phase != .stopped { self.phase = .paused; self.setActive(true) }
            } else if self.phase == .waiting || self.phase == .capturing {
                self.beginRecognition()
            }
        }
    }
}
