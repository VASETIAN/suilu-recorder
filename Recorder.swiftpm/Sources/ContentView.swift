import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @ObservedObject var recorder: RecorderController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var isBlack = false
    @State private var showLibrary = false
    @State private var blackBeforeLeaving = false
    @State private var leavingSnapshotTaken = false
    @State private var restoreBlackAfterResume = false
    @State private var pendingResumeID: UUID?
    @StateObject private var location = LocationService()
    @StateObject private var brightness = ScreenBrightness()
    @StateObject private var pictureInPicture = RecorderPictureInPicture()

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(recorder: recorder, pictureInPicture: pictureInPicture,
                              onBlackScreen: { setBlackScreen(true) })
                    .ignoresSafeArea().accessibilityHidden(isBlack)
                LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
                VStack(spacing: landscape ? 8 : 14) {
                    header
                    if let warning = recorder.captureLoad.warning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                            .padding(8).background(.black.opacity(0.55), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    if !recorder.isReady && recorder.phase == .idle { unavailableView }
                    Spacer(minLength: 8)
                    footer(landscape: landscape)
                }
                .padding(.horizontal, landscape ? 26 : 20)
                .padding(.vertical, landscape ? 10 : 18)
                .frame(maxWidth: 1000)
                .accessibilityHidden(isBlack)

                if isBlack { blackScreen }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .statusBarHidden(isBlack)
        .persistentSystemOverlays(isBlack ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView(recorder: recorder, location: location, pictureInPicture: pictureInPicture)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(recorder: recorder)
        }
        .alert(item: Binding(get: { showSettings || showLibrary ? nil : recorder.message },
                             set: { recorder.message = $0 })) { value in
            Alert(title: Text(value.title), message: Text(value.detail), dismissButton: .default(Text("知道了")))
        }
        .onAppear {
            recorder.sceneChanged(scenePhase)
            location.setEnabled(recorder.settings.includeLocation, foreground: scenePhase == .active)
            updateIdleTimer()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; setBlackScreen(false) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            rememberBlackBeforeLeaving()
            setBlackScreen(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: RecorderLaunchRequest.notification)) { _ in
            showSettings = false
            showLibrary = false
            setBlackScreen(false)
        }
        .onChange(of: scenePhase) { value in
            if value == .background { pendingResumeID = nil }
            if value == .active { leavingSnapshotTaken = false }
            if value != .active { rememberBlackBeforeLeaving(); setBlackScreen(false) }
            location.setEnabled(recorder.settings.includeLocation, foreground: value == .active)
            recorder.sceneChanged(value)
            updateIdleTimer()
            restoreOrResumeCapture()
        }
        .onChange(of: recorder.phase) { value in
            if value == .recording && (recorder.settings.autoBlackScreen || restoreBlackAfterResume) && scenePhase == .active {
                setBlackScreen(true)
                restoreBlackAfterResume = false
            }
            if recorder.settings.captureMode == .video && value != .recording { setBlackScreen(false) }
            updateIdleTimer()
            restoreOrResumeCapture()
        }
        // A failure / low-space notice must be visible even if the content is black.
        .onChange(of: recorder.message?.id) { value in
            if value != nil {
                setBlackScreen(false)
                pendingResumeID = nil
                restoreBlackAfterResume = false
                blackBeforeLeaving = false
            }
        }
        .onChange(of: recorder.settings.includeLocation) { value in
            location.setEnabled(value, foreground: scenePhase == .active)
        }
        .onChange(of: recorder.settings.dimBlackScreen) { _ in setBlackScreen(isBlack) }
        .onChange(of: recorder.settings.captureMode) { _ in setBlackScreen(false); pendingResumeID = nil }
        .onChange(of: recorder.isReady) { ready in
            if !ready { setBlackScreen(false) }
            restoreOrResumeCapture()
        }
        .onChange(of: recorder.resumeRequest) { value in pendingResumeID = value; restoreOrResumeCapture() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if recorder.phase == .recording {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(recorder.elapsedLabel).monospacedDigit().font(.headline)
                    } else {
                        Text("随心记").font(.headline)
                    }
                }
                Text(recorder.settings.captureMode == .video ? recorder.settings.mode.title : recorder.settings.captureMode.title)
                    .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Text(recorder.activeLensLabel).font(.caption2).foregroundStyle(.white.opacity(0.65))
                Text("剩余 \(RecorderFiles.sizeLabel(recorder.availableSpace))")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                if recorder.settings.includeLocation {
                    Label(location.status, systemImage: "location.fill").font(.caption2).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if recorder.settings.captureMode == .video { pictureInPictureButton }
            else { livePhotoButton }
            Button(action: recorder.toggleTorch) {
                Image(systemName: recorder.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.title3)
                    .foregroundStyle(recorder.torchOn ? .yellow : .white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .disabled(!recorder.hasTorch || !recorder.isReady)
            .opacity(recorder.hasTorch ? 1 : 0.35)
            .accessibilityLabel(recorder.torchOn ? "关闭补光灯" : "开启补光灯")
            Button { pendingResumeID = nil; showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .disabled(recorder.phase.blocksConfiguration || recorder.isConfiguring)
            .accessibilityLabel("拍摄设置")
        }
        .foregroundStyle(.white)
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.largeTitle)
            Text(recorder.status).font(.headline).multilineTextAlignment(.center)
            if recorder.captureLoad == .critical && recorder.settings.thermalProtection {
                Text("设备恢复后相机会重新准备，录像需重新开始。")
                    .font(.caption).multilineTextAlignment(.center)
            } else if recorder.isConfiguring {
                ProgressView().tint(.white)
            } else {
                HStack {
                    Button("重试", action: recorder.start).buttonStyle(.borderedProminent)
                    Button("系统设置") { openSystemSettings() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(22)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
    }

    private var livePhotoButton: some View {
        let enabled = recorder.settings.captureMode == .livePhoto
        return Button(action: recorder.toggleLivePhoto) {
            VStack(spacing: 3) {
                Image(systemName: enabled ? "livephoto" : "livephoto.slash").font(.title3)
                Text("LIVE").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(enabled ? .yellow : .white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: Circle())
        }
        .disabled(!recorder.canConfigure || !recorder.isReady || !recorder.livePhotoSupported)
        .opacity(recorder.livePhotoSupported ? 1 : 0.35)
        .accessibilityLabel(recorder.livePhotoSupported ? (enabled ? "关闭动态照片" : "开启动态照片") : "当前镜头不支持动态照片")
        .accessibilityValue(enabled ? "已开启" : "已关闭")
    }

    private var pictureInPictureButton: some View {
        let enabled = pictureInPicture.isActive || pictureInPicture.isStarting
        return Button {
            if enabled { pictureInPicture.stop() }
            else { setBlackScreen(false); pictureInPicture.start() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: enabled ? "pip.exit" : "pip.enter").font(.title3)
                Text("画中画").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(enabled ? .yellow : .white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: Circle())
        }
        .disabled(!pictureInPicture.canStart && !enabled)
        .opacity(pictureInPicture.canStart || enabled ? 1 : 0.35)
        .accessibilityLabel(pictureInPicture.isActive ? "关闭画中画" : pictureInPicture.isStarting ? "取消开启画中画" : "开启画中画")
        .accessibilityHint(pictureInPicture.status)
    }

    private func footer(landscape: Bool) -> some View {
        VStack(spacing: landscape ? 8 : 16) {
            HStack(spacing: 10) {
                ForEach([CaptureMode.video, .photo]) { mode in
                    Button { recorder.setCaptureMode(mode) } label: {
                        Text(mode.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle((recorder.settings.captureMode == .video) == (mode == .video) ? .yellow : .white)
                            .padding(.horizontal, 14).frame(minHeight: 40)
                            .background(.black.opacity(0.5), in: Capsule())
                    }.disabled(!recorder.canConfigure)
                }
            }
            HStack(spacing: 10) {
                ForEach(recorder.zoomStops, id: \.self) { value in
                    Button { recorder.selectZoom(value) } label: {
                        Text(zoomLabel(value))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(abs(recorder.zoom - value) < 0.08 ? .yellow : .white)
                            .frame(minWidth: 46, minHeight: 44)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                    .disabled(!recorder.isReady || recorder.isConfiguring)
                    .accessibilityLabel("变焦 \(zoomLabel(value))")
                }
            }
            .frame(height: 44)
            .accessibilityValue("当前倍率 \(Double(recorder.zoom), specifier: "%.1f") 倍")
            HStack(spacing: 24) {
                cameraButton(symbol: "photo.on.rectangle.angled", title: "相册", enabled: recorder.canConfigure) {
                    pendingResumeID = nil
                    showLibrary = true
                }
                Spacer(minLength: 0)
                captureButton
                Spacer(minLength: 0)
                cameraButton(symbol: "arrow.triangle.2.circlepath.camera", title: "翻转",
                             enabled: recorder.canConfigure && recorder.isReady, action: recorder.switchCamera)
            }
            .frame(maxWidth: 400)
            Text(recorder.phase == .recording ? "\(recorder.settings.microphoneEnabled ? "有声" : "无声")录像 · \(recorder.settings.recovery.title)恢复黑屏"
                 : recorder.phase.blocksConfiguration ? recorder.phase.title : recorder.status)
                .font(.caption).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(height: 32)
        }
        .foregroundStyle(.white)
    }

    private var captureButton: some View {
        Button(action: capture) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                if recorder.phase == .recording {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 32, height: 32)
                } else if recorder.phase.blocksConfiguration {
                    ProgressView().tint(.white).scaleEffect(1.25)
                } else {
                    Circle().fill(recorder.settings.captureMode == .video ? .red : .white).frame(width: 62, height: 62)
                }
            }
        }
        .disabled(!(recorder.canRecord || recorder.phase == .recording))
        .opacity(recorder.isReady || recorder.phase.blocksConfiguration ? 1 : 0.45)
        .accessibilityLabel(recorder.phase == .recording ? "停止录像并保存到内置图库" : recorder.settings.captureMode == .video ? "开始录像" : "拍摄并保存到内置图库")
    }

    private func capture() {
        pendingResumeID = nil
        blackBeforeLeaving = false
        if recorder.phase == .recording { recorder.stopRecording() }
        else if recorder.canRecord {
            let position = recorder.settings.includeLocation ? location.snapshot() : nil
            if recorder.settings.captureMode == .video { recorder.startRecording(location: position) }
            else {
                recorder.takePhoto(location: position)
            }
        }
    }

    private func rememberBlackBeforeLeaving() {
        guard !leavingSnapshotTaken else { return }
        blackBeforeLeaving = isBlack
        leavingSnapshotTaken = true
    }

    private func restoreOrResumeCapture() {
        guard scenePhase == .active, recorder.settings.resumeAfterBackground,
              !showSettings, !showLibrary, recorder.message == nil else { return }
        if recorder.phase == .recording {
            pendingResumeID = nil
            if blackBeforeLeaving && recorder.isReady { setBlackScreen(true); blackBeforeLeaving = false }
            return
        }
        guard let previous = pendingResumeID, recorder.canRecord else { return }
        pendingResumeID = nil
        restoreBlackAfterResume = blackBeforeLeaving
        blackBeforeLeaving = false
        let position = recorder.settings.includeLocation ? location.snapshot() : nil
        recorder.startRecording(location: position, resumedFrom: previous)
    }

    private func cameraButton(symbol: String, title: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title2).frame(height: 28)
                Text(title).font(.caption)
            }.frame(width: 64, height: 64)
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var blackScreen: some View {
        let isPhoto = recorder.settings.captureMode != .video
        let surface = Color.black.ignoresSafeArea().contentShape(Rectangle())
            .accessibilityLabel(isPhoto ? "黑屏拍照" : "黑屏录像中")
            .accessibilityHint(isPhoto ? "单击拍照，长按恢复界面。" : "\(recorder.settings.recovery.title)恢复相机界面；录像仍在进行。")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setBlackScreen(false) }
        if isPhoto {
            surface.gesture(LongPressGesture(minimumDuration: 0.8).exclusively(before: TapGesture()).onEnded { value in
                switch value {
                case .first: setBlackScreen(false)
                case .second: capture()
                }
            })
            .accessibilityAction(named: Text("拍照"), capture)
        } else {
            switch recorder.settings.recovery {
            case .singleTap: surface.onTapGesture { setBlackScreen(false) }
            case .doubleTap: surface.onTapGesture(count: 2) { setBlackScreen(false) }
            case .longPress: surface.onLongPressGesture(minimumDuration: 0.8) { setBlackScreen(false) }
            }
        }
    }

    private func setBlackScreen(_ requested: Bool) {
        let allowed = recorder.settings.captureMode == .video ? recorder.phase == .recording
            : recorder.isReady && !recorder.isConfiguring
        let enabled = requested && scenePhase == .active && allowed
        // Set physical brightness in the action itself, before showing the black
        // surface. Every entry/exit path uses this function, including auto entry.
        if enabled && recorder.settings.dimBlackScreen { brightness.dim() }
        else { brightness.restore() }
        isBlack = enabled
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && (recorder.phase.blocksConfiguration || isBlack)
    }
    private func zoomLabel(_ value: CGFloat) -> String { String(format: "%g×", Double(value)) }
    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
