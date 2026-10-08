import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Public AVKit camera presentation. It never registers a call or a VoIP mode.
@MainActor
final class RecorderPictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var isPossible = false
    private weak var recorder: RecorderController?
    private weak var sourceView: UIView?
    private var controller: AVPictureInPictureController?
    private var cameraView: PiPCameraView?
    private var observation: NSKeyValueObservation?
    private var requested = false

    private var audioCapabilityLoaded: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") == true
    }

    var status: String {
        if isActive { return "画中画已开启" }
        if isStarting { return "正在开启画中画…" }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return "设备不支持画中画" }
        guard audioCapabilityLoaded else { return "运行环境未加载画中画声明" }
        guard recorder?.multitaskingCameraSupported == true else { return "系统未允许画中画相机" }
        guard recorder?.phase == .recording else { return "开始录像后可开启画中画" }
        return isPossible ? "可以开启画中画" : "画中画暂未就绪"
    }

    var canStart: Bool {
        !isActive && !isStarting && isPossible && audioCapabilityLoaded
            && recorder?.multitaskingCameraSupported == true && recorder?.phase == .recording
    }

    func attach(source: UIView, recorder: RecorderController) {
        guard source.window != nil else { return }
        if sourceView === source && controller != nil { return }
        detach()
        self.recorder = recorder
        sourceView = source
        recorder.onStopPictureInPicture = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let camera = PiPCameraView()
        camera.previewLayer.session = recorder.session
        camera.previewLayer.videoGravity = .resizeAspect
        let content = AVPictureInPictureVideoCallViewController()
        // A normal camera aspect ratio; AVKit owns the actual window size.
        content.preferredContentSize = CGSize(width: 180, height: 320)
        camera.frame = content.view.bounds
        camera.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.view.addSubview(camera)
        let label = UILabel(frame: CGRect(x: 10, y: 8, width: 100, height: 26))
        label.text = "● REC"
        label.textColor = .systemRed
        label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        label.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        label.textAlignment = .center
        label.accessibilityLabel = "正在录像"
        content.view.addSubview(label)
        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: source,
                                                               contentViewController: content)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        controller = pip
        cameraView = camera
        let identity = ObjectIdentifier(pip)
        observation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in
                guard let self = self, self.matches(identity) else { return }
                self.isPossible = possible
            }
        }
    }

    func updateOrientation(_ interface: UIInterfaceOrientation, front: Bool) {
        guard let connection = cameraView?.previewLayer.connection else { return }
        if connection.isVideoOrientationSupported {
            switch interface {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = front
        }
    }

    func start() {
        guard canStart, let controller = controller else {
            recorder?.message = RecorderMessage(title: "暂时无法开启画中画", detail: status)
            return
        }
        requested = true
        isStarting = true
        // Reserve only a bounded transition for the explicit native PiP request.
        recorder?.setPictureInPictureState(.starting)
        controller.startPictureInPicture()
    }

    func stop() {
        let wasRequested = requested || isActive || isStarting
        requested = false
        isStarting = false
        isActive = false
        if wasRequested {
            recorder?.setPictureInPictureState(.inactive)
            controller?.stopPictureInPicture()
        }
    }

    func detach(source: UIView? = nil) {
        if let source = source, sourceView !== source { return }
        stop()
        observation?.invalidate()
        observation = nil
        controller?.delegate = nil
        controller = nil
        cameraView?.previewLayer.session = nil
        cameraView = nil
        sourceView = nil
        isPossible = false
        recorder?.onStopPictureInPicture = nil
        recorder = nil
    }

    private func matches(_ identity: ObjectIdentifier) -> Bool {
        controller.map { ObjectIdentifier($0) } == identity
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
        let identity = ObjectIdentifier(pip)
        Task { @MainActor in
            guard self.matches(identity) else { return }
            guard self.requested, self.recorder?.phase == .recording else {
                self.controller?.stopPictureInPicture()
                return
            }
            self.isStarting = false
            self.isActive = true
            self.recorder?.setPictureInPictureState(.active)
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pip: AVPictureInPictureController) {
        let identity = ObjectIdentifier(pip)
        Task { @MainActor in
            guard self.matches(identity) else { return }
            self.stop()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
        let identity = ObjectIdentifier(pip)
        Task { @MainActor in
            guard self.matches(identity) else { return }
            self.stop()
        }
    }

    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let identity = ObjectIdentifier(pip)
        let detail = error.localizedDescription
        Task { @MainActor in
            guard self.matches(identity) else { return }
            self.stop()
            self.recorder?.message = RecorderMessage(title: "画中画启动失败", detail: detail + " 当前录像会按前台状态继续或停止并保存。")
        }
    }

    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let identity = ObjectIdentifier(pip)
        Task { @MainActor in
            // AVKit restores the original source window. Do not claim restoration
            // if the host has destroyed that interface or replaced this request.
            completionHandler(self.matches(identity) && self.sourceView?.window != nil)
        }
    }
}

private final class PiPCameraView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
