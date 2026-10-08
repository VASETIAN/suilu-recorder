import AVFoundation
import ImageIO
import Photos
import SwiftUI
import UIKit

// This reference crosses queue boundaries, but its mutable state stays confined:
// UI-facing calls / Published state use the main queue; capture state uses
// captureQueue. Values are copied before publishing from captureQueue to main.
// Sendability is checked manually because DispatchQueue confinement cannot be
// expressed by Swift's actor annotations without moving the capture engine.
final class RecorderController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published private(set) var settings = RecorderSettings.load()
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var isReady = false
    @Published private(set) var isConfiguring = false
    @Published private(set) var supportedModes: [VideoMode] = []
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var zoomStops: [CGFloat] = [1]
    @Published private(set) var minimumZoom: CGFloat = 1
    @Published private(set) var maximumZoom: CGFloat = 1
    @Published private(set) var hasTorch = false
    @Published private(set) var torchOn = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var availableSpace: Int64?
    @Published private(set) var libraryItems: [MediaItem] = []
    @Published private(set) var livePhotoSupported = false
    @Published private(set) var multitaskingCameraSupported = false
    @Published private(set) var activeLensLabel = "相机"
    @Published private(set) var status = "正在准备相机…"
    @Published private(set) var lastCameraError = UserDefaults.standard.string(forKey: "Recorder.lastCameraError")
    @Published var message: RecorderMessage?
    @Published private(set) var resumeRequest: UUID?
    @Published private(set) var captureLoad: CaptureLoad = .normal
    @Published private(set) var thumbnailGeneration = 0
    @Published private(set) var exportingPhotoIDs: Set<UUID> = []
    @Published private(set) var photosExportStatus = ""
    @Published private(set) var preparingShare = false
    @Published var shareExport: MediaExport?
    private var preparedShare: MediaExport?
    private var failedPhotosExports = 0
    @Published private(set) var dualPreview: DualCameraCapture?
    let dualCaptureModes = DualCameraCapture.modes
    var dualCaptureSupported: Bool { !dualCaptureModes.isEmpty }
    private var dualRecorder: DualCameraCapture?
    private var activeSession: AVCaptureSession { dualRecorder?.session ?? session }

    func attachDualPreview(_ back: AVCaptureVideoPreviewLayer, _ face: AVCaptureVideoPreviewLayer) {
        captureQueue.async {
            guard let dual = self.dualRecorder, back.session !== dual.session || face.session !== dual.session else { return }
            dual.attachPreview(back, face)
            self.publish { self.objectWillChange.send() }
        }
    }

    func toggleDualCapture() {
        guard canConfigure, dualCaptureSupported else { return }
        var value = settings
        value.dualCapture.toggle()
        value.captureMode = .video
        apply(value)
    }

    // All capture state and AVFoundation mutations belong to this serial queue.
    // Published UI state is changed only on the main queue.
    private let captureQueue = DispatchQueue(label: "com.tians.recorder.capture", qos: .userInitiated)
    private let mediaQueue = DispatchQueue(label: "com.tians.recorder.media", qos: .utility)
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var photoCapture: PhotoCaptureProcessor?
    private var activeItem: MediaItem?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var captureSettings = RecorderSettings.load()
    private var capturePhase: RecordingPhase = .idle
    private var configured = false
    private var foreground = false
    private var stopRequested = false
    private var activeURL: URL?
    private var zoomScale: CGFloat = 1
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var ticker: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var tickCount = 0
    private var startTaskRunning = false
    private var mainForeground = false
    private var runtimeRecoveryAttempted = false
    private var resumeAfterBackgroundPending = false
    private var resumeSourceID: UUID?
    private var loadOnQueue: CaptureLoad = .normal
    private var pressureObserver: NSKeyValueObservation?
    private var pendingPhotosExports: [(MediaItem, Bool)] = []
    private var photosExportRunning = false
    private var permissionGeneration = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        settings.captureMode = .video
        captureSettings = settings
        installObservers()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
        mediaQueue.async { MediaLibrary.cleanOldShareExports() }
        captureQueue.async {
            do { try MediaLibrary.recover() }
            catch { self.report("图库恢复未完成", error.localizedDescription + " 原文件仍保留。") }
            self.refreshLibraryOnQueue()
        }
    }

    deinit {
        ticker?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var canRecord: Bool {
        mainForeground && isReady && !isConfiguring && phase == .idle
            && (!settings.thermalProtection || captureLoad != .critical)
    }
    var canConfigure: Bool { phase == .idle && !isConfiguring }
    var elapsedLabel: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    func start() {
        guard mainForeground, !startTaskRunning, !isConfiguring, phase == .idle else { return }
        guard Self.hasPurposeString("NSCameraUsageDescription") else {
            status = "相机权限声明未加载"
            showMessage("相机权限声明未加载", "这个运行环境没有加载工程中的相机用途说明。请在 Swift Playgrounds 中点击运行；如仍提示此错误，请检查 App 设置中的相机能力。")
            return
        }
        startTaskRunning = true
        isConfiguring = true
        let generation = permissionGeneration
        Task { @MainActor in
            let cameraGranted = await Self.requestCapturePermission(.video)
            guard generation == permissionGeneration, mainForeground else {
                startTaskRunning = false
                isConfiguring = false
                if mainForeground { start() }
                return
            }
            guard cameraGranted else {
                startTaskRunning = false
                isConfiguring = false
                isReady = false
                status = "请在系统设置中允许相机权限"
                showMessage("需要相机权限", "打开系统设置，允许畅游访问相机，然后回到这里重试。")
                return
            }
            var requested = settings
            if requested.microphoneEnabled && requested.captureMode != .photo {
                let granted = await Self.requestCapturePermission(.audio)
                if !granted {
                    requested.microphoneEnabled = false
                    showMessage("麦克风未授权", "已切换为无声录像。可在系统设置中开启麦克风权限，再到录像设置中启用声音。")
                }
            }
            guard generation == permissionGeneration, mainForeground else {
                startTaskRunning = false
                isConfiguring = false
                if mainForeground { start() }
                return
            }
            startTaskRunning = false
            configure(requested)
        }
    }

    func sceneChanged(_ scenePhase: ScenePhase) {
        if scenePhase == .active {
            guard !mainForeground else { return }
            mainForeground = true
            captureQueue.async {
                self.foreground = true
                self.runtimeRecoveryAttempted = false
                // The UI phase can lag behind an already completed file callback.
                // Reconcile on the queue that owns capture state as well.
                if self.capturePhase == .recording && self.activeSession.isRunning && !self.activeSession.isInterrupted {
                    self.publish { self.isReady = true; self.status = "录像中" }
                } else if self.configured { self.resumeSessionOnQueue() }
                else { self.publish { self.start() } }
            }
        } else if scenePhase == .background {
            guard mainForeground else { return }
            mainForeground = false
            isReady = false
            permissionGeneration += 1
            if phase.blocksConfiguration { beginFinishingTask() }
            captureQueue.async {
                self.foreground = false

                self.resumeAfterBackgroundPending = self.captureSettings.resumeAfterBackground
                    && self.captureSettings.captureMode == .video
                    && (self.capturePhase == .preparing || self.capturePhase == .recording)
                self.resumeSourceID = self.resumeAfterBackgroundPending ? self.activeItem?.id : nil
                self.turnTorchOff()
                if self.capturePhase == .preparing || self.capturePhase == .recording {
                    self.stopOnQueue(reason: "离开前台，已停止录像", preserveResume: true)
                }
                if self.activeSession.isRunning { self.activeSession.stopRunning() }
                self.publish { self.isReady = false }
            }
        }
        // .inactive also occurs for permission prompts. The capture interruption
        // notification handles a system interruption without canceling these prompts.
    }





    func apply(_ value: RecorderSettings, displayedZoom: CGFloat? = nil) {
        guard canConfigure else { return }
        isConfiguring = true
        Task { @MainActor in
            var requested = value
            if requested.microphoneEnabled && requested.captureMode != .photo {
                let granted = await Self.requestCapturePermission(.audio)
                if !granted {
                    requested.microphoneEnabled = false
                    showMessage("麦克风未授权", "声音未开启。请先在系统设置中允许麦克风权限。")
                }
            }
            if requested.automaticallyExportToPhotos && !settings.automaticallyExportToPhotos {
                let granted = await Self.requestPhotosPermission()
                if !granted {
                    requested.automaticallyExportToPhotos = false
                    showMessage("未启用自动导出", "系统照片添加权限未获允许，拍摄仍保存到内置图库。")
                }
            }
            guard mainForeground else { isConfiguring = false; return }
            if displayedZoom == nil && requested.hasSameCaptureConfiguration(as: settings) {
                let value = requested
                captureQueue.async {
                    self.resumeAfterBackgroundPending = false
                    self.captureSettings = value
                    self.movieOutput.minFreeDiskSpaceLimit = value.reserveBytes
                    self.readCaptureLoadOnQueue()
                    self.resumeSessionOnQueue()
                    self.publish { self.settings = value; value.save(); self.isConfiguring = false }
                }
                return
            }
            configure(requested, displayedZoom: displayedZoom)
        }
    }

    func setInterfaceMode(_ mode: RecorderInterface) {
        guard !isConfiguring, phase == .idle || phase == .recording else { return }
        if mode == .browser && settings.captureMode != .video {
            var value = settings
            value.interfaceMode = mode
            value.captureMode = .video
            apply(value)
            return
        }
        settings.interfaceMode = mode
        settings.save()
        captureQueue.async { self.captureSettings.interfaceMode = mode }
    }

    func switchCamera() {
        guard !settings.dualCapture else { return }
        var value = settings
        value.frontCamera.toggle()
        apply(value)
    }

    private func configure(_ requested: RecorderSettings, displayedZoom: CGFloat? = nil) {
        captureQueue.async {
            self.resumeAfterBackgroundPending = false
            guard self.capturePhase == .idle, self.foreground else {
                self.publish { self.isConfiguring = false }
                return
            }
            do {
                let applied = try self.configureOnQueue(requested, displayedZoom: displayedZoom)
                if !self.activeSession.isRunning { self.activeSession.startRunning() }
                let running = self.activeSession.isRunning && !self.activeSession.isInterrupted
                self.publish {
                    self.settings = applied
                    applied.save()
                    self.isConfiguring = false
                    self.isReady = running
                    self.status = running ? (applied.captureMode == .video ? "准备录像" : "准备拍照") : "相机暂不可用，点击重试"
                }
                self.publishCapabilities()
                self.readCaptureLoadOnQueue()
            } catch {
                let ready = self.configured && self.activeSession.isRunning && !self.activeSession.isInterrupted
                self.publish {
                    self.isConfiguring = false
                    self.isReady = ready
                    self.showMessage("相机配置失败", error.localizedDescription)
                }
            }
        }
    }

    private func configureOnQueue(_ requested: RecorderSettings, displayedZoom: CGFloat? = nil) throws -> RecorderSettings {
        guard Self.hasPurposeString("NSCameraUsageDescription"),
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw RecorderError("相机权限未准备好，请允许相机权限后重试。")
        }
        if dualRecorder != nil || requested.dualCapture {
            let previous = captureSettings
            turnTorchOff()
            if activeSession.isRunning { activeSession.stopRunning() }
            dualRecorder = nil
            publish { self.dualPreview = nil }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
            videoInput = nil; audioInput = nil; pressureObserver = nil; configured = false
            if requested.dualCapture && requested.captureMode == .video {
                do {
                    let dual = DualCameraCapture(queue: captureQueue)
                    let mode = try dual.configure(mode: requested.mode, audio: requested.microphoneEnabled)
                    var applied = requested
                    applied.quality = mode.quality; applied.fps = mode.fps; applied.dynamicRange = .sdr
                    applied.frontCamera = false; applied.rearLens = .automatic
                    videoInput = dual.rearInput; zoomScale = 1
                    dualRecorder = dual; captureSettings = applied; configured = true
                    publish { self.dualPreview = dual }
                    if mode != requested.mode {
                        publish { self.showMessage("双摄录像格式", "已使用设备支持的 \(mode.title)。关闭双摄后可重新选择单摄的高画质与高帧率。") }
                    }
                    return applied
                } catch {
                    var fallback = previous
                    fallback.dualCapture = false
                    let restored = try configureOnQueue(fallback)
                    let detail = error.localizedDescription
                    publish { self.showMessage("双摄暂不可用", detail + " 已恢复单摄，可以继续拍摄。") }
                    return restored
                }
            }
        }
        guard let device = Self.camera(front: requested.frontCamera,
                                      mode: requested.captureMode == .video ? requested.mode : nil,
                                      lens: requested.rearLens) else {
            throw RecorderError("没有可用摄像头。")
        }
        var applied = requested
        if device.deviceType != .builtInTelephotoCamera { applied.rearLens = .automatic }
        if applied.captureMode != .video {
            applied.captureMode = applied.livePhotoEnabled ? .livePhoto : .photo
        }
        let modes = Self.modes(for: device)
        let chosen = Self.closestMode(to: requested.mode, in: modes)
        let format = Self.format(for: chosen, device: device)
        if requested.captureMode == .video {
            guard format != nil else { throw RecorderError("当前镜头没有支持的录像格式。") }
            applied.quality = chosen.quality
            applied.fps = chosen.fps
            applied.dynamicRange = chosen.dynamicRange
        }
        let input: AVCaptureDeviceInput
        if let current = videoInput, current.device.uniqueID == device.uniqueID { input = current }
        else { input = try AVCaptureDeviceInput(device: device) }
        let oldVideo = videoInput
        let oldAudio = audioInput
        let oldSettings = captureSettings
        let oldOutputs = session.outputs
        let oldPreset = session.sessionPreset
        let oldLiveEnabled = photoOutput.isLivePhotoCaptureEnabled
        let oldPhotoDimensions = photoOutput.maxPhotoDimensions
        let oldFormat = device.activeFormat
        let oldMinimum = device.activeVideoMinFrameDuration
        let oldMaximum = device.activeVideoMaxFrameDuration
        let oldZoom = device.videoZoomFactor
        let oldColorSpace = device.activeColorSpace
        let oldAutoHDR = device.automaticallyAdjustsVideoHDREnabled
        let oldHDR = device.isVideoHDREnabled
        let oldWideColor = session.automaticallyConfiguresCaptureDeviceForWideColor
        let newAudio: AVCaptureDeviceInput?
        if applied.microphoneEnabled && applied.captureMode != .photo {
            guard Self.hasPurposeString("NSMicrophoneUsageDescription"),
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  let microphone = AVCaptureDevice.default(for: .audio) else { throw RecorderError("麦克风不可用，可关闭声音后重试。") }
            newAudio = try oldAudio ?? AVCaptureDeviceInput(device: microphone)
        } else { newAudio = nil }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Public iPad multitasking support only; no background/VoIP entitlement.
        let multitasking = session.isMultitaskingCameraAccessSupported
        if multitasking { session.isMultitaskingCameraAccessEnabled = true }
        publish { self.multitaskingCameraSupported = multitasking }
        do {
            if oldVideo !== input {
                turnTorchOff()
                if let old = oldVideo { session.removeInput(old) }
                guard session.canAddInput(input) else { throw RecorderError("无法启用摄像头。") }
                session.addInput(input)
            }
            if oldAudio !== newAudio {
                if let old = oldAudio { session.removeInput(old) }
                if let audio = newAudio {
                    guard session.canAddInput(audio) else { throw RecorderError("无法启用麦克风。") }
                    session.addInput(audio)
                }
            }
            // Movie file output disables Live Photo. Keep the outputs exclusive.
            if applied.captureMode == .video {
                if session.outputs.contains(where: { $0 === photoOutput }) { session.removeOutput(photoOutput) }
                if !session.outputs.contains(where: { $0 === movieOutput }) {
                    guard session.canAddOutput(movieOutput) else { throw RecorderError("无法启用录像输出。") }
                    session.addOutput(movieOutput)
                }
            } else {
                if session.outputs.contains(where: { $0 === movieOutput }) { session.removeOutput(movieOutput) }
                if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                if !session.outputs.contains(where: { $0 === photoOutput }) {
                    guard session.canAddOutput(photoOutput) else { throw RecorderError("无法启用照片输出。") }
                    session.addOutput(photoOutput)
                }
                photoOutput.maxPhotoQualityPrioritization = .quality
                if applied.captureMode == .livePhoto && !photoOutput.isLivePhotoCaptureSupported {
                    applied.captureMode = .photo
                    applied.livePhotoEnabled = false
                    publish { self.showMessage("当前镜头不支持 Live Photo", "已切换普通拍照。可尝试切换前后摄像头。") }
                }
                photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported && applied.captureMode == .livePhoto
            }
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if applied.captureMode == .video, let format = format {
                // activeFormat selects inputPriority automatically on iOS.
                session.automaticallyConfiguresCaptureDeviceForWideColor = false
                device.activeFormat = format
                device.automaticallyAdjustsVideoHDREnabled = false
                if format.isVideoHDRSupported { device.isVideoHDREnabled = false }
                device.activeColorSpace = chosen.dynamicRange == .hdr ? .HLG_BT2020 : .sRGB
                let duration = CMTime(value: 1, timescale: CMTimeScale(chosen.fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            } else {
                session.automaticallyConfiguresCaptureDeviceForWideColor = true
                // Use Apple's processed-photo pipeline at the largest directly
                // delivered dimensions. 24MP deferred proxies need PhotoKit and
                // are not suitable for our durable local-original workflow.
                let dimensions = device.activeFormat.supportedMaxPhotoDimensions
                let direct = dimensions.filter {
                    let pixels = Int64($0.width) * Int64($0.height)
                    return !(pixels > 20_000_000 && pixels < 30_000_000)
                        && (applied.captureMode != .livePhoto || pixels <= 16_000_000)
                }
                if let maximum = (direct.isEmpty ? dimensions : direct).max(by: {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }) { photoOutput.maxPhotoDimensions = maximum }
                if photoOutput.isContentAwareDistortionCorrectionSupported {
                    photoOutput.isContentAwareDistortionCorrectionEnabled = true
                }
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.setExposureTargetBias(0, completionHandler: nil)
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.isSubjectAreaChangeMonitoringEnabled = true
            if device.hasTorch && device.isTorchModeSupported(.off) { device.torchMode = .off }
            videoInput = input
            audioInput = newAudio
            zoomScale = Self.displayZoomScale(device)
            let limits = zoomLimits(device)
            let defaultZoom: CGFloat = device.deviceType == .builtInTelephotoCamera ? 1 : zoomScale
            let targetZoom = displayedZoom.map { $0 * zoomScale } ?? (oldVideo === input ? oldZoom : defaultZoom)
            device.videoZoomFactor = min(max(targetZoom, limits.lowerBound), limits.upperBound)
            captureSettings = applied
            if applied.captureMode == .video {
                movieOutput.minFreeDiskSpaceLimit = applied.reserveBytes
                movieOutput.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
                if let connection = movieOutput.connection(with: .video) {
                    let codecs = movieOutput.availableVideoCodecTypes
                    if applied.dynamicRange == .hdr && !codecs.contains(.hevc) {
                        throw RecorderError("当前输出无法录制 HEVC HDR，请选择 SDR。")
                    }
                    if codecs.contains(.hevc) {
                        movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                    } else if codecs.contains(.h264) {
                        movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                    }
                    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .standard }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                }
            }
            pressureObserver = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] _, _ in
                guard let self = self else { return }
                self.captureQueue.async { self.readCaptureLoadOnQueue() }
            }
            configured = true
            if applied.captureMode == .video && chosen != requested.mode {
                publish { self.showMessage("已调整录像格式", "已选用当前镜头支持的 \(chosen.title)。") }
            }
            return applied
        } catch {
            for output in session.outputs { session.removeOutput(output) }
            if input !== oldVideo { session.removeInput(input) }
            if let old = oldVideo, !session.inputs.contains(where: { $0 === old }), session.canAddInput(old) { session.addInput(old) }
            if let audio = newAudio, audio !== oldAudio { session.removeInput(audio) }
            if let old = oldAudio, !session.inputs.contains(where: { $0 === old }), session.canAddInput(old) { session.addInput(old) }
            if oldPreset != .inputPriority, session.canSetSessionPreset(oldPreset) { session.sessionPreset = oldPreset }
            for output in oldOutputs where session.canAddOutput(output) { session.addOutput(output) }
            if let _ = try? device.lockForConfiguration() {
                device.activeFormat = oldFormat
                device.activeVideoMinFrameDuration = oldMinimum
                device.activeVideoMaxFrameDuration = oldMaximum
                device.activeColorSpace = oldColorSpace
                device.automaticallyAdjustsVideoHDREnabled = oldAutoHDR
                if oldFormat.isVideoHDRSupported { device.isVideoHDREnabled = oldHDR }
                device.videoZoomFactor = oldZoom
                device.unlockForConfiguration()
            }
            videoInput = oldVideo
            audioInput = oldAudio
            captureSettings = oldSettings
            session.automaticallyConfiguresCaptureDeviceForWideColor = oldWideColor
            if session.outputs.contains(where: { $0 === photoOutput }) {
                photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported && oldLiveEnabled
                if oldVideo?.device.activeFormat.supportedMaxPhotoDimensions.contains(where: {
                    $0.width == oldPhotoDimensions.width && $0.height == oldPhotoDimensions.height
                }) == true { photoOutput.maxPhotoDimensions = oldPhotoDimensions }
            }
            throw error
        }
    }

    private static func cameras(front: Bool) -> [AVCaptureDevice] {
        let position: AVCaptureDevice.Position = front ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = front
            ? [.builtInWideAngleCamera, .builtInTrueDepthCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                        position: position).devices
        // Prefer a virtual multi-lens camera so pinch zoom can cross the 0.5x / 1x
        // boundary during a single recording when the device supports it.
        return types.compactMap { type in devices.first(where: { $0.deviceType == type }) }
    }

    static func camera(front: Bool, mode: VideoMode? = nil, lens: RearCameraLens = .automatic) -> AVCaptureDevice? {
        let devices = cameras(front: front)
        if !front && lens == .telephoto,
           let telephoto = devices.first(where: { $0.deviceType == .builtInTelephotoCamera }) { return telephoto }
        // Some high-speed modes exist only on the physical main camera.
        if let mode = mode, let exact = devices.first(where: { format(for: mode, device: $0) != nil }) { return exact }
        return devices.first
    }

    static func modes(for device: AVCaptureDevice) -> [VideoMode] {
        VideoQuality.allCases.flatMap { quality in
            [24, 30, 60, 120].flatMap { fps in
                VideoDynamicRange.allCases.compactMap { range in
                    let mode = VideoMode(quality: quality, fps: fps, dynamicRange: range)
                    return format(for: mode, device: device) == nil ? nil : mode
                }
            }
        }
    }

    static func format(for mode: VideoMode, device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let colorSupported: Bool
            if mode.dynamicRange == .hdr {
                colorSupported = subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    && format.supportedColorSpaces.contains(.HLG_BT2020)
            } else {
                colorSupported = (subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                    && format.supportedColorSpaces.contains(.sRGB)
            }
            return size.width == mode.quality.width && size.height == mode.quality.height
                && colorSupported
                && format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= Double(mode.fps) && $0.maxFrameRate >= Double(mode.fps)
                }
        }.min { left, right in
            let lhs = left.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let rhs = right.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            return lhs < rhs
        }
    }

    static func closestMode(to requested: VideoMode, in modes: [VideoMode]) -> VideoMode {
        VideoMode.closest(to: requested, in: modes)
    }

    private static func displayZoomScale(_ device: AVCaptureDevice) -> CGFloat {
        if device.deviceType == .builtInTelephotoCamera, let base = telephotoBase() { return 1 / base }
        if #available(iOS 18.0, *), device.displayVideoZoomFactorMultiplier > 0 {
            return 1 / device.displayVideoZoomFactorMultiplier
        }
        if device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
           let firstSwitch = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(truncating: firstSwitch)
        }
        return 1
    }

    private static func telephotoBase() -> CGFloat? {
        let devices = cameras(front: false)
        guard devices.contains(where: { $0.deviceType == .builtInTelephotoCamera }),
              let virtual = devices.first(where: { $0.constituentDevices.contains { $0.deviceType == .builtInTelephotoCamera } }) else { return nil }
        let multiplier: Double
        if #available(iOS 18.0, *) { multiplier = Double(virtual.displayVideoZoomFactorMultiplier) }
        else { multiplier = 1 / Double(displayZoomScale(virtual)) }
        return CameraZoom.telephotoBase(switchOvers: virtual.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue },
                                       multiplier: multiplier).map { CGFloat($0) }
    }

    private static func lensLabel(_ device: AVCaptureDevice) -> String {
        if device.position == .front { return "前置相机" }
        let actual = device.activePrimaryConstituent ?? device
        switch actual.deviceType {
        case .builtInTelephotoCamera: return "后置长焦"
        case .builtInUltraWideCamera: return "后置超广角"
        default: return "后置主摄"
        }
    }

    private func zoomLimits(_ device: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let low = device.minAvailableVideoZoomFactor
        let high = max(low, min(device.maxAvailableVideoZoomFactor,
                                device.activeFormat.videoMaxZoomFactor, zoomScale * 10))
        return low...high
    }

    private func publishCapabilities() {
        guard let device = videoInput?.device else { return }
        let candidates = captureSettings.rearLens == .telephoto && !captureSettings.frontCamera
            ? [device] : Self.cameras(front: captureSettings.frontCamera)
        let modes = dualRecorder != nil ? dualCaptureModes : Array(Set(candidates.flatMap { Self.modes(for: $0) }))
            .sorted { ($0.quality.width, $0.fps, $0.dynamicRange.rawValue) < ($1.quality.width, $1.fps, $1.dynamicRange.rawValue) }
        let limits = zoomLimits(device)
        let low = limits.lowerBound / zoomScale
        let high = limits.upperBound / zoomScale
        let current = device.videoZoomFactor / zoomScale
        let telephoto = captureSettings.frontCamera || captureSettings.dualCapture ? nil : Self.telephotoBase()
        var shortcutMinimum = low
        var shortcutMaximum = high
        var shortcutTelephoto = telephoto
        if !capturePhase.blocksConfiguration && !captureSettings.frontCamera && !captureSettings.dualCapture {
            if captureSettings.rearLens == .telephoto,
               let automatic = Self.camera(front: false, mode: captureSettings.captureMode == .video ? captureSettings.mode : nil) {
                shortcutMinimum = automatic.minAvailableVideoZoomFactor / Self.displayZoomScale(automatic)
            }
            shortcutMaximum = max(high, (telephoto ?? 0) * 2)
        } else if !device.isVirtualDevice && device.deviceType != .builtInTelephotoCamera {
            shortcutTelephoto = nil
        }
        let stops = CameraZoom.stops(minimum: Double(shortcutMinimum), maximum: Double(shortcutMaximum),
                                    telephoto: shortcutTelephoto.map { Double($0) }).map { CGFloat($0) }
        let label = dualRecorder != nil ? "前后双摄" : Self.lensLabel(device)
        let torchAvailable = device.hasTorch && device.isTorchAvailable
        let on = device.torchMode == .on
        let supportsLive = self.captureSettings.captureMode != .video && self.photoOutput.isLivePhotoCaptureSupported
        publish {
            self.supportedModes = modes
            self.minimumZoom = low
            self.maximumZoom = high
            self.zoom = current
            self.zoomStops = stops
            self.activeLensLabel = label
            self.hasTorch = torchAvailable
            self.torchOn = on
            self.livePhotoSupported = supportsLive
        }
    }

    func selectZoom(_ value: CGFloat) {
        guard isReady, !isConfiguring else { return }
        if canConfigure && !settings.frontCamera && !settings.dualCapture {
            let wantsTelephoto = Self.telephotoBase().map { value >= $0 - 0.01 } ?? false
            let lens: RearCameraLens = wantsTelephoto ? .telephoto : .automatic
            if lens != settings.rearLens {
                var requested = settings
                requested.rearLens = lens
                apply(requested, displayedZoom: value)
                return
            }
        }
        setZoom(value)
    }

    func setZoom(_ displayedZoom: CGFloat) {
        captureQueue.async {
            guard let device = self.videoInput?.device,
                  self.configured, self.foreground else { return }
            do {
                try device.lockForConfiguration()
                let limits = self.zoomLimits(device)
                device.videoZoomFactor = min(max(displayedZoom * self.zoomScale,
                                                 limits.lowerBound), limits.upperBound)
                device.unlockForConfiguration()
                self.publishCapabilities()
            } catch { self.report("变焦失败", error.localizedDescription) }
        }
    }

    func focus(at point: CGPoint) {
        captureQueue.async {
            guard let device = self.videoInput?.device, self.configured, self.foreground else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
            } catch { self.report("对焦失败", error.localizedDescription) }
        }
    }



    func toggleTorch() {
        captureQueue.async {
            guard let device = self.videoInput?.device, self.foreground,
                  device.hasTorch, device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.torchMode == .on { device.torchMode = .off }
                else { try device.setTorchModeOn(level: min(0.5, AVCaptureDevice.maxAvailableTorchLevel)) }
                self.publishCapabilities()
            } catch { self.report("补光灯不可用", error.localizedDescription) }
        }
    }

    private func turnTorchOff() {
        guard let device = videoInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        } catch { /* The camera may already be unavailable during an interruption. */ }
        publish { self.torchOn = false }
    }

    func updateOrientation(_ interface: UIInterfaceOrientation) {
        let value: AVCaptureVideoOrientation
        switch interface {
        case .landscapeLeft: value = .landscapeLeft
        case .landscapeRight: value = .landscapeRight
        case .portraitUpsideDown: value = .portraitUpsideDown
        default: value = .portrait
        }
        captureQueue.async { self.orientation = value }
    }

    func startRecording(location: CaptureLocation? = nil, resumedFrom: UUID? = nil) {
        guard canRecord, settings.captureMode == .video else { return }
        phase = .preparing
        status = "正在开始录像…"
        captureQueue.async { self.startRecordingOnQueue(location: location, resumedFrom: resumedFrom) }
    }

    private func startRecordingOnQueue(location: CaptureLocation?, resumedFrom: UUID?) {
        resumeAfterBackgroundPending = false
        guard foreground, configured, activeSession.isRunning, !activeSession.isInterrupted,
              capturePhase == .idle else {
            setPhase(.idle)
            report("暂时无法录像", "请确认 App 在前台，并等待相机恢复。")
            return
        }
        guard !captureSettings.thermalProtection || loadOnQueue != .critical else {
            setPhase(.idle)
            report("设备需要冷却", "温度或相机负载过高，本次没有开始录像。")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            setPhase(.idle)
            report("相机权限已关闭", "请在系统设置中允许相机权限。")
            return
        }
        guard !captureSettings.microphoneEnabled || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            setPhase(.idle)
            report("麦克风权限已关闭", "请允许麦克风权限，或在录像设置中关闭声音。")
            return
        }
        guard let space = RecorderFiles.availableBytes() else {
            setPhase(.idle)
            report("无法读取存储空间", "为避免录制失败，本次没有开始录像。稍后重试。")
            return
        }
        guard space > captureSettings.reserveBytes + 256 * 1_048_576 else {
            setPhase(.idle)
            report("存储空间不足", "剩余 \(RecorderFiles.sizeLabel(space))。开始录像需要超过保留空间加 256 MB，请先释放空间。")
            return
        }
        do {
            var item = self.newItem(kind: .video, location: location)
            item.resumedFromID = resumedFrom
            let folder = try MediaLibrary.begin(item)
            let url = folder.appendingPathComponent("video.mov")
            movieOutput.metadata = location?.movieMetadata ?? []
            activeItem = item
            if let dual = dualRecorder {
                activeURL = url
                stopRequested = false
                setPhase(.preparing)
                publish { self.elapsed = 0; self.status = "正在开始双摄录像…" }
                dual.start(url: url, orientation: orientation, metadata: location?.movieMetadata ?? [], began: { [weak self] in
                    guard let self else { return }
                    self.fileOutput(self.movieOutput, didStartRecordingTo: url, from: [])
                }, finished: { [weak self] url, error in
                    guard let self else { return }
                    self.fileOutput(self.movieOutput, didFinishRecordingTo: url, from: [], error: error)
                })
                return
            }
            guard let connection = movieOutput.connection(with: .video), connection.isActive else {
                throw RecorderError("摄像头输出暂未就绪，请稍后重试。")
            }
            if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            movieOutput.minFreeDiskSpaceLimit = captureSettings.reserveBytes
            activeURL = url
            stopRequested = false
            setPhase(.preparing)
            publish { self.elapsed = 0; self.status = "正在开始录像…" }
            movieOutput.startRecording(to: url, recordingDelegate: self)
        } catch {
            activeURL = nil
            activeItem = nil
            setPhase(.idle)
            report("开始录像失败", error.localizedDescription)
        }
    }

    func stopRecording() {
        guard phase == .recording || phase == .preparing else { return }
        beginFinishingTask()
        captureQueue.async { self.stopOnQueue(reason: "正在完成录像…") }
    }

    private func stopOnQueue(reason: String, preserveResume: Bool = false) {
        guard capturePhase == .recording || capturePhase == .preparing else { return }
        if !preserveResume { resumeAfterBackgroundPending = false }
        stopRequested = true
        setPhase(.finishing)
        publish { self.status = reason; self.captureFeedback(.stopped) }
        if let dual = dualRecorder { dual.stop() }
        else if movieOutput.isRecording { movieOutput.stopRecording() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        captureQueue.async {
            if self.stopRequested || !self.foreground {
                self.setPhase(.finishing)
                if let dual = self.dualRecorder { dual.stop() }
                else if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            } else {
                self.setPhase(.recording)
                self.publish { self.status = "录像中"; self.captureFeedback(.began) }
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let detail = error?.localizedDescription
        let nsError = error as NSError?
        let finished = error == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        captureQueue.async {
            if error != nil { self.resumeAfterBackgroundPending = false }
            let item = self.activeItem
            self.activeItem = nil
            self.activeURL = nil
            self.stopRequested = false
            self.turnTorchOff()
            if var value = item {
                value.recovered = !finished
                self.completeCaptureOnQueue(value)
            } else { self.finishCaptureStateOnQueue() }
            if let detail = detail {
                self.report(finished ? "录像已自动停止" : "录像异常结束",
                            detail + " 拍摄文件已保留，可在图库查看或导出。")
            }
        }
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard canConfigure else { return }
        var value = settings
        value.captureMode = mode == .video ? .video : value.livePhotoEnabled ? .livePhoto : .photo
        if mode != .video { value.dualCapture = false }
        apply(value)
    }

    func toggleLivePhoto() {
        guard canConfigure, isReady, settings.captureMode != .video, livePhotoSupported else { return }
        var value = settings
        value.livePhotoEnabled.toggle()
        value.captureMode = value.livePhotoEnabled ? .livePhoto : .photo
        apply(value)
    }

    private func newItem(kind: CaptureMode, location: CaptureLocation?) -> MediaItem {
        var item = MediaItem(id: UUID(), kind: kind, createdAt: Date(),
                  camera: captureSettings.dualCapture ? "前后双摄" : videoInput.map { Self.lensLabel($0.device) } ?? "相机",
                  resolution: kind == .video ? "\(captureSettings.quality.width) × \(captureSettings.quality.height)" : "待处理",
                  fps: kind == .video ? captureSettings.fps : nil,
                  dynamicRange: kind == .video ? captureSettings.dynamicRange.title : nil,
                  hasAudio: captureSettings.microphoneEnabled && kind != .photo, location: location)
        if let device = videoInput?.device {
            item.zoomFactor = Double(device.videoZoomFactor / zoomScale)
            item.exposureBias = device.exposureTargetBias
            item.focusExposureLocked = device.focusMode == .locked && device.exposureMode == .locked
        }
        return item
    }

    func takePhoto(location: CaptureLocation? = nil) {
        guard canRecord, settings.captureMode != .video else { return }
        phase = .photographing
        status = "正在拍摄…"
        captureQueue.async {
            guard self.foreground, self.configured, self.capturePhase == .idle,
                  self.activeSession.isRunning, !self.activeSession.isInterrupted,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.finishCaptureStateOnQueue()
                self.report("暂时无法拍照", "请等待相机恢复后重试。")
                return
            }
            guard let free = RecorderFiles.availableBytes(), free > self.captureSettings.reserveBytes + 64 * 1_048_576 else {
                self.finishCaptureStateOnQueue()
                self.report("存储空间不足", "拍照需要超过保留空间加 64 MB。")
                return
            }
            do {
                let live = self.captureSettings.captureMode == .livePhoto
                guard self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) else { throw RecorderError("当前镜头不支持 JPEG 照片输出。") }
                if live && !self.photoOutput.isLivePhotoCaptureEnabled { throw RecorderError("当前镜头未准备好 Live Photo。") }
                let item = self.newItem(kind: live ? .livePhoto : .photo, location: location)
                let folder = try MediaLibrary.begin(item)
                let options = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                options.photoQualityPrioritization = .quality
                options.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                if self.photoOutput.isContentAwareDistortionCorrectionSupported { options.isAutoContentAwareDistortionCorrectionEnabled = true }
                if let location = location { options.metadata = location.gpsMetadata }
                if live {
                    options.livePhotoMovieFileURL = folder.appendingPathComponent("live.mov")
                    options.livePhotoMovieMetadata = location?.movieMetadata ?? []
                }
                if let connection = self.photoOutput.connection(with: .video) {
                    if connection.isVideoOrientationSupported { connection.videoOrientation = self.orientation }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                }
                self.activeItem = item
                self.setPhase(.photographing)
                let processor = PhotoCaptureProcessor(queue: self.captureQueue) { data, resolution, liveSucceeded, detail in
                    self.photoCapture = nil
                    self.activeItem = nil
                    guard let data = data else {
                        self.finishCaptureStateOnQueue()
                        self.report("拍照失败", detail ?? "系统未返回完整照片，请重试。")
                        return
                    }
                    do {
                        var completed = item
                        completed.resolution = resolution
                        if live && !liveSucceeded { completed.kind = .photo }
                        try data.write(to: folder.appendingPathComponent("photo.jpg"), options: .atomic)
                        self.completeCaptureOnQueue(completed)
                        if live && !liveSucceeded {
                            self.report("动态片段未完成", "普通照片已保存到内置图库。" + (detail ?? ""))
                        } else if let detail = detail { self.report("拍摄提示", detail) }
                    } catch {
                        self.finishCaptureStateOnQueue()
                        self.report("照片保存未完成", error.localizedDescription + " 暂存内容仍保留。")
                    }
                }
                self.photoCapture = processor
                self.photoOutput.capturePhoto(with: options, delegate: processor)
            } catch {
                self.activeItem = nil
                self.finishCaptureStateOnQueue()
                self.report("拍照失败", error.localizedDescription)
            }
        }
    }

    private func completeCaptureOnQueue(_ item: MediaItem) {
        setPhase(.saving)
        do {
            try MediaLibrary.finish(item)
            self.createThumbnail(item)
            let automatic = captureSettings.automaticallyExportToPhotos
            publish {
                self.status = "\(item.kind.title)已保存到内置图库"
                self.captureFeedback(.saved)
                if automatic { self.exportToPhotos([item], automatic: true) }
            }
        } catch {
            resumeAfterBackgroundPending = false
            report("保存图库未完成", error.localizedDescription + " 原始暂存内容仍保留。")
        }
        refreshLibraryOnQueue()
        finishCaptureStateOnQueue()
    }

    private func createThumbnail(_ item: MediaItem) {
        Task.detached(priority: .utility) { [weak self] in
            var image: UIImage?
            var seconds: Double?
            if item.kind == .video {
                let asset = AVURLAsset(url: item.movieURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400)
                if let result = try? await generator.image(at: .zero) { image = UIImage(cgImage: result.image) }
                if let duration = try? await asset.load(.duration) { seconds = CMTimeGetSeconds(duration) }
            } else if let source = CGImageSourceCreateWithURL(item.imageURL as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) {
                image = UIImage(cgImage: thumbnail)
            }
            if let data = image?.jpegData(compressionQuality: 0.75) { try? data.write(to: item.thumbnailURL, options: .atomic) }
            let duration = seconds
            guard let self = self else { return }
            self.captureQueue.async {
                if let duration = duration { try? MediaLibrary.setDuration(item, seconds: duration) }
                self.refreshLibraryOnQueue()
                self.publish { self.thumbnailGeneration += 1 }
            }
        }
    }

    private func finishCaptureStateOnQueue() {
        setPhase(.idle)
        if !foreground && activeSession.isRunning { activeSession.stopRunning() }
        resumeSessionOnQueue()
        let ready = foreground && activeSession.isRunning && !activeSession.isInterrupted
            && (!captureSettings.thermalProtection || loadOnQueue != .critical)
        publish { self.isReady = ready; self.endFinishingTask() }
    }

    private func resumeSessionOnQueue() {
        guard foreground, configured, capturePhase == .idle else { return }
        guard !captureSettings.thermalProtection || loadOnQueue != .critical else {
            if activeSession.isRunning { activeSession.stopRunning() }
            publish { self.isReady = false; self.status = "等待设备冷却" }
            return
        }
        guard !activeSession.isInterrupted else {
            publish { self.isReady = false; self.status = "等待系统解除相机中断" }
            return
        }
        if !activeSession.isRunning { activeSession.startRunning() }
        let ready = activeSession.isRunning && !activeSession.isInterrupted
        let label = captureSettings.captureMode == .video ? "准备录像" : "准备拍照"
        publish {
            self.isReady = ready
            self.status = ready ? label : "等待相机恢复，可点击重试"
        }
        requestResumeOnQueue(ready: ready)
    }

    private func requestResumeOnQueue(ready: Bool) {
        guard ready, foreground, capturePhase == .idle, resumeAfterBackgroundPending else { return }
        resumeAfterBackgroundPending = false
        guard captureSettings.resumeAfterBackground, captureSettings.captureMode == .video,
              let previous = resumeSourceID else { return }
        publish { self.resumeRequest = previous }
    }

    func refreshLibrary() { captureQueue.async { self.refreshLibraryOnQueue() } }
    private func refreshLibraryOnQueue() {
        let items = MediaLibrary.items()
        let space = RecorderFiles.availableBytes()
        publish { self.libraryItems = items; self.availableSpace = space }
    }

    func exportToPhotos(_ item: MediaItem) {
        exportToPhotos([item], allowRepeats: true)
    }

    func exportToPhotos(_ items: [MediaItem], allowRepeats: Bool = false, automatic: Bool = false) {
        let values = items.filter { !exportingPhotoIDs.contains($0.id) && (allowRepeats || $0.exportedAt == nil) }
        guard !values.isEmpty else { return }
        if exportingPhotoIDs.isEmpty { failedPhotosExports = 0 }
        exportingPhotoIDs.formUnion(values.map(\.id))
        photosExportStatus = "正在导出到系统照片…"
        Task { @MainActor in
            if !mainForeground && PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
                exportingPhotoIDs.subtract(values.map(\.id))
                photosExportStatus = "原件已保存，回到前台授权后可导出"
                return
            }
            let granted = await Self.requestPhotosPermission()
            guard granted else {
                exportingPhotoIDs.subtract(values.map(\.id))
                photosExportStatus = "未导出到系统照片，App 原件保留"
                if !automatic { showMessage("需要照片添加权限", "请在系统设置中允许添加照片后重试。内置图库中的原件仍保留。") }
                return
            }
            captureQueue.async {
                self.pendingPhotosExports += values.map { ($0, automatic) }
                self.processPhotosExportOnQueue()
            }
        }
    }

    private func processPhotosExportOnQueue() {
        guard !photosExportRunning, !pendingPhotosExports.isEmpty else { return }
        let (item, automatic) = pendingPhotosExports.removeFirst()
        photosExportRunning = true
        guard item.resourceURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            finishPhotosExportOnQueue(item, success: false, detail: "原文件不完整。", automatic: automatic)
            return
        }
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = item.createdAt
            request.location = item.location?.clLocation
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            switch item.kind {
            case .video: request.addResource(with: .video, fileURL: item.movieURL, options: options)
            case .photo: request.addResource(with: .photo, fileURL: item.imageURL, options: options)
            case .livePhoto:
                request.addResource(with: .photo, fileURL: item.imageURL, options: options)
                request.addResource(with: .pairedVideo, fileURL: item.movieURL, options: options)
            }
        }) { success, error in
            let detail = error?.localizedDescription
            self.captureQueue.async {
                self.finishPhotosExportOnQueue(item, success: success, detail: detail, automatic: automatic)
            }
        }
    }

    private func finishPhotosExportOnQueue(_ item: MediaItem, success: Bool, detail: String?, automatic: Bool) {
        photosExportRunning = false
        if success {
            do { try MediaLibrary.markExported(item) }
            catch { report("已导出，标记未更新", "系统照片已有副本，App 原件保留。" + error.localizedDescription) }
        }
        refreshLibraryOnQueue()
        publish {
            self.exportingPhotoIDs.remove(item.id)
            if !success { self.failedPhotosExports += 1 }
            self.photosExportStatus = self.exportingPhotoIDs.isEmpty
                ? (self.failedPhotosExports == 0 ? "系统照片导出完成，App 原件保留" : "\(self.failedPhotosExports) 项未导出，App 原件保留，可重试")
                : "正在导出，剩余 \(self.exportingPhotoIDs.count) 项；失败 \(self.failedPhotosExports) 项"
            if !success && !automatic { self.showMessage("导出未完成", "App 内原件仍保留。\n" + (detail ?? "系统照片暂不可用")) }
        }
        processPhotosExportOnQueue()
    }

    func prepareShare(_ items: [MediaItem]) {
        guard !preparingShare, shareExport == nil, !items.isEmpty else { return }
        preparingShare = true
        mediaQueue.async {
            do {
                let value = try MediaLibrary.prepareExport(items)
                self.publish { self.preparingShare = false; self.preparedShare = value; self.shareExport = value }
            } catch {
                self.publish { self.preparingShare = false }
                self.report("原件导出未完成", error.localizedDescription)
            }
        }
    }

    func finishSharing() {
        guard let export = preparedShare else { return }
        preparedShare = nil
        shareExport = nil
        mediaQueue.async { try? FileManager.default.removeItem(at: export.folder) }
    }

    func deleteMedia(_ item: MediaItem) {
        guard canConfigure, !exportingPhotoIDs.contains(item.id), !preparingShare, shareExport == nil else { return }
        captureQueue.async {
            guard self.capturePhase == .idle else { return }
            do { try MediaLibrary.delete(item) }
            catch { self.report("删除失败", error.localizedDescription) }
            self.refreshLibraryOnQueue()
        }
    }

    private func tick() {
        tickCount += 1
        readCaptureLoadOnQueue()
        if !foreground && capturePhase == .recording {
            stopOnQueue(reason: "离开前台，正在保存…")
            if activeSession.isRunning { activeSession.stopRunning() }
            publish { self.isReady = false }
        }
        if capturePhase == .recording {
            let value = dualRecorder?.elapsed ?? CMTimeGetSeconds(movieOutput.recordedDuration)
            publish { self.elapsed = value.isFinite ? max(0, value) : 0 }
        }
        if tickCount % 3 == 0 || capturePhase == .recording {
            let free = RecorderFiles.availableBytes()
            publish { self.availableSpace = free }
            if capturePhase == .recording {
                if let free = free, free <= captureSettings.reserveBytes {
                    stopOnQueue(reason: "空间不足，正在停止并保存…")
                    report("剩余空间较低", "已自动停止录像，并尝试保存已录制的视频。")
                } else if free == nil {
                    stopOnQueue(reason: "无法读取空间，正在停止并保存…")
                    report("存储空间检测失败", "已停止录像，并尝试保存已录制的视频。")
                }
            }
        }
    }

    private func readCaptureLoadOnQueue() {
        let thermal = ProcessInfo.processInfo.thermalState
        let pressures = [videoInput?.device, dualRecorder?.frontInput?.device].compactMap { $0?.systemPressureState.level }
        let value: CaptureLoad
        if thermal == .critical || pressures.contains(.critical) || pressures.contains(.shutdown) { value = .critical }
        else if thermal == .serious || pressures.contains(.serious) { value = .elevated }
        else { value = .normal }
        updateCaptureLoadOnQueue(value)
    }

    private func updateCaptureLoadOnQueue(_ value: CaptureLoad) {
        let old = loadOnQueue
        loadOnQueue = value
        if old != value { publish { self.captureLoad = value } }
        if value == .critical && captureSettings.thermalProtection {
            resumeAfterBackgroundPending = false
            turnTorchOff()
            if capturePhase == .recording || capturePhase == .preparing {
                stopOnQueue(reason: "设备负载过高，正在停止并保存…")
                report("设备需要冷却", "已停止录像并尝试保存。画质和帧率没有被自动改变，请等待设备恢复后再拍摄。")
            } else if capturePhase == .idle {
                if activeSession.isRunning { activeSession.stopRunning() }
                publish { self.isReady = false; self.status = "等待设备冷却" }
            }
        } else if old == .critical && value != .critical { resumeSessionOnQueue() }
    }

    private enum CaptureFeedback { case began, stopped, saved }
    private func captureFeedback(_ value: CaptureFeedback) {
        guard settings.hapticFeedback, mainForeground else { return }
        switch value {
        case .began: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .stopped: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .saved: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        // Playgrounds hosts the running app; also follow UIKit lifecycle events
        // instead of relying exclusively on the hosted SwiftUI scenePhase.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.sceneChanged(.background)
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.sceneChanged(.active)
        })
        observers.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.phase.blocksConfiguration { self.beginFinishingTask() }
            self.captureQueue.async {
                self.resumeAfterBackgroundPending = false
                self.turnTorchOff()
                self.stopOnQueue(reason: "设备已锁定，正在保存…")
                if self.activeSession.isRunning { self.activeSession.stopRunning() }
                self.publish { self.isReady = false }
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let observed = notification.object as? AVCaptureSession
            let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            let background = reason == AVCaptureSession.InterruptionReason.videoDeviceNotAvailableInBackground.rawValue
            if background && UIApplication.shared.applicationState != .active { self.sceneChanged(.background) }
            if self.phase.blocksConfiguration { self.beginFinishingTask() }
            self.captureQueue.async {
                guard observed === self.activeSession else { return }
                // A queued notification can outlive the interruption itself.
                guard self.activeSession.isInterrupted else { self.resumeSessionOnQueue(); return }
                self.turnTorchOff()
                self.stopOnQueue(reason: "相机被系统中断，正在保存…")
                self.publish { self.isReady = false; self.status = "相机暂被系统占用" }
                if !background {
                    self.resumeAfterBackgroundPending = false
                    self.report("相机已中断", "相机可能被其他 App 占用，或当前窗口模式不支持摄像。回到前台全屏后可重试。")
                }
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let observed = notification.object as? AVCaptureSession
            self.captureQueue.async {
                guard observed === self.activeSession else { return }
                self.resumeSessionOnQueue()
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionDidStartRunning,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let observed = notification.object as? AVCaptureSession
            self.captureQueue.async {
                guard observed === self.activeSession else { return }
                let ready = self.foreground && self.configured && self.activeSession.isRunning && !self.activeSession.isInterrupted
                self.publish { self.isReady = ready }
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionDidStopRunning,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let observed = notification.object as? AVCaptureSession
            self.captureQueue.async {
                guard observed === self.activeSession else { return }
                if !self.activeSession.isRunning { self.publish { self.isReady = false } }
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let observed = notification.object as? AVCaptureSession
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let reportedInForeground = self.mainForeground
            self.captureQueue.async {
                guard observed === self.activeSession else { return }
                self.handleRuntimeErrorOnQueue(error, reportedInForeground: reportedInForeground)
            }
        })
        observers.append(center.addObserver(forName: .AVCaptureDeviceSubjectAreaDidChange,
                                             object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let changedDevice = notification.object as? AVCaptureDevice else { return }
            let changedDeviceID = changedDevice.uniqueID
            self.captureQueue.async {
                guard let device = self.videoInput?.device, device.uniqueID == changedDeviceID else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    device.unlockForConfiguration()
                } catch { /* Autofocus can resume on the next configuration. */ }
            }
        })
    }

    private func handleRuntimeErrorOnQueue(_ error: NSError?, reportedInForeground: Bool) {
        if reportedInForeground { resumeAfterBackgroundPending = false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.0"
        let mode = captureSettings.captureMode == .video ? captureSettings.mode.title : captureSettings.captureMode.title
        let lens = videoInput.map { Self.lensLabel($0.device) } ?? "相机"
        let detail = "畅游 \(version) · \(mode) · \(lens)\n" + CameraErrorDetail.describe(error)
        publish {
            self.lastCameraError = detail
            UserDefaults.standard.set(detail, forKey: "Recorder.lastCameraError")
        }
        // A background notification may reach our queue after a successful return.
        // Preserve a new, healthy capture instead of stopping it for that old event.
        if !reportedInForeground && foreground && activeSession.isRunning && !activeSession.isInterrupted { return }
        stopOnQueue(reason: "相机发生错误，正在完成录像…")
        publish { self.isReady = false; self.status = "相机暂不可用，可点击重试" }
        guard foreground, reportedInForeground else { return }
        if error?.domain == AVFoundationErrorDomain,
           error?.code == AVError.Code.mediaServicesWereReset.rawValue,
           capturePhase == .idle, !runtimeRecoveryAttempted, !activeSession.isInterrupted {
            runtimeRecoveryAttempted = true
            resumeSessionOnQueue()
            if activeSession.isRunning && !activeSession.isInterrupted { return }
        }
        report("相机运行错误", detail + "\n可在设置中复制最近相机错误。")
    }

    private static func requestCapturePermission(_ media: AVMediaType) async -> Bool {
        let key = media == .video ? "NSCameraUsageDescription" : "NSMicrophoneUsageDescription"
        guard hasPurposeString(key) else { return false }
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: media) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    private static func requestPhotosPermission() async -> Bool {
        guard hasPurposeString("NSPhotoLibraryAddUsageDescription")
                || hasPurposeString("NSPhotoLibraryUsageDescription") else { return false }
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
            }
        }
        return status == .authorized || status == .limited
    }

    private static func hasPurposeString(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginFinishingTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask == .invalid else { return }
            // A finite task finishes the file after foreground capture stops.
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishRecording") { [weak self] in
                guard let self = self else { return }
                self.captureQueue.async {
                    if let dual = self.dualRecorder { dual.stop() }
                else if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                    if self.activeSession.isRunning { self.activeSession.stopRunning() }
                }
                self.endFinishingTask()
            }
        }
    }

    private func endFinishingTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    private func setPhase(_ value: RecordingPhase) {
        capturePhase = value
        if configured && (value == .recording || value == .idle) { publishCapabilities() }
        publish {
            self.phase = value
            // System and low-space stops still need time to finish the file.
            if value == .finishing { self.beginFinishingTask() }
        }
    }
    private func publish(_ action: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: action) }
    private func report(_ title: String, _ detail: String) { publish { self.showMessage(title, detail) } }
    private func showMessage(_ title: String, _ detail: String) {
        message = RecorderMessage(title: title, detail: detail)
    }
}

private struct RecorderError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}
