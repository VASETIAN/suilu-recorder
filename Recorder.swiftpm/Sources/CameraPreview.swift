import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var recorder: RecorderController
    let onBlackScreen: () -> Void

    func makeCoordinator() -> RecorderController { recorder }

    func makeUIView(context: Context) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.frontOrigin = recorder.frontPreviewOrigin
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = { recorder.focus(at: $0) }
        view.onFrontMoved = { recorder.moveFrontPreview($0) }
        view.onZoom = { recorder.setZoom($0) }
        view.onDoubleTap = onBlackScreen
        view.currentZoom = { recorder.zoom }
        view.onOrientation = {
            recorder.updateOrientation($0)
        }
        view.onWindowChange = { [weak view] in
            if let view { recorder.attachPreview(view.previewLayer, view.frontPreviewLayer) }
        }
        recorder.attachPreview(view.previewLayer, view.frontPreviewLayer)
        return view
    }

    func updateUIView(_ view: CapturePreviewView, context: Context) {
        view.onDoubleTap = onBlackScreen
        view.gesturesEnabled = recorder.isReady && !recorder.isConfiguring
            && (recorder.phase == .idle || recorder.phase == .recording)
        view.dualCapture = recorder.dualCaptureActive
        view.frontOrigin = recorder.frontPreviewOrigin
        recorder.attachPreview(view.previewLayer, view.frontPreviewLayer)
        view.reportOrientation()
    }

    static func dismantleUIView(_ view: CapturePreviewView, coordinator: RecorderController) {
        view.onWindowChange = nil
        view.onOrientation = nil
        coordinator.detachPreview(view.previewLayer, view.frontPreviewLayer)
    }
}

final class CapturePreviewView: UIView, UIGestureRecognizerDelegate {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let frontPreviewLayer = AVCaptureVideoPreviewLayer()
    var dualCapture = false {
        didSet { if oldValue != dualCapture { frontPreviewLayer.isHidden = !dualCapture; setNeedsLayout() } }
    }
    var onFrontMoved: ((CGPoint) -> Void)?
    var onFocus: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onDoubleTap: (() -> Void)?
    var currentZoom: (() -> CGFloat)?
    var onOrientation: ((UIInterfaceOrientation) -> Void)?
    var onWindowChange: (() -> Void)?
    var gesturesEnabled = false
    var frontOrigin = DualPreviewLayout.defaultOrigin {
        didSet { if oldValue != frontOrigin { setNeedsLayout() } }
    }
    private var panStart = DualPreviewLayout.defaultOrigin
    private var frontPan: UIPanGestureRecognizer!
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
        frontPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        frontPan.maximumNumberOfTouches = 1
        frontPan.delegate = self
        tap.require(toFail: frontPan)
        doubleTap.require(toFail: frontPan)
        addGestureRecognizer(frontPan)
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
        accessibilityHint = "单击对焦，双指缩放，双击进入黑屏；双摄时可拖动前置小画面。"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "进入黑屏", target: self, selector: #selector(accessibilityBlackScreen)),
            UIAccessibilityCustomAction(name: "对焦", target: self, selector: #selector(accessibilityFocus)),
            UIAccessibilityCustomAction(name: "前置画面左移", target: self, selector: #selector(moveFrontLeft)),
            UIAccessibilityCustomAction(name: "前置画面右移", target: self, selector: #selector(moveFrontRight)),
            UIAccessibilityCustomAction(name: "前置画面上移", target: self, selector: #selector(moveFrontUp)),
            UIAccessibilityCustomAction(name: "前置画面下移", target: self, selector: #selector(moveFrontDown))]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previewLayer.superlayer === layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            frontPreviewLayer.frame = DualPreviewLayout.rect(in: bounds, origin: frontOrigin)
            CATransaction.commit()
        }
        reportOrientation()
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
        reportOrientation()
    }

    func reportOrientation() {
        guard let interface = window?.windowScene?.interfaceOrientation else { return }
        onOrientation?(interface)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === frontPan {
            return dualCapture && gesturesEnabled && frontPreviewLayer.frame.contains(gesture.location(in: self))
        }
        return true
    }

    private func moveFront(to origin: CGPoint) {
        frontOrigin = DualPreviewLayout.clamped(origin)
        setNeedsLayout()
        onFrontMoved?(frontOrigin)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard dualCapture, gesturesEnabled, bounds.width > 0, bounds.height > 0 else { return }
        if gesture.state == .began { panStart = frontOrigin }
        if gesture.state == .changed || gesture.state == .ended {
            let delta = gesture.translation(in: self)
            moveFront(to: CGPoint(x: panStart.x + delta.x / bounds.width, y: panStart.y + delta.y / bounds.height))
        }
    }

    private func accessibilityMoveFront(x: CGFloat, y: CGFloat) -> Bool {
        guard dualCapture, gesturesEnabled else { return false }
        moveFront(to: CGPoint(x: frontOrigin.x + x, y: frontOrigin.y + y))
        return true
    }
    @objc private func moveFrontLeft() -> Bool { accessibilityMoveFront(x: -0.08, y: 0) }
    @objc private func moveFrontRight() -> Bool { accessibilityMoveFront(x: 0.08, y: 0) }
    @objc private func moveFrontUp() -> Bool { accessibilityMoveFront(x: 0, y: -0.08) }
    @objc private func moveFrontDown() -> Bool { accessibilityMoveFront(x: 0, y: 0.08) }

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
