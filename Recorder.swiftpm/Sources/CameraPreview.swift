import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var recorder: RecorderController
    let pictureInPicture: RecorderPictureInPicture
    let onBlackScreen: () -> Void

    func makeUIView(context: Context) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.previewLayer.session = recorder.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = { recorder.focus(at: $0) }
        view.onLockFocus = { recorder.lockFocusAndExposure() }
        view.onExposure = { recorder.setExposureBias($0) }
        view.currentExposure = { recorder.exposureBias }
        view.onZoom = { recorder.setZoom($0) }
        view.onDoubleTap = onBlackScreen
        view.currentZoom = { recorder.zoom }
        view.onOrientation = {
            recorder.updateOrientation($0)
            pictureInPicture.updateOrientation($0, front: recorder.settings.frontCamera)
        }
        view.onWindowChange = { [weak view] in
            if let view = view { pictureInPicture.attach(source: view, recorder: recorder) }
        }
        view.onDetach = { [weak view] in pictureInPicture.detach(source: view) }
        return view
    }

    func updateUIView(_ view: CapturePreviewView, context: Context) {
        view.onDoubleTap = onBlackScreen
        view.gesturesEnabled = recorder.isReady && !recorder.isConfiguring
            && (recorder.phase == .idle || recorder.phase == .recording)
        view.updateFeedback(locked: recorder.focusExposureLocked, exposure: recorder.exposureBias)
        view.frontCamera = recorder.settings.frontCamera
        pictureInPicture.attach(source: view, recorder: recorder)
        view.updateConnection()
    }

    static func dismantleUIView(_ view: CapturePreviewView, coordinator: ()) {
        view.onDetach?()
        view.onWindowChange = nil
        view.onDetach = nil
        view.onOrientation = nil
        view.previewLayer.session = nil
    }
}

