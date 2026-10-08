import AVFoundation
import Photos
import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    @ObservedObject var recorder: RecorderController
    @ObservedObject var location: LocationService
    @ObservedObject var pictureInPicture: RecorderPictureInPicture
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: RecorderSettings
    @State private var showLibrary = false
    @State private var pendingBrowserStart = false
    @State private var browserStartSubmitted = false

    init(recorder: RecorderController, location: LocationService, pictureInPicture: RecorderPictureInPicture) {
        self.recorder = recorder
        self.location = location
        self.pictureInPicture = pictureInPicture
        _draft = State(initialValue: recorder.settings)
    }

    private var qualities: [VideoQuality] {
        VideoQuality.allCases.filter { quality in recorder.supportedModes.contains { $0.quality == quality } }
    }
    private var frameRates: [Int] {
        Array(Set(recorder.supportedModes.filter { $0.quality == draft.quality }.map { $0.fps })).sorted()
    }
    private var dynamicRanges: [VideoDynamicRange] {
        VideoDynamicRange.allCases.filter { range in
            recorder.supportedModes.contains { $0.quality == draft.quality && $0.fps == draft.fps && $0.dynamicRange == range }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("边浏览边录像") {
                    if recorder.phase == .recording {
                        LabeledContent("正在录像", value: recorder.elapsedLabel).monospacedDigit()
                        Button("停止录像并保存", role: .destructive) { recorder.stopRecording() }
                        Button("返回浏览，继续录像") {
                            recorder.setInterfaceMode(.browser)
                            dismiss()
                        }
                    } else if pendingBrowserStart {
                        HStack { ProgressView(); Text("正在准备录像…") }
                    } else {
                        Text(recorder.phase == .idle ? recorder.status : recorder.phase.title)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("开始录像并返回浏览", action: startBrowsingRecording)
                            .disabled(!recorder.canRecord)
                    }
                    Text("浏览主页只显示帖子、搜索和网页导航。开始、计时和停止都在这里；停止时保存到内置图库。录像需你手动开启，系统相机和麦克风隐私指示正常显示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("界面形态") {
                    Picker("打开方式", selection: $draft.interfaceMode) {
                        ForEach(RecorderInterface.allCases) { Text($0.title).tag($0) }
                    }
                    Text("浏览模式打开按手机宽度显示的小黑盒官方社区网页，可输入网址或全网搜索。浏览发生在本 App 内，切换到其他 App 后仍按原规则停止或分段恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!recorder.canConfigure)
                if recorder.settings.interfaceMode == .browser {
                    Section {
                        Button("打开相机界面") {
                            recorder.setInterfaceMode(.camera)
                            dismiss()
                        }.disabled(recorder.isConfiguring || (recorder.phase != .idle && recorder.phase != .recording))
                    }
                }
                Section("隐私") {
                    Toggle("任务切换器中隐藏内容", isOn: $draft.obscureAppSwitcher)
                    Text("默认开启。离开活动前台时用模糊遮罩覆盖页面，回到 App 后恢复；软件内正常截图仍可用。不会隐藏系统相机和麦克风隐私指示。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!recorder.canConfigure)
                Section("录像") {
                    if qualities.isEmpty {
                        Text("相机准备完成后可选择画质。")
                    } else {
                        Picker("画质", selection: $draft.quality) {
                            ForEach(qualities) { Text($0.title).tag($0) }
                        }
                        Picker("帧率", selection: $draft.fps) {
                            ForEach(frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        Picker("动态范围", selection: $draft.dynamicRange) {
                            ForEach(dynamicRanges) { Text($0.title).tag($0) }
                        }
                    }
                    Toggle("录制麦克风声音", isOn: $draft.microphoneEnabled)
                        .disabled(draft.captureMode == .photo)
                    Text("最高 4K · 120fps，按设备实际能力显示；HDR 使用 10 位 HEVC。部分高速模式需要主摄，切换后可用倍率会变化。不支持的组合自动调整。前置预览为镜像，保存为正常方向。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!recorder.canConfigure)

                Section("黑屏模式") {
                    Text("相机模式中双击取景器进入黑屏。黑屏拍照：单击拍一张，长按 0.8 秒恢复；Live 开关和镜头保持进入前的设置。浏览模式不自动进入黑屏，录制状态在设置中查看。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("录像恢复方式", selection: $draft.recovery) {
                        ForEach(BlackScreenRecovery.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("开始录像后自动黑屏", isOn: $draft.autoBlackScreen)
                    Toggle("黑屏时将屏幕亮度降到最低", isOn: $draft.dimBlackScreen)
                    Text("恢复界面或离开前台时还原此前亮度。此设置降低整个屏幕亮度，系统相机和麦克风隐私指示仍正常显示。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("黑屏遮住 App 画面，录像仍在前台进行。离开前台时只有已获系统允许的画中画能继续录像；锁屏或相机被系统中断时停止并保存。系统隐私指示始终正常显示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!recorder.canConfigure)

                Section("多任务与返回相机") {
                    Toggle("返回 App 后自动恢复录像", isOn: $draft.resumeAfterBackground)
                        .disabled(!recorder.canConfigure)
                    Text("默认关闭。开启后，离开前台会保存当前一段；回到 App 且保存、相机和权限正常后，用原参数开始新的一段，并恢复此前的黑屏。离开的时间没有画面，不拼接文件；退出进程不会自动录像。保存失败、空间不足、过热或相机错误时取消恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("分屏 / 侧拉拍摄", value: recorder.multitaskingCameraSupported ? "运行环境支持" : "当前环境不支持")
                    LabeledContent("系统画中画", value: pictureInPicture.status)
                    Text("开始录像后手动点击主界面的‘画中画’，等实时小窗出现后再返回主屏幕。仅系统允许多任务相机的环境可以继续录像。关闭后台小窗、将小窗收起或相机被中断时停止并保存；回到前台后关闭画中画可继续录像。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("小窗保留实时画面和 REC 标识，最终尺寸由系统管理。普通 iPhone 录像 App 没有后台相机权限；不支持时返回主屏幕会停止并保存，回来后可以再次录像。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("存储空间") {
                    LabeledContent("剩余空间", value: RecorderFiles.sizeLabel(recorder.availableSpace))
                    Picker("保留空间", selection: $draft.reserveMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                    }.disabled(!recorder.canConfigure)
                    Text("录像开始需超过保留空间加 256 MB，拍照需加 64 MB。录像达到保留空间会自动停止并保存到内置图库。导出到系统照片需要额外空间；失败时 App 原件保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("权限") {
                    LabeledContent("相机", value: capturePermissionLabel(.video))
                    LabeledContent("麦克风", value: capturePermissionLabel(.audio))
                    LabeledContent("照片（仅添加）", value: photoPermissionLabel)
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }

                Section("内置图库") {
                    Toggle("拍摄后自动导出到系统照片", isOn: $draft.automaticallyExportToPhotos)
                        .disabled(!recorder.canConfigure)
                    LabeledContent("拍摄内容", value: "\(recorder.libraryItems.count) 项")
                    Button("打开内置图库") { showLibrary = true }.disabled(!recorder.canConfigure)
                    Text("照片、Live Photo 和视频先保存在 App 内，系统照片导出独立进行。图库支持日期筛选、多选导出，以及原件连同拍摄信息一起共享；所有导出保留 App 原件。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !recorder.photosExportStatus.isEmpty { Text(recorder.photosExportStatus).font(.caption) }
                }

                Section("操作与高负载保护") {
                    Toggle("拍摄操作震动反馈", isOn: $draft.hapticFeedback)
                    Text("开始录像为中等轻震，停止为轻震，原文件保存成功为成功反馈。设备不支持触觉反馈时不会震动。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("温度和相机高负载保护", isOn: $draft.thermalProtection)
                    Text(recorder.captureLoad.warning ?? "温度和相机负载正常")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("负载升高时提醒降低帧率；达到严重状态时停止保存并暂停相机，恢复后需重新录像。不会悄悄改变 SDR／HDR 或帧率。关闭保护也不能阻止系统自行中断相机。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("单击取景器对焦，会显示黄色对焦框；相机继续使用苹果原生自动曝光。双指缩放，双击进入黑屏。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!recorder.canConfigure)

                Section("拍摄位置") {
                    Toggle("在照片和视频中记录定位信息", isOn: $draft.includeLocation)
                        .disabled(!recorder.canConfigure)
                    Text(location.status).font(.caption).foregroundStyle(.secondary)
                    Text("取得你授权的位置后，记录经纬度、定位时间和精度；照片、动态片段和视频也写入位置。定位不可用时仍可拍摄，详情页显示未取得位置。导出内容可能包含这些位置资料。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("快捷启动") {
                    Text("Swift Playgrounds 运行：可将控制中心的“打开 App”设为 Swift Playgrounds，再进入此工程运行。系统不把运行预览注册成独立 App。")
                        .font(.subheadline)
                    Text("独立安装版（iOS 18 及以上）：先打开一次 App，再进入控制中心，长按空白处 → 添加控制 → 搜索“畅游” → 选择“畅游相机”。位置由你选择；也可将“开启畅游相机”快捷指令用于操作按钮。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("关于畅游") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.1")
                    Text("使用 Apple 原生拍摄、画质优先处理、自动白平衡和支持时的镜头畸变校正。原照片直接保存，App 不加美颜或 AI 滤镜。系统是否使用多帧融合等处理由设备和场景决定，成片不保证与系统相机所有模式一致。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("开始前选择长焦倍率会使用真实长焦镜头；受格式能力限制，可能自动降低帧率。4K120 通常需要主摄。其他倍率可能是传感器裁切或数字变焦。照片 JPEG、视频 MOV，Live Photo 保留配对文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("录像方向在开始时确定。录制中旋转设备会调整预览和操作界面，文件保持开始时的方向。横屏录像请先横放设备再开始。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let detail = recorder.lastCameraError {
                    Section("最近相机错误") {
                        Text(detail).font(.caption).textSelection(.enabled)
                        Button("复制错误详情") { UIPasteboard.general.string = detail }
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { pendingBrowserStart = false; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if draft.interfaceMode == .browser { draft.captureMode = .video }
                        if draft != recorder.settings { recorder.apply(draft) }
                        dismiss()
                    }.disabled(!recorder.canConfigure || pendingBrowserStart)
                }
            }
            .onChange(of: draft.quality) { _ in
                if !frameRates.contains(draft.fps) { draft.fps = frameRates.contains(30) ? 30 : frameRates.first ?? 30 }
                clampDynamicRange()
            }
            .onChange(of: draft.fps) { _ in clampDynamicRange() }
            .onAppear { recorder.refreshLibrary() }
            .onChange(of: recorder.isConfiguring) { _ in continueBrowsingStart() }
            .onChange(of: recorder.isReady) { _ in continueBrowsingStart() }
            .onChange(of: recorder.phase) { _ in continueBrowsingStart() }
            .onChange(of: recorder.message?.id) { _ in continueBrowsingStart() }
            .onChange(of: scenePhase) { _ in continueBrowsingStart() }
            .onDisappear { pendingBrowserStart = false }
            .sheet(isPresented: $showLibrary) { LibraryView(recorder: recorder) }
            .interactiveDismissDisabled(pendingBrowserStart)
        }
        .preferredColorScheme(.dark)
        .alert(item: Binding(get: { showLibrary ? nil : recorder.message },
                             set: { recorder.message = $0 })) { value in
            Alert(title: Text(value.title), message: Text(value.detail), dismissButton: .default(Text("知道了")))
        }
    }

    private func startBrowsingRecording() {
        guard recorder.canRecord else { return }
        draft.interfaceMode = .browser
        draft.captureMode = .video
        recorder.message = nil
        pendingBrowserStart = true
        browserStartSubmitted = false
        if draft != recorder.settings { recorder.apply(draft) }
        continueBrowsingStart()
    }

    private func continueBrowsingStart() {
        guard pendingBrowserStart else { return }
        guard scenePhase != .background, recorder.message == nil else { pendingBrowserStart = false; return }
        if recorder.phase == .recording { pendingBrowserStart = false; dismiss(); return }
        if browserStartSubmitted {
            if recorder.phase != .preparing { pendingBrowserStart = false }
            return
        }
        guard scenePhase == .active, recorder.canRecord, recorder.settings.interfaceMode == .browser,
              recorder.settings.captureMode == .video else { return }
        browserStartSubmitted = true
        recorder.startRecording(location: recorder.settings.includeLocation ? location.snapshot() : nil)
    }

    private func clampDynamicRange() {
        if !dynamicRanges.contains(draft.dynamicRange) { draft.dynamicRange = dynamicRanges.first ?? .sdr }
    }

    private func capturePermissionLabel(_ media: AVMediaType) -> String {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "系统限制"
        case .notDetermined: return "尚未请求"
        @unknown default: return "未知"
        }
    }
    private var photoPermissionLabel: String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "系统限制"
        case .notDetermined: return "导出到系统照片时请求"
        @unknown default: return "未知"
        }
    }
}

