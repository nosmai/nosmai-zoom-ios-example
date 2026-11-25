import UIKit
import AVFoundation
import ZoomVideoSDK

/// Host:     Nosmai owns the camera -> filtered frames -> Zoom external video source.
/// Audience: plain Zoom Video SDK participant rendering the host's video.
final class LiveViewController: UIViewController {
    enum Role { case host, audience }

    private let role: Role
    private let config: DemoConfig
    private let sessionToken: String
    private var isHost: Bool { role == .host }

    /// Host: feeds Nosmai frames to Zoom. Zoom only keeps a weak reference to it.
    private let videoSource = NosmaiZoomVideoSource()
    /// Audience: the user whose video is currently on screen.
    private var watchedUser: ZoomVideoSDKUser?
    private var joined = false
    private var cameraRunning = false
    private var stopped = false
    /// Host: frames handed to Zoom since the last tick.
    private let frameLock = NSLock()
    private var framesSinceTick = 0
    private var fpsTimer: Timer?

    private var liveStatus = "Preparing…"
    private var toastToken = 0

    private let videoView = UIView()
    private let statusLabel = PaddedLabel()
    private let fpsLabel = PaddedLabel()
    private let controls = UIStackView()
    private let effectsPanel = EffectsPanelView()

    init(role: Role, config: DemoConfig, sessionToken: String) {
        self.role = role
        self.config = config
        self.sessionToken = sessionToken
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isHost ? "Live" : "Watching"
        view.backgroundColor = .black
        buildUI()
        guard setUpZoom() else { return }
        startFPSTimer()
        if isHost {
            requestPermissions { [weak self] in self?.startNosmaiCamera() }
        } else {
            joinSession()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        if isMovingFromParent || isBeingDismissed { stopSession() }
    }

    // MARK: - UI

    private func buildUI() {
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        statusLabel.text = "Preparing…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        fpsLabel.text = "-- FPS"
        fpsLabel.textColor = .systemGreen
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        fpsLabel.layer.cornerRadius = 10
        fpsLabel.clipsToBounds = true
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)

        controls.axis = .vertical
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        if isHost {
            effectsPanel.onStatus = { [weak self] text in self?.showToast(text) }
            controls.addArrangedSubview(effectsPanel)
        }

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        if isHost {
            buttons.addArrangedSubview(makeButton(title: "Flip", color: .darkGray, action: #selector(flipCamera)))
            buttons.addArrangedSubview(makeButton(title: "Effects", color: .systemPink, action: #selector(toggleEffects)))
        }
        buttons.addArrangedSubview(makeButton(title: isHost ? "End Live" : "Leave", color: .systemRed, action: #selector(close)))
        buttons.heightAnchor.constraint(equalToConstant: 48).isActive = true
        controls.addArrangedSubview(buttons)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fpsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            fpsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 12
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.liveStatus = text
            self.statusLabel.text = text
        }
    }

    /// Briefly shows effect feedback in the status pill, then restores the live status.
    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        statusLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.statusLabel.text = self.liveStatus
        }
    }

    // MARK: - Zoom

    /// The Zoom SDK is a singleton that is initialised once per app launch.
    private static var zoomInitialized = false

    private func setUpZoom() -> Bool {
        guard let sdk = ZoomVideoSDK.sharedInstance() else { return false }
        if !Self.zoomInitialized {
            let params = ZoomVideoSDKInitParams()
            params.domain = "zoom.us"
            params.enableLog = false
            let result = sdk.initialize(params)
            guard result == .Errors_Success else {
                setStatus("Zoom SDK init failed (\(result.rawValue))")
                return false
            }
            Self.zoomInitialized = true
        }
        sdk.addDelegate(self)
        if isHost {
            videoSource.onFrameSent = { [weak self] in
                guard let self else { return }
                self.frameLock.lock()
                self.framesSinceTick += 1
                self.frameLock.unlock()
            }
        }
        return true
    }

    private func joinSession() {
        guard !stopped, let sdk = ZoomVideoSDK.sharedInstance() else { return }
        let context = ZoomVideoSDKSessionContext()
        context.sessionName = config.sessionName
        context.userName = isHost ? "Host" : "Viewer"
        context.token = sessionToken

        let video = ZoomVideoSDKVideoOptions()
        video.localVideoOn = isHost
        context.videoOption = video

        let audio = ZoomVideoSDKAudioOptions()
        audio.connect = true
        audio.mute = !isHost // viewers only listen
        context.audioOption = audio

        // Nosmai owns the camera, so Zoom must take frames from us.
        if isHost { context.externalVideoSourceDelegate = videoSource }

        if sdk.joinSession(context) == nil {
            setStatus("Zoom rejected the join — check the session name and token")
        } else {
            setStatus("Joining \(config.sessionName)…")
        }
    }

    /// Host FPS = frames handed to Zoom each second.
    /// Audience FPS = frame rate of the host's video as received.
    private func startFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isHost {
                self.frameLock.lock()
                let frames = self.framesSinceTick
                self.framesSinceTick = 0
                self.frameLock.unlock()
                if self.joined { self.fpsLabel.text = "\(frames) FPS" }
            } else if let fps = self.watchedUser?.getVideoStatisticInfo()?.fps, fps > 0 {
                self.fpsLabel.text = "\(fps) FPS"
            }
        }
    }

    /// Audience: show the first remote user whose video is on (the host).
    private func refreshWatchedUser() {
        guard !isHost, joined, let session = ZoomVideoSDK.sharedInstance()?.getSession() else { return }
        let remoteUsers = session.getRemoteUsers() ?? []
        let target = remoteUsers.first { $0.getVideoCanvas()?.videoStatus()?.on == true }
        if let current = watchedUser, current.getID() == target?.getID() { return }

        watchedUser?.getVideoCanvas()?.unSubscribe(with: videoView)
        watchedUser = nil
        guard let target, let canvas = target.getVideoCanvas() else {
            fpsLabel.text = "-- FPS"
            setStatus(remoteUsers.isEmpty ? "Connected — waiting for host" : "Host video is off")
            return
        }
        canvas.subscribe(with: videoView, aspectMode: .panAndScan, andResolution: ._720)
        watchedUser = target
        setStatus("Watching host")
    }

    // MARK: - Nosmai (host only)

    private func requestPermissions(then start: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] camera in
            guard camera else { self?.setStatus("Camera permission denied"); return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] mic in
                guard mic else { self?.setStatus("Microphone permission denied"); return }
                DispatchQueue.main.async(execute: start)
            }
        }
    }

    private func startNosmaiCamera() {
        guard !stopped else { return }
        setStatus("Starting Nosmai…")
        NosmaiCore.shared().initialize(withAPIKey: config.nosmaiAPIKey) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard success else {
                    self.setStatus("Nosmai init failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                guard let camera = NosmaiCore.shared().camera else {
                    self.setStatus("Nosmai camera unavailable")
                    return
                }
                let cameraConfig = NosmaiCameraConfig()
                cameraConfig.position = .front
                cameraConfig.sessionPreset = AVCaptureSession.Preset.hd1280x720.rawValue
                cameraConfig.frameRate = 30
                camera.updateConfiguration(cameraConfig)
                camera.attach(to: self.videoView)

                guard camera.startCapture() else {
                    self.setStatus("Nosmai camera failed to start")
                    return
                }
                // Required for beauty / filters to render.
                NosmaiSDK.sharedInstance()?.startProcessing()
                self.cameraRunning = true
                self.effectsPanel.nosmaiReady()
                self.joinSession()
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleEffects() {
        UIView.animate(withDuration: 0.2) {
            self.effectsPanel.isHidden.toggle()
            self.effectsPanel.alpha = self.effectsPanel.isHidden ? 0 : 1
        }
    }

    @objc private func flipCamera() {
        guard cameraRunning else { return }
        _ = NosmaiCore.shared().camera?.switch()
    }

    @objc private func close() {
        navigationController?.popViewController(animated: true)
    }

    private func stopSession() {
        guard !stopped else { return }
        stopped = true
        fpsTimer?.invalidate()
        fpsTimer = nil
        if isHost {
            videoSource.shutdown() // stop taking Nosmai frames before leaving
        } else {
            watchedUser?.getVideoCanvas()?.unSubscribe(with: videoView)
            watchedUser = nil
        }
        if let sdk = ZoomVideoSDK.sharedInstance() {
            // The host ends the session for everyone; a viewer just leaves.
            if sdk.isInSession() { _ = sdk.leaveSession(isHost) }
            sdk.removeDelegate(self)
        }

        if cameraRunning {
            cameraRunning = false
            let core = NosmaiCore.shared()
            core.effects?.clearAll() // the SDK is a singleton; don't leak effects into the next session
            core.camera?.stopCapture()
            core.camera?.detachFromView()
            core.cleanup()
        }
    }
}

// MARK: - ZoomVideoSDKDelegate

extension LiveViewController: ZoomVideoSDKDelegate {
    func onSessionJoin() {
        joined = true
        guard let sdk = ZoomVideoSDK.sharedInstance() else { return }
        // Make sure audio is connected: the host talks, viewers listen.
        if let me = sdk.getSession()?.getMySelf(), me.audioStatus()?.audioType == ZoomVideoSDKAudioType.none {
            _ = sdk.getAudioHelper()?.startAudio()
        }
        if isHost {
            setStatus("Live in \(config.sessionName)")
        } else {
            refreshWatchedUser()
        }
    }

    func onSessionLeave(_ reason: ZoomVideoSDKSessionLeaveReason) {
        joined = false
        guard !stopped else { return }
        watchedUser = nil
        fpsLabel.text = "-- FPS"
        setStatus(isHost ? "Session ended" : "Host ended the stream")
    }

    func onError(_ errorType: ZoomVideoSDKError, detail: Int) {
        switch errorType {
        case .Errors_Success:
            break
        case .Errors_Session_Reconnecting:
            setStatus("Reconnecting…")
        case .Errors_Session_Not_Started:
            setStatus("The host has not started the session yet")
        default:
            setStatus("Zoom error \(errorType.rawValue) — check the token, its expiry and the session name")
        }
    }

    func onUserJoin(_ helper: ZoomVideoSDKUserHelper?, users: [ZoomVideoSDKUser]?) {
        refreshWatchedUser()
    }

    func onUserLeave(_ helper: ZoomVideoSDKUserHelper?, users: [ZoomVideoSDKUser]?) {
        refreshWatchedUser()
    }

    func onUserVideoStatusChanged(_ helper: ZoomVideoSDKVideoHelper?, user: [ZoomVideoSDKUser]?) {
        refreshWatchedUser()
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