final class CapturePreviewView: UIView, UIGestureRecognizerDelegate {
    // One preview connection for the entire app. PiP temporarily moves this
    // same layer rather than binding a second, off-screen camera preview.
    let previewLayer = AVCaptureVideoPreviewLayer()
    var onFocus: ((CGPoint) -> Void)?
    var onLockFocus: (() -> Void)?
    var onExposure: ((Float) -> Void)?
    var currentExposure: (() -> Float)?
    var onZoom: ((CGFloat) -> Void)?
    var onDoubleTap: (() -> Void)?
    var currentZoom: (() -> CGFloat)?
    var onOrientation: ((UIInterfaceOrientation) -> Void)?
    var onWindowChange: (() -> Void)?
    var onDetach: (() -> Void)?
    var frontCamera = false
    var gesturesEnabled = false
    private var pinchStart: CGFloat = 1
    private let focusRing = CAShapeLayer()
    private let exposureLabel = UILabel()
    private var exposureStart: Float = 0
    private var feedbackUntil = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(locked(_:)))
        longPress.minimumPressDuration = 0.7
        addGestureRecognizer(longPress)
        let exposurePan = UIPanGestureRecognizer(target: self, action: #selector(exposurePanned(_:)))
        exposurePan.maximumNumberOfTouches = 1
        exposurePan.delegate = self
        addGestureRecognizer(exposurePan)
        focusRing.fillColor = UIColor.clear.cgColor
        focusRing.strokeColor = UIColor.systemYellow.cgColor
        focusRing.lineWidth = 2
        focusRing.opacity = 0
        layer.addSublayer(focusRing)
        exposureLabel.textColor = .systemYellow
        exposureLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        exposureLabel.textAlignment = .center
        exposureLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        exposureLabel.layer.cornerRadius = 6
        exposureLabel.clipsToBounds = true
        exposureLabel.isHidden = true
        addSubview(exposureLabel)
        isAccessibilityElement = true
        accessibilityLabel = "相机预览"
        accessibilityHint = "单击对焦并解除锁定，长按锁定当前对焦和曝光，上下滑动调明暗，双指缩放；双击进入黑屏。"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "进入黑屏", target: self, selector: #selector(accessibilityBlackScreen)),
            UIAccessibilityCustomAction(name: "锁定对焦和曝光", target: self, selector: #selector(accessibilityLock)),
            UIAccessibilityCustomAction(name: "解除锁定并对焦", target: self, selector: #selector(accessibilityFocus)),
            UIAccessibilityCustomAction(name: "调亮", target: self, selector: #selector(accessibilityBrighter)),
            UIAccessibilityCustomAction(name: "调暗", target: self, selector: #selector(accessibilityDarker))]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previewLayer.superlayer === layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
        updateConnection()
    }

    func restorePreview() {
        previewLayer.videoGravity = .resizeAspectFill
        layer.insertSublayer(previewLayer, at: 0)
        setNeedsLayout()
    }

    @objc private func doubleTapped() { if gesturesEnabled { onDoubleTap?() } }
    @objc private func accessibilityBlackScreen() -> Bool {
        guard gesturesEnabled else { return false }
        onDoubleTap?()
        return true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
        updateConnection()
    }

    func updateConnection() {
        guard let interface = window?.windowScene?.interfaceOrientation else { return }
        if let connection = previewLayer.connection {
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
                connection.isVideoMirrored = frontCamera
            }
        }
        onOrientation?(interface)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesturesEnabled else { return }
        let point = gesture.location(in: self)
        showFocusFeedback(at: point)
        // The layer conversion accounts for rotation, aspect-fill cropping and
        // front-camera preview mirroring; view coordinates alone are insufficient.
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
    }

    private func showFocusFeedback(at point: CGPoint) {
        feedbackUntil = Date().addingTimeInterval(3)
        exposureLabel.frame = CGRect(x: min(max(8, point.x - 80), max(8, bounds.width - 168)),
                                     y: min(point.y + 38, max(0, bounds.height - 30)), width: 160, height: 26)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusRing.path = UIBezierPath(roundedRect: CGRect(x: point.x - 32, y: point.y - 32,
                                                          width: 64, height: 64), cornerRadius: 10).cgPath
        focusRing.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 1.2
        focusRing.add(fade, forKey: "focusFeedback")
    }

    func updateFeedback(locked: Bool, exposure: Float) {
        exposureLabel.text = (locked ? "AE/AF 锁定 · " : "") + String(format: "%+.1f EV", exposure)
        exposureLabel.isHidden = !gesturesEnabled || (!locked && feedbackUntil < Date())
        focusRing.opacity = locked && gesturesEnabled ? 1 : 0
        accessibilityValue = (locked ? "对焦曝光已锁定，" : "") + String(format: "曝光 %+.1f EV", exposure)
    }

    @objc private func locked(_ gesture: UILongPressGestureRecognizer) {
        guard gesturesEnabled, gesture.state == .began else { return }
        showFocusFeedback(at: gesture.location(in: self))
        onLockFocus?()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gesturesEnabled else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x)
        }
        return true
    }

    @objc private func exposurePanned(_ gesture: UIPanGestureRecognizer) {
        guard gesturesEnabled else { return }
        if gesture.state == .began {
            exposureStart = currentExposure?() ?? 0
            showFocusFeedback(at: gesture.location(in: self))
        }
        if gesture.state == .began || gesture.state == .changed {
            feedbackUntil = Date().addingTimeInterval(3)
            onExposure?(exposureStart - Float(gesture.translation(in: self).y / 100))
        }
    }

    @objc private func accessibilityLock() -> Bool { guard gesturesEnabled else { return false }; onLockFocus?(); return true }
    @objc private func accessibilityFocus() -> Bool {
        guard gesturesEnabled else { return false }
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: CGPoint(x: bounds.midX, y: bounds.midY)))
        return true
    }
    @objc private func accessibilityBrighter() -> Bool { guard gesturesEnabled else { return false }; onExposure?((currentExposure?() ?? 0) + 0.3); return true }
    @objc private func accessibilityDarker() -> Bool { guard gesturesEnabled else { return false }; onExposure?((currentExposure?() ?? 0) - 0.3); return true }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesturesEnabled else { return }
        if gesture.state == .began { pinchStart = currentZoom?() ?? 1 }
        if gesture.state == .began || gesture.state == .changed {
            onZoom?(pinchStart * gesture.scale)
        }
    }
}
