import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera

@MainActor
class RayBanManager: NSObject, ObservableObject, FrameSource {

    // MARK: - FrameSource Protocol

    @Published var latestFrame: Data?
    @Published var latestImage: UIImage?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: FrameSourceStatus = .disconnected
    @Published var frameCount: Int = 0

    let sourceType: FrameSourceType = .rayBan

    // MARK: - State

    @Published var glassesName: String = "Not Connected"
    @Published var hasActiveDevice: Bool = false
    @Published var registrationState: String = "unregistered"
    @Published var isRegistered: Bool = false

    // DAT SDK
    private var deviceSession: DeviceSession?
    private var camera: Camera?
    private var sessionStateToken: AnyListenerToken?
    private var sessionErrorToken: AnyListenerToken?
    private var deviceSelector: (any DeviceSelector)?
    private var stateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var deviceMonitorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?

    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5
    private var lastCaptureTime: Date = .distantPast

    // MARK: - Configuration

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    // MARK: - Registration (MUST complete before streaming)

    func startMonitoringRegistration() {
        let wearables = Wearables.shared
        registrationTask = Task { @MainActor in
            for await state in wearables.registrationStateStream() {
                switch state {
                case .registered:
                    self.registrationState = "registered"
                    self.isRegistered = true
                    print("[RayBan] Registration complete")
                case .registering:
                    self.registrationState = "registering"
                    print("[RayBan] Registration in progress...")
                case .available, .unavailable:
                    self.registrationState = "unregistered"
                    self.isRegistered = false
                    print("[RayBan] Not registered")
                @unknown default:
                    break
                }
            }
        }

        // Check current state
        let currentState = wearables.registrationState
        switch currentState {
        case .registered:
            isRegistered = true
            registrationState = "registered"
        case .registering:
            registrationState = "registering"
        case .available, .unavailable:
            registrationState = "unregistered"
        @unknown default:
            break
        }
    }

    func register() async {
        guard !isRegistered else {
            print("[RayBan] Already registered")
            return
        }

        do {
            print("[RayBan] Starting registration with Meta AI...")
            connectionStatus = .connecting
            try await Wearables.shared.startRegistration()
        } catch {
            print("[RayBan] Registration error: \(error)")
            connectionStatus = .error("Registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FrameSource Implementation

    func start() throws {
        guard !isRunning else { return }

        // Re-check registration state directly from SDK
        let currentState = Wearables.shared.registrationState
        if currentState == .registered {
            isRegistered = true
            registrationState = "registered"
        }

        guard isRegistered else {
            print("[RayBan] Not registered (state: \(currentState)) — starting registration first")
            connectionStatus = .error("Tap 'Connect Glasses' in Settings to register with Meta AI first")
            Task { await register() }
            return
        }

        connectionStatus = .connecting
        print("[RayBan] Starting device session...")

        let wearables = Wearables.shared
        // Pick the known glasses directly: AutoDeviceSelector resolves asynchronously,
        // so createSession right after init failed with noEligibleDevice.
        let selector: any DeviceSelector
        if let first = wearables.devices.first {
            selector = SpecificDeviceSelector(device: first)
        } else {
            selector = AutoDeviceSelector(wearables: wearables)
        }
        self.deviceSelector = selector

        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            connectionStatus = .error("Session error: \(error.localizedDescription) | \(deviceDiagnostics())")
            print("[RayBan] createSession failed: \(error)")
            return
        }
        self.deviceSession = session

        // Monitor device availability
        deviceMonitorTask = Task { @MainActor in
            for await device in selector.activeDeviceStream() {
                self.hasActiveDevice = device != nil
                if device != nil {
                    self.glassesName = "Ray-Ban Meta"
                    print("[RayBan] Device active")
                } else {
                    self.glassesName = "No Device"
                    print("[RayBan] No active device")
                }
            }
        }

        // Session errors
        sessionErrorToken = session.errorPublisher.listen { [weak self] (error: DeviceSessionError) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = "Session: \(error.errorDescription ?? "\(error)") | \(self.deviceDiagnostics())"
                print("[RayBan] \(msg)")
                self.connectionStatus = .error(msg)
            }
        }

        // When the device session is started, attach camera + stream
        sessionStateToken = session.statePublisher.listen { [weak self] (state: DeviceSessionState) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[RayBan] Session state: \(state)")
                switch state {
                case .started:
                    self.attachCameraAndStream(to: session)
                case .stopped:
                    self.isRunning = false
                    self.connectionStatus = .disconnected
                default:
                    self.connectionStatus = .connecting
                }
            }
        }

        // Request camera permission THEN start the session
        Task { @MainActor in
            do {
                print("[RayBan] Checking camera permission...")
                let status = try await wearables.checkPermissionStatus(.camera)
                print("[RayBan] Camera permission status: \(status)")
                if status != .granted {
                    print("[RayBan] Requesting camera permission (will open Meta AI)...")
                    let result = try await wearables.requestPermission(.camera)
                    print("[RayBan] Permission result: \(result)")
                    if result != .granted {
                        self.connectionStatus = .error("Camera permission denied. Grant in Meta AI app.")
                        return
                    }
                }
            } catch {
                print("[RayBan] Permission error: \(error) — trying to start anyway")
            }
            do {
                try session.start()
                print("[RayBan] Session start() returned, state: \(session.state)")
            } catch {
                print("[RayBan] Session start failed: \(error)")
                self.connectionStatus = .error("Start failed: \(error.localizedDescription) | \(self.deviceDiagnostics())")
            }
        }
    }

