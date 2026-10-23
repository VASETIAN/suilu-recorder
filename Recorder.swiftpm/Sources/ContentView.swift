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
    @StateObject private var browser = RecorderBrowser()

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let cameraLayout = landscape ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
                : AnyLayout(VStackLayout(spacing: 14))
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(recorder: recorder,
                              onBlackScreen: { setBlackScreen(true) })
                    .id(recorder.previewGeneration)
                    .ignoresSafeArea().accessibilityHidden(isBlack || recorder.settings.interfaceMode == .browser)
                if recorder.settings.interfaceMode == .camera {
                LinearGradient(colors: [.black.opacity(0.4), .clear, .clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
                cameraLayout {
                    VStack(spacing: 10) {
                    header
                    if recorder.settings.captureMode == .video {
                        VideoFormatControls(mode: recorder.settings.mode, modes: recorder.supportedModes,
                                            canChange: recorder.canConfigure && recorder.isReady,
                                            select: recorder.setVideoMode)
                    }
                    if let warning = recorder.captureLoad.warning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                            .padding(8).background(.black.opacity(0.55), in: Capsule())
                    }
                        if landscape {
                            Spacer(minLength: 8)
                            if !recorder.isReady && recorder.phase == .idle { unavailableView }
                            Spacer(minLength: 8)
                        }
                    }
                    .frame(maxWidth: landscape ? 350 : .infinity, maxHeight: landscape ? .infinity : nil)
                    if landscape { Spacer(minLength: 0) }
                    else {
                        Spacer(minLength: 8)
                        if !recorder.isReady && recorder.phase == .idle { unavailableView }
                        Spacer(minLength: 8)
                    }
                    footer(landscape: landscape).frame(width: landscape ? 280 : nil)
                }
                .padding(.horizontal, landscape ? 26 : 20)
                .padding(.vertical, landscape ? 10 : 18)
                .frame(maxWidth: landscape ? 1000 : 500)
                .accessibilityHidden(isBlack)
                } else {
                    BrowserView(browser: browser, settings: { pendingResumeID = nil; showSettings = true })
                }

                if isBlack { blackScreen }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ScreenPrivacyAnchor(enabled: recorder.settings.obscureAppSwitcher))
        .preferredColorScheme(recorder.settings.interfaceMode == .browser && !browser.isVideoPage ? .light : .dark)
        .statusBarHidden(isBlack)
        .persistentSystemOverlays(isBlack ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView(recorder: recorder, location: location)
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
            handleCameraLaunchRequest()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; setBlackScreen(false) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            rememberBlackBeforeLeaving()
            setBlackScreen(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: RecorderLaunchRequest.notification)) { _ in
            handleCameraLaunchRequest()
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
            handleCameraLaunchRequest()
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
        .onChange(of: recorder.settings.interfaceMode) { _ in setBlackScreen(false) }
        .onChange(of: recorder.settings.captureMode) { _ in setBlackScreen(false); pendingResumeID = nil }
        .onChange(of: recorder.isReady) { ready in
            if !ready { setBlackScreen(false) }
            restoreOrResumeCapture()
        }
        .onChange(of: recorder.isConfiguring) { _ in handleCameraLaunchRequest() }
        .onChange(of: recorder.resumeRequest) { value in pendingResumeID = value; restoreOrResumeCapture() }
    }

    private var header: some View {
        recorderGlassGroup {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if recorder.phase == .recording {
                                Circle().fill(.red).frame(width: 7, height: 7)
                                Text("REC").font(.caption.weight(.bold)).foregroundStyle(.red)
                                Text(recorder.elapsedLabel).monospacedDigit().font(.headline)
                            } else {
                                Text("畅游").font(.headline)
                            }
                        }
                        Text("\(recorder.activeLensLabel) · \(recorder.settings.captureMode == .video ? "16:9" : "4:3")")
                            .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { recorder.setInterfaceMode(.browser) } label: {
                        Image(systemName: "safari").font(.title3).frame(width: 44, height: 44)
                    }
                    .disabled(recorder.isConfiguring || (recorder.phase != .idle && recorder.phase != .recording))
                    .accessibilityLabel("打开浏览模式")
                    captureOptions
                    Button { pendingResumeID = nil; showSettings = true } label: {
                        Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44)
                    }
                    .disabled(recorder.phase.blocksConfiguration || recorder.isConfiguring)
                    .accessibilityLabel("拍摄设置")
                }
                HStack(spacing: 8) {
                    Text("剩余 \(RecorderFiles.sizeLabel(recorder.availableSpace))")
                    Spacer(minLength: 4)
                    if recorder.settings.captureMode == .video {
                        Text("可录 \(recorder.recordingTimeEstimate(for: recorder.settings))").monospacedDigit()
                    } else if recorder.settings.includeLocation {
                        Label(location.status, systemImage: "location.fill")
                    }
                }.font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .recorderGlass(in: RoundedRectangle(cornerRadius: 22))
        }
        .foregroundStyle(.white)
    }

    private var captureOptions: some View {
        Menu {
            Button(action: recorder.toggleTorch) {
                Label(recorder.torchOn ? "关闭补光灯" : "开启补光灯", systemImage: "flashlight.on.fill")
            }.disabled(!recorder.hasTorch || !recorder.isReady)
            if recorder.settings.captureMode == .video {
                if recorder.dualCaptureSupported {
                    Button(action: recorder.toggleDualCapture) {
                        Label(recorder.settings.dualCapture ? "关闭前后双摄" : "开启前后双摄", systemImage: "rectangle.on.rectangle")
                    }.disabled(!recorder.canConfigure)
                }
            } else {
                Button(action: recorder.toggleLivePhoto) {
                    Label(recorder.settings.captureMode == .livePhoto ? "关闭动态照片" : "开启动态照片", systemImage: "livephoto")
                }.disabled(!recorder.canConfigure || !recorder.isReady || !recorder.livePhotoSupported)
            }
            Divider()
            Button { setBlackScreen(true) } label: {
                Label("进入黑屏", systemImage: "moon.fill")
            }.disabled(recorder.settings.captureMode == .video ? recorder.phase != .recording : !recorder.isReady || recorder.isConfiguring)
        } label: {
            Image(systemName: "ellipsis").font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel("拍摄选项").accessibilityIdentifier("capture-options")
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
        .recorderGlass(in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
    }

    private func footer(landscape: Bool) -> some View {
        recorderGlassGroup {
            VStack(spacing: landscape ? 6 : 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(recorder.zoomStops, id: \.self) { value in
                        Button { recorder.selectZoom(value) } label: {
                            Text(zoomLabel(value))
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 46, minHeight: 44)
                                .background(.white.opacity(abs(recorder.zoom - value) < 0.08 ? 0.18 : 0), in: Capsule())
                        }
                        .disabled(!recorder.isReady || recorder.isConfiguring)
                        .accessibilityLabel("变焦 \(zoomLabel(value))")
                    }
                }
                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: 310)
                .accessibilityIdentifier("capture-zoom")
                .accessibilityValue("当前倍率 \(Double(recorder.zoom), specifier: "%.1f") 倍")
                HStack(spacing: 16) {
                    cameraButton(symbol: "photo.on.rectangle.angled", title: "相册", enabled: recorder.canConfigure) {
                        pendingResumeID = nil
                        showLibrary = true
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        captureButton
                        Text(recorder.phase == .recording ? "停止录像" : recorder.phase.blocksConfiguration ? recorder.phase.title
                             : recorder.settings.captureMode == .video ? "开始录像" : "拍照")
                            .font(.caption.weight(.medium))
                    }
                    Spacer(minLength: 0)
                    cameraButton(symbol: "arrow.triangle.2.circlepath.camera", title: "翻转",
                                 enabled: recorder.canConfigure && recorder.isReady && !recorder.settings.dualCapture, action: recorder.switchCamera)
                }
                .frame(maxWidth: 400)
                HStack(spacing: 4) {
                    ForEach([CaptureMode.video, .photo]) { mode in
                        let selected = (recorder.settings.captureMode == .video) == (mode == .video)
                        Button { recorder.setCaptureMode(mode) } label: {
                            Text(mode.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(selected ? .black : .white.opacity(0.7))
                                .padding(.horizontal, 24).frame(minHeight: 44)
                                .background(selected ? .white : .clear, in: Capsule())
                        }.disabled(!recorder.canConfigure)
                        .accessibilityIdentifier("capture-mode-\(mode.rawValue)")
                    }
                }.padding(3).background(.white.opacity(0.08), in: Capsule())
                Text(recorder.phase == .recording ? "\(recorder.settings.microphoneEnabled ? "有声" : "无声")录像 · \(recorder.settings.recovery.title)恢复黑屏"
                     : recorder.phase.blocksConfiguration ? recorder.phase.title : recorder.status)
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(minHeight: 20)
            }
            .padding(.horizontal, 16).padding(.vertical, landscape ? 8 : 14)
            .recorderGlass(in: RoundedRectangle(cornerRadius: 28))
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
            .frame(width: 84, height: 84)
        }
        .disabled(!(recorder.canRecord || recorder.phase == .recording))
        .opacity(recorder.isReady || recorder.phase.blocksConfiguration ? 1 : 0.45)
        .accessibilityLabel(recorder.phase == .recording ? "停止录像并保存到内置图库" : recorder.settings.captureMode == .video ? "开始录像" : "拍摄并保存到内置图库")
        .accessibilityIdentifier("capture-primary")
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

    private func handleCameraLaunchRequest() {
        guard RecorderLaunchRequest.isPending else { return }
        showSettings = false
        showLibrary = false
        setBlackScreen(false)
        guard !recorder.isConfiguring, recorder.phase == .idle || recorder.phase == .recording else { return }
        _ = RecorderLaunchRequest.consume()
        recorder.setInterfaceMode(.camera)
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
        let enabled = requested && scenePhase == .active && allowed && recorder.settings.interfaceMode == .camera
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

@MainActor
struct VideoFormatControls: View {
    let mode: VideoMode
    let modes: [VideoMode]
    let canChange: Bool
    let select: (VideoMode) -> Void
    private var qualities: [VideoQuality] { VideoQuality.allCases.filter { value in modes.contains { $0.quality == value } } }
    private var rates: [Int] { Array(Set(modes.filter { $0.quality == mode.quality }.map(\.fps))).sorted() }
    private var ranges: [VideoDynamicRange] {
        VideoDynamicRange.allCases.filter { value in
            modes.contains { $0.quality == mode.quality && $0.fps == mode.fps && $0.dynamicRange == value }
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(qualities) { value in
                    Button(value.title) { select(VideoMode(quality: value, fps: mode.fps, dynamicRange: mode.dynamicRange)) }
                }
            } label: { Text(mode.quality.title).frame(maxWidth: .infinity, minHeight: 44) }
                .accessibilityLabel("画质").accessibilityValue(mode.quality.title).accessibilityIdentifier("capture-quality")
            Menu {
                ForEach(rates, id: \.self) { value in
                    Button("\(value) fps") { select(VideoMode(quality: mode.quality, fps: value, dynamicRange: mode.dynamicRange)) }
                }
            } label: { Text("\(mode.fps) fps").frame(maxWidth: .infinity, minHeight: 44) }
                .accessibilityLabel("帧率").accessibilityValue("\(mode.fps) fps").accessibilityIdentifier("capture-fps")
            Menu {
                ForEach(ranges) { value in
                    Button(value.title) { select(VideoMode(quality: mode.quality, fps: mode.fps, dynamicRange: value)) }
                }
            } label: { Text(mode.dynamicRange.title).frame(maxWidth: .infinity, minHeight: 44) }
                .accessibilityLabel("动态范围").accessibilityValue(mode.dynamicRange.title).accessibilityIdentifier("capture-range")
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.white).tint(.white)
        .padding(4).recorderGlass(in: Capsule(), interactive: true)
        .disabled(!canChange || modes.isEmpty)
    }
}
