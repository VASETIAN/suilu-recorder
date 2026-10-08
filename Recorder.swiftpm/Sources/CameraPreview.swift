import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var recorder: RecorderController
    let pictureInPicture: RecorderPictureInPicture

    func makeUIView(context: Context) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.previewLayer.session = recorder.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = { recorder.focus(at: $0) }
        view.onZoom = { recorder.setZoom($0) }
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
        view.gesturesEnabled = recorder.isReady && !recorder.isConfiguring
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

final class CapturePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onFocus: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var currentZoom: (() -> CGFloat)?
    var onOrientation: ((UIInterfaceOrientation) -> Void)?
    var onWindowChange: (() -> Void)?
    var onDetach: (() -> Void)?
    var frontCamera = false
    var gesturesEnabled = false
    private var pinchStart: CGFloat = 1
    private let focusRing = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        focusRing.fillColor = UIColor.clear.cgColor
        focusRing.strokeColor = UIColor.systemYellow.cgColor
        focusRing.lineWidth = 2
        focusRing.opacity = 0
        layer.addSublayer(focusRing)
        isAccessibilityElement = true
        accessibilityLabel = "相机预览"
        accessibilityHint = "点击画面对焦，双指缩放。倍率按钮可直接选择变焦。"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateConnection()
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

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesturesEnabled else { return }
        if gesture.state == .began { pinchStart = currentZoom?() ?? 1 }
        if gesture.state == .began || gesture.state == .changed {
            onZoom?(pinchStart * gesture.scale)
        }
    }
}