    private func deviceDiagnostics() -> String {
        let wearables = Wearables.shared
        let ids = wearables.devices
        if ids.isEmpty { return "SDK sees 0 devices (reg: \(wearables.registrationState))" }
        let parts: [String] = ids.map { id in
            guard let d = wearables.deviceForIdentifier(id) else { return "\(id): unknown" }
            return "\(d.name) link=\(d.linkState) compat=\(d.compatibility()) worn=\(d.donState) hinge=\(d.hingeState) batt=\(d.batteryLevel.map(String.init) ?? "?")"
        }
        return "devices(\(ids.count)): " + parts.joined(separator: "; ") + " selActive=\(deviceSelector?.activeDevice != nil)"
    }

    private func attachCameraAndStream(to session: DeviceSession) {
        guard camera == nil else { return }
        let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 30)
        let cam: Camera?
        do {
            cam = try session.addCamera(config: config)
        } catch {
            print("[RayBan] addCamera failed: \(error)")
            connectionStatus = .error("Camera error: \(error.localizedDescription)")
            return
        }
        guard let cam else {
            connectionStatus = .error("Camera unavailable on these glasses")
            return
        }
        self.camera = cam
        let stream = cam.stream

        stateToken = stream.statePublisher.listen { [weak self] (state: StreamState) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[RayBan] Stream state: \(state)")
                switch state {
                case .streaming:
                    self.isRunning = true
                    self.connectionStatus = .connected
                case .stopped:
                    self.isRunning = false
                    self.connectionStatus = .disconnected
                default:
                    self.connectionStatus = .connecting
                }
            }
        }

        frameToken = stream.videoFramePublisher.listen { [weak self] (videoFrame: VideoFrame) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let uiImage = videoFrame.makeUIImage() else { return }
                self.latestImage = uiImage
                self.frameCount += 1
                let now = Date()
                if now.timeIntervalSince(self.lastCaptureTime) >= self.frameInterval {
                    self.lastCaptureTime = now
                    if let jpegData = uiImage.jpegData(compressionQuality: self.jpegQuality) {
                        self.latestFrame = jpegData
                        print("[RayBan] Captured JPEG frame (\(jpegData.count) bytes)")
                    }
                }
            }
        }

        errorToken = stream.errorPublisher.listen { [weak self] (error: StreamError) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = self.formatError(error)
                print("[RayBan] Error: \(msg)")
                self.connectionStatus = .error(msg)
            }
        }

        stream.start()
    }

    func stop() {
        camera?.stop()
        deviceSession?.stop()
        stateToken = nil
        frameToken = nil
        errorToken = nil
        sessionStateToken = nil
        sessionErrorToken = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        camera = nil
        deviceSession = nil
        deviceSelector = nil
        isRunning = false
        connectionStatus = .disconnected
        latestFrame = nil
        latestImage = nil
        glassesName = "Not Connected"
        hasActiveDevice = false
    }

    func consumeFrame() -> Data? {
        return latestFrame
    }

    func cleanup() {
        stop()
        registrationTask?.cancel()
        registrationTask = nil
    }

    // MARK: - Error Formatting

    private func formatError(_ error: StreamError) -> String {
        switch error {
        case .deviceNotFound: return "Glasses not found. Power on and open hinges."
        case .deviceNotConnected: return "Glasses disconnected. Check Bluetooth."
        case .permissionDenied: return "Camera permission denied. Grant in Meta AI app Settings."
        case .hingesClosed: return "Open the glasses hinges to stream."
        case .thermalHot: return "Glasses overheating. Streaming paused."
        case .batteryLow: return "Glasses battery low."
        case .peakPowerLimit: return "Glasses power limit reached."
        case .timeout: return "Connection timed out. Try again."
        case .videoStreamingError, .audioStreamingError: return "Stream failed. Restart app."
        case .photoCaptureFailed: return "Photo capture failed."
        case .internalError: return "Internal SDK error. Restart app."
        }
    }
}
