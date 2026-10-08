import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var recorder: RecorderController
    let onBlackScreen: () -> Void

    func makeUIView(context: Context) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.previewLayer.session = recorder.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = { recorder.focus(at: $0) }
        view.onZoom = { recorder.setZoom($0) }
        view.onDoubleTap = onBlackScreen
        view.currentZoom = { recorder.zoom }
        view.onOrientation = {
            recorder.updateOrientation($0)
        }
        view.onWindowChange = { [weak view] in
            if let view, recorder.dualPreview != nil { recorder.attachDualPreview(view.previewLayer, view.frontPreviewLayer) }
        }
        return view
    }

    func updateUIView(_ view: CapturePreviewView, context: Context) {
        view.onDoubleTap = onBlackScreen
        view.gesturesEnabled = recorder.isReady && !recorder.isConfiguring
            && (recorder.phase == .idle || recorder.phase == .recording)
        view.dualCapture = recorder.dualPreview != nil
        view.frontCamera = !view.dualCapture && recorder.settings.frontCamera
        if view.dualCapture {
            recorder.attachDualPreview(view.previewLayer, view.frontPreviewLayer)
        } else {
            if view.previewLayer.session !== recorder.session { view.previewLayer.session = recorder.session }
            view.frontPreviewLayer.session = nil
        }
        view.updateConnection()
    }

    static func dismantleUIView(_ view: CapturePreviewView, coordinator: ()) {
        view.onWindowChange = nil
        view.onOrientation = nil
        view.previewLayer.session = nil
        view.frontPreviewLayer.session = nil
    }
}

final class CapturePreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let frontPreviewLayer = AVCaptureVideoPreviewLayer()
    var dualCapture = false { didSet { frontPreviewLayer.isHidden = !dualCapture; setNeedsLayout() } }
    var onFocus: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onDoubleTap: (() -> Void)?
    var currentZoom: (() -> CGFloat)?
    var onOrientation: ((UIInterfaceOrientation) -> Void)?
    var onWindowChange: (() -> Void)?
    var frontCamera = false
    var gesturesEnabled = false
    private var pinchStart: CGFloat = 1
    private let focusRing = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        frontPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.cornerRadius = 14
        frontPreviewLayer.masksToBounds = true
        frontPreviewLayer.isHidden = true
        layer.addSublayer(frontPreviewLayer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        focusRing.fillColor = UIColor.clear.cgColor
        focusRing.strokeColor = UIColor.systemYellow.cgColor
        focusRing.lineWidth = 2
        focusRing.opacity = 0
        layer.addSublayer(focusRing)
        isAccessibilityElement = true
        accessibilityLabel = "相机预览"
        accessibilityHint = "单击对焦，双指缩放；录像中或拍照界面双击进入黑屏。"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "进入黑屏", target: self, selector: #selector(accessibilityBlackScreen)),
            UIAccessibilityCustomAction(name: "对焦", target: self, selector: #selector(accessibilityFocus))]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previewLayer.superlayer === layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            frontPreviewLayer.frame = CGRect(x: bounds.width * 0.035,
                                              y: bounds.width < bounds.height ? max(safeAreaInsets.top + 150, bounds.height * 0.20) : safeAreaInsets.top + 64,
                                              width: bounds.width * 0.28, height: bounds.height * 0.28)
            CATransaction.commit()
        }
        updateConnection()
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
        if let connection = frontPreviewLayer.connection {
            if connection.isVideoOrientationSupported {
                switch interface {
                case .landscapeLeft: connection.videoOrientation = .landscapeLeft
                case .landscapeRight: connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                default: connection.videoOrientation = .portrait
                }
            }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
        onOrientation?(interface)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesturesEnabled else { return }
        let point = gesture.location(in: self)
        // The layer conversion accounts for rotation, aspect-fill cropping and
        // front-camera preview mirroring; view coordinates alone are insufficient.
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
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

    @objc private func accessibilityFocus() -> Bool {
        guard gesturesEnabled else { return false }
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: CGPoint(x: bounds.midX, y: bounds.midY)))
        return true
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesturesEnabled else { return }
        if gesture.state == .began { pinchStart = currentZoom?() ?? 1 }
        if gesture.state == .began || gesture.state == .changed {
            onZoom?(pinchStart * gesture.scale)
        }
    }
}
