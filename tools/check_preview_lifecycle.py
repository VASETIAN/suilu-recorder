"""Replay actual preview bridge/binding/drag methods with queue-checking fakes.

This detects simultaneous UI/capture ownership, stale view teardown and drag
geometry. It is not a native camera exception or iPhone touch reproduction.
"""
from pathlib import Path
import argparse
import subprocess
from check_lifecycle import extract

ROOT = Path(__file__).resolve().parent.parent


def build(output: Path, preview_source: Path):
    src = ROOT / 'Recorder.swiftpm/Sources'
    controller = (src / 'RecorderController.swift').read_text(encoding='utf-8')
    preview = preview_source.read_text(encoding='utf-8')
    geometry = extract((src / 'DualCameraCapture.swift').read_text(encoding='utf-8'), 'enum DualPreviewLayout {')
    methods = '\n'.join(extract(controller, s) for s in [
        'func attachPreview(', 'func detachPreview(', 'private func disconnectPreviewOnQueue(',
        'private func bindPreviewOnQueue(', 'private func updatePreviewConnectionsOnQueue(', 'func moveFrontPreview('])
    # Exercise the production mode-change ordering, without mocking all hardware configuration.
    teardown = controller.split('if dualRecorder != nil || requested.dualCapture {', 1)[1]
    teardown = teardown[teardown.index('if activeSession.isRunning'):teardown.index('publish { self.dualCaptureActive')]
    methods += '\nfunc leaveDualOnQueue() {\n' + teardown + '\n}'
    bridge = '\n'.join(extract(preview, s) for s in ['func makeUIView(', 'func updateUIView(', 'static func dismantleUIView('])
    # Use the current gesture code even when testing the previous UIView bridge.
    current = (src / 'CameraPreview.swift').read_text(encoding='utf-8')
    gestures = '\n'.join(extract(current, s).replace('@objc ', '') for s in [
        'func gestureRecognizerShouldBegin(', 'private func moveFront(to', '@objc private func panned(',
        'private func accessibilityMoveFront('])
    harness = r'''
import Foundation
final class ReplayQueue {
    static var inCapture = false
    var pending: [() -> Void] = []
    func async(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() {
        precondition(!Self.inCapture)
        Self.inCapture = true
        while !pending.isEmpty { pending.removeFirst()() }
        Self.inCapture = false
    }
}
enum AVCaptureVideoOrientation { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight }
typealias UIInterfaceOrientation = AVCaptureVideoOrientation
enum RecordingPhase { case idle, preparing, recording, finishing }
final class AVCaptureConnection {
    var isVideoOrientationSupported = true, isVideoMirroringSupported = true
    var videoOrientation: AVCaptureVideoOrientation = .portrait
    var automaticallyAdjustsVideoMirroring = true, isVideoMirrored = false
}
final class AVCaptureSession {
    var isRunning = true, attachedLayers = 0
    func stopRunning() { precondition(ReplayQueue.inCapture); isRunning = false }
}
enum Gravity { case resizeAspectFill }
final class AVCaptureVideoPreviewLayer {
    var videoGravity: Gravity = .resizeAspectFill
    var frame = CGRect.zero
    var connection: AVCaptureConnection?
    var session: AVCaptureSession? {
        didSet {
            precondition(ReplayQueue.inCapture, "Preview session mutated outside capture queue")
            oldValue?.attachedLayers -= 1
            session?.attachedLayers += 1
            connection = session == nil ? nil : AVCaptureConnection()
        }
    }
}
final class DualCameraCapture {
    let session = AVCaptureSession()
    var insetOrigin = DualPreviewLayout.defaultOrigin
    func attachPreview(_ back: AVCaptureVideoPreviewLayer, _ face: AVCaptureVideoPreviewLayer) {
        precondition(ReplayQueue.inCapture)
        back.session = session; face.session = session
    }
    func detach() {
        precondition(ReplayQueue.inCapture && session.attachedLayers == 0,
                     "Old MultiCam inputs removed while preview layers still bound")
    }
}
final class RecorderController {
    let captureQueue = ReplayQueue(), session = AVCaptureSession()
    weak var rearPreviewLayer: AVCaptureVideoPreviewLayer?, facePreviewLayer: AVCaptureVideoPreviewLayer?
    var dualRecorder: DualCameraCapture?
    var activeSession: AVCaptureSession { dualRecorder?.session ?? session }
    var configured = true, dualCaptureActive = false
    var isReady = true, isConfiguring = false
    var phase: RecordingPhase = .idle
    var frontInsetOrigin = DualPreviewLayout.defaultOrigin, frontPreviewOrigin = DualPreviewLayout.defaultOrigin
    var captureSettings = Settings(), settings = Settings()
    struct Settings { var frontCamera = false }
    var orientation: AVCaptureVideoOrientation = .portrait
    var zoom: CGFloat = 1
    var dualPreview: DualCameraCapture? { dualRecorder }
    func attachDualPreview(_ back: AVCaptureVideoPreviewLayer, _ face: AVCaptureVideoPreviewLayer) { attachPreview(back, face) }
    func focus(at point: CGPoint) {}
    func setZoom(_ factor: CGFloat) {}
    func updateOrientation(_ value: UIInterfaceOrientation) { captureQueue.async { self.orientation = value; self.updatePreviewConnectionsOnQueue() } }
    METHODS
}
enum GestureState { case possible, began, changed, ended, cancelled }
class UIGestureRecognizer {
    var point = CGPoint.zero
    func location(in view: CapturePreviewView) -> CGPoint { point }
}
final class UIPanGestureRecognizer: UIGestureRecognizer {
    var state: GestureState = .possible
    var delta = CGPoint.zero
    func translation(in view: CapturePreviewView) -> CGPoint { delta }
}
final class CapturePreviewView {
    let previewLayer = AVCaptureVideoPreviewLayer(), frontPreviewLayer = AVCaptureVideoPreviewLayer()
    var frontOrigin = DualPreviewLayout.defaultOrigin, panStart = DualPreviewLayout.defaultOrigin
    let frontPan = UIPanGestureRecognizer()
    var bounds = CGRect(x: 0, y: 0, width: 430, height: 800)
    var onFocus: ((CGPoint) -> Void)?, onFrontMoved: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat) -> Void)?, onDoubleTap: (() -> Void)?, currentZoom: (() -> CGFloat)?
    var onOrientation: ((UIInterfaceOrientation) -> Void)?, onWindowChange: (() -> Void)?
    var dualCapture = false, frontCamera = false, gesturesEnabled = false
    func setNeedsLayout() { frontPreviewLayer.frame = DualPreviewLayout.rect(in: bounds, origin: frontOrigin) }
    func reportOrientation() { onOrientation?(.portrait) }
    func updateConnection() { reportOrientation() }
    GESTURES
    func drag(from point: CGPoint, by delta: CGPoint) {
        frontPan.point = point
        guard gestureRecognizerShouldBegin(frontPan) else { return }
        frontPan.state = .began; panned(frontPan)
        frontPan.delta = delta; frontPan.state = .changed; panned(frontPan)
        frontPan.state = .ended; panned(frontPan)
    }
}
struct CameraPreview {
    typealias Context = Int
    let recorder: RecorderController
    let onBlackScreen: () -> Void
    BRIDGE
}
let recorder = RecorderController()
let bridge = CameraPreview(recorder: recorder, onBlackScreen: {})
let view = bridge.makeUIView(context: 0)
bridge.updateUIView(view, context: 0)
recorder.captureQueue.drain()
assert(view.previewLayer.session === recorder.session && view.frontPreviewLayer.session == nil)
for _ in 0..<100 {
    let old = DualCameraCapture()
    recorder.captureQueue.async { recorder.dualRecorder = old }
    bridge.updateUIView(view, context: 0) // deliberately arrives before the UI published flag
    recorder.captureQueue.drain()
    assert(view.previewLayer.session === old.session && view.frontPreviewLayer.session === old.session)
    recorder.captureQueue.async { recorder.leaveDualOnQueue() }
    recorder.dualCaptureActive = true // simulate a delayed main-queue publication
    bridge.updateUIView(view, context: 0)
    recorder.captureQueue.drain()
    assert(old.session.attachedLayers == 0 && recorder.session.attachedLayers == 1)
    assert(view.previewLayer.session === recorder.session && view.frontPreviewLayer.session == nil)
}
let replacement = bridge.makeUIView(context: 0)
if BRIDGE_HAS_COORDINATOR { CameraPreview.dismantleUIView(view, coordinator: recorder) }
recorder.captureQueue.drain()
assert(replacement.previewLayer.session === recorder.session && view.previewLayer.session == nil)
recorder.dualCaptureActive = true
bridge.updateUIView(replacement, context: 0)
replacement.setNeedsLayout()
let before = replacement.frontOrigin
replacement.drag(from: CGPoint(x: 5, y: 5), by: CGPoint(x: 150, y: 200))
assert(replacement.frontOrigin == before) // dragging the rear view keeps tap focus available
let rect = replacement.frontPreviewLayer.frame
replacement.drag(from: CGPoint(x: rect.midX, y: rect.midY), by: CGPoint(x: 100, y: 160))
recorder.captureQueue.drain()
assert(abs(replacement.frontOrigin.x - (before.x + 100/430.0)) < 0.001)
assert(abs(replacement.frontOrigin.y - (before.y + 0.2)) < 0.001)
assert(recorder.frontInsetOrigin == replacement.frontOrigin)
replacement.setNeedsLayout()
replacement.drag(from: CGPoint(x: replacement.frontPreviewLayer.frame.midX, y: replacement.frontPreviewLayer.frame.midY), by: CGPoint(x: 5000, y: -5000))
recorder.captureQueue.drain()
let edge = DualPreviewLayout.clamped(CGPoint(x: 5000, y: -5000))
assert(replacement.frontOrigin == edge)
for bounds in [CGRect(x: 0, y: 0, width: 430, height: 800), CGRect(x: 0, y: 0, width: 800, height: 430)] {
    let r = DualPreviewLayout.rect(in: bounds, origin: edge)
    assert(bounds.contains(r) && r.width > 0 && r.height > 0)
}
assert(DualPreviewLayout.clamped(CGPoint(x: CGFloat.nan, y: CGFloat.infinity)) == DualPreviewLayout.defaultOrigin)
print("PASS: production preview bridge/bindings stay on one queue through 100 delayed dual/single switches and stale view teardown")
print("PASS: production drag methods move only the front inset, clamp to view edges, retain the output position and support portrait/landscape")
print("Queue/view fakes do not reproduce an actual iPhone camera crash or touch input.")
'''
    # The previous bridge fails on its first main-thread session write; keep its old coordinator signature compilable.
    harness = harness.replace('if BRIDGE_HAS_COORDINATOR { CameraPreview.dismantleUIView(view, coordinator: recorder) }',
                              'CameraPreview.dismantleUIView(view, coordinator: ' + ('recorder' if 'coordinator: RecorderController' in bridge else '()') + ')')
    harness = harness.replace('METHODS', methods).replace('GESTURES', gestures).replace('BRIDGE', bridge)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(geometry + '\n' + harness, encoding='utf-8')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, default=ROOT / 'build/preview-lifecycle-check.swift')
    p.add_argument('--preview-source', type=Path, default=ROOT / 'Recorder.swiftpm/Sources/CameraPreview.swift')
    p.add_argument('--generate-only', action='store_true')
    args = p.parse_args()
    build(args.output, args.preview_source)
    if not args.generate_only:
        subprocess.run(['swift', str(args.output)], check=True)
