"""Replay production lifecycle methods with controllable capture/UI queue order.

This exercises the reported return-to-camera state race. Session/queues are
fakes; it does not claim iPad background behavior or camera hardware testing.
"""
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def extract(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def build(controller: Path, output: Path):
    source = controller.read_text(encoding='utf-8')
    settings = (ROOT / 'Recorder.swiftpm/Sources/RecorderSettings.swift').read_text(encoding='utf-8')
    view = (ROOT / 'Recorder.swiftpm/Sources/ContentView.swift').read_text(encoding='utf-8')
    phase = extract(settings, 'enum RecordingPhase:')
    pip = extract(settings, 'enum CameraPiPState:')
    methods = [extract(source, s) for s in (
        'func sceneChanged(', 'private func finishCaptureStateOnQueue()',
        'private func setPhase(', 'private func stopOnQueue(',
        'private func handleRuntimeErrorOnQueue(', 'private func completeCaptureOnQueue(',
        'private func requestResumeOnQueue(', 'private func updateCaptureLoadOnQueue(')]
    if 'private func resumeSessionOnQueue()' in source:
        methods.append(extract(source, 'private func resumeSessionOnQueue()'))
    else:
        # Existing interruption-ended observer uses this same published-state guard.
        assert 'if self.phase == .idle { self.start() }' in source
    if 'func setPictureInPictureState(' in source:
        methods += [extract(source, 'func setPictureInPictureState('),
                    extract(source, 'private var canContinueInPictureInPicture:'),
                    extract(source, 'private func tick()')]
    else:
        methods.append('func setPictureInPictureState(_ value: CameraPiPState) {}')
        methods.append('private func tick() {}')
    harness = r'''
import Foundation
enum ScenePhase { case active, inactive, background }
final class ReplayQueue {
    var pending: [() -> Void] = []
    func async(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}
final class ReplaySession {
    var isRunning = true
    var isInterrupted = false
    var isMultitaskingCameraAccessSupported = false
    var isMultitaskingCameraAccessEnabled = false
    var starts = 0
    func startRunning() { starts += 1; isRunning = !isInterrupted }
    func stopRunning() { isRunning = false }
}
struct FakeSettings {
    var captureMode = "video", mode = "4K · 60 fps · HDR"
    var reserveBytes: Int64 = 512
    var resumeAfterBackground = false, automaticallyExportToPhotos = false, thermalProtection = true, includeLocation = true
}
struct MediaItem { var id = UUID(); var kind = "video" }
enum MediaLibrary {
    static var fails = false
    static func finish(_ item: MediaItem) throws {
        if fails { throw NSError(domain: "Save", code: 1) }
    }
}
struct FakeInput { var device = "后置主摄" }
let AVFoundationErrorDomain = "AVFoundationErrorDomain"
enum AVError { enum Code: Int { case mediaServicesWereReset = -11819 } }
func CMTimeGetSeconds(_ value: Double) -> Double { value }
enum RecorderFiles {
    static var freeBytes: Int64? = 1024
    static func availableBytes() -> Int64? { freeBytes }
}
extension String { static let video = "video"; var title: String { self } }
final class ReplayMovie {
    var isRecording = true
    var recordedDuration: Double = 1
    func stopRecording() { isRecording = false }
}
final class Recorder: @unchecked Sendable {
    let captureQueue = ReplayQueue(), uiQueue = ReplayQueue()
    let session = ReplaySession(), movieOutput = ReplayMovie()
    var phase: RecordingPhase = .idle, capturePhase: RecordingPhase = .idle
    var configured = true, foreground = true, mainForeground = true
    var runtimeRecoveryAttempted = false
    var isReady = true, isConfiguring = false, startTaskRunning = false
    var stopRequested = false, permissionGeneration = 0
    var pictureInPictureState: CameraPiPState = .inactive
    var pictureInPictureDeadline: TimeInterval = 0
    var onStopPictureInPicture: (() -> Void)?
    var finishingTask = false
    var tickCount = 0, elapsed: Double = 0
    var availableSpace: Int64?
    var captureSettings = FakeSettings(), status = "ready"
    var activeItem: MediaItem? = MediaItem()
    var resumeAfterBackgroundPending = false, resumeSourceID: UUID?
    var loadOnQueue: CaptureLoad = .normal, captureLoad: CaptureLoad = .normal
    var resumeRequests: [UUID] = []
    var resumeRequest: UUID? { didSet { if let value = resumeRequest { resumeRequests.append(value) } } }
    var startConfigurations = 0
    var videoInput: FakeInput?
    var lastCameraError: String?
    var reports: [String] = []
    var settings: FakeSettings { captureSettings }
    var message: String?
    var resumedStarts: [UUID] = []
    var canRecord: Bool { mainForeground && isReady && phase == .idle }
    func startRecording(location: String?, resumedFrom: UUID) { resumedStarts.append(resumedFrom); phase = .preparing }
    static func lensLabel(_ value: String) -> String { value }
    func publish(_ action: @escaping @Sendable () -> Void) { uiQueue.async(action) }
    func start() {
        guard mainForeground, !isConfiguring, phase == .idle else { return }
        startConfigurations += 1
        captureQueue.async {
            guard self.foreground, self.capturePhase == .idle else { return }
            self.configured = true
            self.session.startRunning()
            let ready = !self.session.isInterrupted && self.session.isRunning
            self.publish { self.isReady = ready }
        }
    }
    func beginFinishingTask() { finishingTask = true }
    func endFinishingTask() { finishingTask = false }
    func turnTorchOff() {}
    func publishCapabilities() {}
    enum CaptureFeedback { case began, stopped, saved }
    func captureFeedback(_ value: CaptureFeedback) {}
    func createThumbnail(_ item: MediaItem) {}
    func exportToPhotos(_ items: [MediaItem], automatic: Bool) {}
    func refreshLibraryOnQueue() {}
    func readCaptureLoadOnQueue() {}
    func report(_ title: String, _ detail: String) { reports.append(title + "\n" + detail) }
    func fireTimer() { tick() }
    func completedFile() { finishCaptureStateOnQueue() }
    func savedFile() { completeCaptureOnQueue(activeItem!) }
    func manualStop() { stopOnQueue(reason: "manual") }
    func setLoad(_ value: CaptureLoad) { updateCaptureLoadOnQueue(value) }
    func interruptionEnded() { resumeSessionOnQueue() }
    func runtimeError(_ error: NSError?, reportedInForeground: Bool = true) {
        handleRuntimeErrorOnQueue(error, reportedInForeground: reportedInForeground)
    }
    func pump() {
        while !captureQueue.pending.isEmpty || !uiQueue.pending.isEmpty {
            captureQueue.drain(); uiQueue.drain()
        }
    }
    METHODS
}
// A file callback completes on captureQueue before its UI publications run.
// UIKit foreground delivery can already be in flight on the main run loop.
let raced = Recorder()
raced.phase = .recording; raced.capturePhase = .recording
raced.sceneChanged(.background); raced.pump()
raced.session.isRunning = false
raced.captureQueue.async { raced.completedFile() }
raced.captureQueue.drain() // Keep UI phase stale (.finishing).
assert(raced.capturePhase == .idle && raced.phase == .finishing)
raced.sceneChanged(.active); raced.captureQueue.drain(); raced.uiQueue.drain()
guard raced.isReady && raced.session.isRunning && raced.capturePhase == .idle else {
    print("FAIL: returning before UI state catches up leaves the record button unavailable")
    exit(1)
}
// Also cover normal return after saving, and return while saving is still active.
let later = Recorder()
later.phase = .recording; later.capturePhase = .recording
later.sceneChanged(.background); later.pump(); later.completedFile(); later.uiQueue.drain()
assert(!later.isReady && !later.session.isRunning)
later.sceneChanged(.active); later.pump()
assert(later.isReady && later.session.isRunning)
let early = Recorder()
early.phase = .recording; early.capturePhase = .recording
early.sceneChanged(.background); early.pump()
early.session.isRunning = false
early.sceneChanged(.active); early.pump()
assert(!early.isReady && !early.session.isRunning)
early.completedFile(); early.uiQueue.drain()
assert(early.isReady && early.session.isRunning)
// Never enable capture while backgrounded; interruption must not report ready.
early.sceneChanged(.background); early.pump()
early.completedFile(); early.uiQueue.drain()
assert(!early.isReady && !early.session.isRunning)
early.session.isInterrupted = true
early.sceneChanged(.active); early.pump()
assert(!early.isReady)
print("PASS: production lifecycle replay covers stale UI state, both completion orders, and background/interruption guards")
let returning = Recorder()
returning.sceneChanged(.background); returning.pump()
returning.sceneChanged(.active); returning.sceneChanged(.active); returning.pump()
assert(returning.startConfigurations == 0, "Returning with configured inputs must resume once, without reconfiguring")
assert(returning.session.starts == 1, "Duplicate UIKit/SwiftUI activation must not start the camera twice")
print("PASS: duplicate foreground notifications reuse configured capture inputs")
let initial = Recorder()
initial.configured = false; initial.foreground = false; initial.mainForeground = false
initial.session.isRunning = false
initial.sceneChanged(.active); initial.sceneChanged(.active); initial.pump()
assert(initial.startConfigurations == 1 && initial.session.starts == 1 && initial.isReady)
let blocked = Recorder()
blocked.sceneChanged(.background); blocked.pump()
blocked.session.isInterrupted = true
blocked.sceneChanged(.active); blocked.pump()
assert(blocked.session.starts == 0 && !blocked.isReady)
blocked.session.isInterrupted = false
blocked.captureQueue.async { blocked.interruptionEnded() }; blocked.pump()
assert(blocked.session.starts == 1 && blocked.isReady)
print("PASS: cold start configured once, interrupted foreground return waits before restarting")
func recordingRecorder(supported: Bool = true, enabled: Bool = true) -> Recorder {
    let value = Recorder()
    value.phase = .recording; value.capturePhase = .recording
    value.session.isMultitaskingCameraAccessSupported = supported
    value.session.isMultitaskingCameraAccessEnabled = enabled
    return value
}
// Eligibility alone never grants continuity: an explicit native PiP request is required.
let noRequest = recordingRecorder()
noRequest.sceneChanged(.background); noRequest.pump()
assert(noRequest.capturePhase == .finishing && !noRequest.session.isRunning)
let allowed = recordingRecorder()
allowed.setPictureInPictureState(.active); allowed.pump()
allowed.sceneChanged(.background); allowed.pump()
guard allowed.capturePhase == .recording && allowed.session.isRunning else {
    print("FAIL: eligible, explicitly active PiP is stopped on background entry")
    exit(2)
}
assert(!allowed.isReady && !allowed.finishingTask)
// Closing the background window stops once and keeps the finite save task.
allowed.setPictureInPictureState(.inactive); allowed.pump()
assert(allowed.capturePhase == .finishing && !allowed.session.isRunning && allowed.finishingTask)
allowed.completedFile(); allowed.uiQueue.drain()
assert(allowed.capturePhase == .idle && !allowed.session.isRunning && !allowed.finishingTask)
// A late successful delegate callback cannot resurrect finished capture.
allowed.setPictureInPictureState(.active); allowed.pump()
assert(allowed.pictureInPictureState == .inactive && allowed.capturePhase == .idle && !allowed.session.isRunning)
let returned = recordingRecorder()
returned.setPictureInPictureState(.active); returned.pump()
returned.sceneChanged(.background); returned.pump()
returned.sceneChanged(.active); returned.pump()
assert(returned.isReady && returned.capturePhase == .recording)
returned.setPictureInPictureState(.inactive); returned.pump()
assert(returned.capturePhase == .recording && returned.session.isRunning)
// Support, enablement and session interruption are independent requirements.
for value in [recordingRecorder(supported: false), recordingRecorder(enabled: false)] {
    value.setPictureInPictureState(.active); value.pump()
    value.sceneChanged(.background); value.pump()
    assert(value.capturePhase == .finishing && !value.session.isRunning)
}
let interrupted = recordingRecorder()
interrupted.setPictureInPictureState(.active); interrupted.pump()
interrupted.session.isInterrupted = true
interrupted.sceneChanged(.background); interrupted.pump()
assert(interrupted.capturePhase == .finishing && !interrupted.session.isRunning)
// Only a bounded start transition can bridge foreground loss. Confirmation ends
// the finite background task, so it cannot stop valid PiP at the task timeout.
let transition = recordingRecorder()
transition.setPictureInPictureState(.starting); transition.pump()
transition.sceneChanged(.background); transition.pump()
assert(transition.capturePhase == .recording && transition.finishingTask)
transition.setPictureInPictureState(.active); transition.pump()
assert(transition.capturePhase == .recording && !transition.finishingTask)
let expired = recordingRecorder()
expired.setPictureInPictureState(.starting); expired.pump()
expired.sceneChanged(.background); expired.pump()
assert(expired.capturePhase == .recording)
expired.pictureInPictureDeadline = ProcessInfo.processInfo.systemUptime - 1
expired.fireTimer(); expired.pump()
assert(expired.capturePhase == .finishing && !expired.session.isRunning)
let lowSpace = recordingRecorder()
lowSpace.setPictureInPictureState(.active); lowSpace.pump()
lowSpace.sceneChanged(.background); lowSpace.pump()
RecorderFiles.freeBytes = 512
lowSpace.fireTimer(); lowSpace.pump()
assert(lowSpace.capturePhase == .finishing && !lowSpace.movieOutput.isRecording && lowSpace.finishingTask)
lowSpace.completedFile(); lowSpace.uiQueue.drain()
assert(lowSpace.capturePhase == .idle && !lowSpace.session.isRunning && !lowSpace.finishingTask)
RecorderFiles.freeBytes = 1024
print("PASS: PiP continuity, close/save, foreground return, capability denial, interruption, late callback, bounded transition and low-space save")
let underlying = NSError(domain: "CameraDevice", code: -16800,
    userInfo: [NSLocalizedFailureReasonErrorKey: "Format unavailable"])
let cameraError = NSError(domain: AVFoundationErrorDomain, code: -11800,
    userInfo: [NSLocalizedDescriptionKey: "Camera failed", NSUnderlyingErrorKey: underlying])
let diagnostic = CameraErrorDetail.describe(cameraError)
assert(diagnostic.contains("-11800") && diagnostic.contains("CameraDevice (-16800)") && diagnostic.contains("Format unavailable"))
assert(CameraErrorDetail.describe(nil) == "系统未提供错误代码。")
let reset = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.mediaServicesWereReset.rawValue)
let recovery = Recorder()
recovery.session.isRunning = false
recovery.runtimeError(reset); recovery.pump()
assert(recovery.runtimeRecoveryAttempted && recovery.session.starts == 1 && recovery.isReady && recovery.reports.isEmpty)
recovery.session.isRunning = false
recovery.runtimeError(reset); recovery.pump()
assert(recovery.session.starts == 1 && !recovery.isReady && recovery.reports.count == 1)
let lateError = recordingRecorder()
lateError.runtimeError(cameraError, reportedInForeground: false); lateError.pump()
assert(lateError.capturePhase == .recording && lateError.movieOutput.isRecording && lateError.isReady && lateError.reports.isEmpty)
let backgroundError = Recorder()
backgroundError.sceneChanged(.background); backgroundError.pump()
backgroundError.runtimeError(cameraError, reportedInForeground: false); backgroundError.pump()
assert(!backgroundError.isReady && backgroundError.reports.isEmpty && backgroundError.lastCameraError!.contains("-16800"))
let activeError = recordingRecorder()
activeError.runtimeError(cameraError); activeError.pump()
assert(activeError.capturePhase == .finishing && !activeError.movieOutput.isRecording && !activeError.isReady)
assert(activeError.reports.count == 1 && activeError.lastCameraError!.contains("-11800"))
print("PASS: bounded reset recovery, delayed/background errors, active recording finish and native NSError diagnostics")
// Resume is opt-in, saves a separate segment, and consumes one pending intent.
let defaultOff = recordingRecorder()
defaultOff.sceneChanged(.background); defaultOff.pump()
defaultOff.sceneChanged(.active); defaultOff.pump()
defaultOff.savedFile(); defaultOff.pump()
assert(defaultOff.resumeRequests.isEmpty)
for returnBeforeSave in [true, false] {
    let resume = recordingRecorder()
    resume.captureSettings.resumeAfterBackground = true
    let original = resume.activeItem!.id
    resume.sceneChanged(.background); resume.pump()
    assert(resume.capturePhase == .finishing && resume.resumeRequests.isEmpty)
    if returnBeforeSave {
        resume.sceneChanged(.active); resume.pump()
        assert(resume.resumeRequests.isEmpty && !resume.isReady)
        resume.savedFile(); resume.pump()
    } else {
        resume.savedFile(); resume.pump()
        assert(resume.resumeRequests.isEmpty && !resume.isReady)
        resume.sceneChanged(.active); resume.pump()
    }
    resume.sceneChanged(.active); resume.completedFile(); resume.pump()
    assert(resume.resumeRequests == [original] && resume.isReady)
}
let failedSave = recordingRecorder()
failedSave.captureSettings.resumeAfterBackground = true
failedSave.sceneChanged(.background); failedSave.pump()
failedSave.sceneChanged(.active); failedSave.pump()
MediaLibrary.fails = true; failedSave.savedFile(); failedSave.pump(); MediaLibrary.fails = false
assert(failedSave.resumeRequests.isEmpty && !failedSave.reports.isEmpty)
for inactiveMode in ["photo", "livePhoto"] {
    let photo = recordingRecorder()
    photo.captureSettings.captureMode = inactiveMode
    photo.captureSettings.resumeAfterBackground = true
    photo.sceneChanged(.background); photo.pump(); photo.savedFile(); photo.pump()
    photo.sceneChanged(.active); photo.pump()
    assert(photo.resumeRequests.isEmpty)
}
let continuedPiP = recordingRecorder()
continuedPiP.captureSettings.resumeAfterBackground = true
continuedPiP.setPictureInPictureState(.active); continuedPiP.pump()
continuedPiP.sceneChanged(.background); continuedPiP.pump()
continuedPiP.sceneChanged(.active); continuedPiP.pump()
assert(continuedPiP.capturePhase == .recording && continuedPiP.resumeRequests.isEmpty)
let interruptedResume = recordingRecorder()
interruptedResume.captureSettings.resumeAfterBackground = true
interruptedResume.sceneChanged(.background); interruptedResume.pump()
interruptedResume.session.isInterrupted = true
interruptedResume.savedFile(); interruptedResume.pump()
interruptedResume.sceneChanged(.active); interruptedResume.pump()
assert(interruptedResume.resumeRequests.isEmpty)
interruptedResume.session.isInterrupted = false
interruptedResume.interruptionEnded(); interruptedResume.pump()
assert(interruptedResume.resumeRequests.count == 1)
let overheating = recordingRecorder()
overheating.captureSettings.resumeAfterBackground = true
overheating.setLoad(.elevated); overheating.pump()
assert(overheating.capturePhase == .recording && overheating.captureSettings.mode == "4K · 60 fps · HDR")
overheating.setLoad(.critical); overheating.pump()
assert(overheating.capturePhase == .finishing && !overheating.movieOutput.isRecording)
overheating.savedFile(); overheating.pump()
assert(!overheating.isReady && !overheating.session.isRunning && overheating.resumeRequests.isEmpty)
overheating.setLoad(.normal); overheating.pump()
assert(overheating.isReady && overheating.resumeRequests.isEmpty)
let unprotected = recordingRecorder()
unprotected.captureSettings.thermalProtection = false
unprotected.setLoad(.critical); unprotected.pump()
assert(unprotected.capturePhase == .recording && unprotected.movieOutput.isRecording)
print("PASS: default-off resume, both save/return orders, one request, failed saves, photo/PiP exclusions, interruption and thermal protection")
struct ReplayLocation { func snapshot() -> String? { "current location" } }
final class ReplayView {
    let recorder = Recorder(), location = ReplayLocation()
    var scenePhase = ScenePhase.background
    var showSettings = false, showLibrary = false, blackBeforeLeaving = true, restoreBlackAfterResume = false
    var pendingResumeID: UUID?, isBlack = false
    var leavingSnapshotTaken = false
    func setBlackScreen(_ value: Bool) { isBlack = value }
    func reconcile() { restoreOrResumeCapture() }
    func leave() { rememberBlackBeforeLeaving(); setBlackScreen(false) }
    VIEW_METHOD
    SNAPSHOT_METHOD
}
let uiResume = ReplayView()
uiResume.recorder.captureSettings.resumeAfterBackground = true
let segmentID = UUID()
uiResume.pendingResumeID = segmentID
uiResume.reconcile()
assert(uiResume.recorder.resumedStarts.isEmpty && uiResume.pendingResumeID == segmentID)
uiResume.scenePhase = .active; uiResume.recorder.isReady = false; uiResume.reconcile()
assert(uiResume.recorder.resumedStarts.isEmpty && uiResume.pendingResumeID == segmentID)
uiResume.recorder.isReady = true; uiResume.reconcile(); uiResume.reconcile()
assert(uiResume.recorder.resumedStarts == [segmentID] && uiResume.restoreBlackAfterResume && uiResume.pendingResumeID == nil)
let uiPiP = ReplayView()
uiPiP.recorder.captureSettings.resumeAfterBackground = true
uiPiP.recorder.phase = .recording; uiPiP.scenePhase = .active
uiPiP.reconcile()
assert(uiPiP.isBlack && uiPiP.recorder.resumedStarts.isEmpty)
uiPiP.leave(); uiPiP.leave()
assert(uiPiP.blackBeforeLeaving && !uiPiP.isBlack, "Duplicate UIKit/SwiftUI deactivation must preserve the original black state")
for blocker in ["settings", "library", "error", "disabled"] {
    let blockedView = ReplayView()
    blockedView.scenePhase = .active; blockedView.pendingResumeID = UUID()
    blockedView.recorder.captureSettings.resumeAfterBackground = blocker != "disabled"
    blockedView.showSettings = blocker == "settings"; blockedView.showLibrary = blocker == "library"
    blockedView.recorder.message = blocker == "error" ? "error" : nil
    blockedView.reconcile()
    assert(blockedView.recorder.resumedStarts.isEmpty)
}
print("PASS: production UI reconciliation waits for active/ready, consumes once, carries black-screen intent and respects sheets/errors/default off")
print("Replay uses fake session and queues; AVKit, Apple SDK and physical device behavior are not tested.")
'''.replace('METHODS', '\n'.join(methods)).replace('VIEW_METHOD', extract(view, 'private func restoreOrResumeCapture()')).replace('SNAPSHOT_METHOD', extract(view, 'private func rememberBlackBeforeLeaving()'))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(phase + '\n' + pip + '\n' + extract(settings, 'enum CaptureLoad:') + '\n' + extract(settings, 'enum CameraErrorDetail {') + '\n' + harness, encoding='utf-8')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--controller', type=Path, default=ROOT / 'Recorder.swiftpm/Sources/RecorderController.swift')
    p.add_argument('--output', type=Path, default=ROOT / 'build/lifecycle-check.swift')
    p.add_argument('--generate-only', action='store_true')
    args = p.parse_args()
    build(args.controller, args.output)
    print('Prepared lifecycle replay from:', args.controller)
    if not args.generate_only:
        subprocess.run(['swift', str(args.output)], check=True)
