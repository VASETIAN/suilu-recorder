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
    @State private var draft: RecorderSettings
    @State private var showLibrary = false

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
        recorder.supportedModes.filter { $0.quality == draft.quality }.map { $0.fps }.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    }
                    Toggle("录制麦克风声音", isOn: $draft.microphoneEnabled)
                        .disabled(draft.captureMode == .photo)
                    Text("画质和帧率按当前镜头筛选。翻转镜头后，不支持的组合会自动调整。前置预览为镜像，保存的视频为正常方向。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!recorder.canConfigure)

                Section("黑屏模式") {
                    Picker("恢复方式", selection: $draft.recovery) {
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
                    LabeledContent("分屏 / 侧拉拍摄", value: recorder.multitaskingCameraSupported ? "运行环境支持" : "当前环境不支持")
                    LabeledContent("系统画中画", value: pictureInPicture.status)
                    Text("开始录像后手动点击主界面的‘画中画’，等实时小窗出现后再返回主屏幕。仅系统允许多任务相机的环境可以继续录像。关闭后台小窗、将小窗收起或相机被中断时停止并保存；回到前台后关闭画中画可继续录像。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("小窗保留实时画面和 REC 标识，尺寸由系统管理。iPad 支持状态不代表 iPhone 支持；普通 iPhone 运行环境可能不允许多任务相机。工程不注册通话或 VoIP 服务，不能赋予系统未提供的相机权限。")
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
                    LabeledContent("拍摄内容", value: "\(recorder.libraryItems.count) 项")
                    Button("打开内置图库") { showLibrary = true }.disabled(!recorder.canConfigure)
                    Text("照片、Live Photo 和视频先保存在 App 内。图库中可预览、查看拍摄信息、导出到系统照片或导出文件；导出后保留原件。")
                        .font(.caption).foregroundStyle(.secondary)
                }

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
                    Text("独立安装随录后：控制中心可选择“打开 App → 随录”；也可把快捷指令“开启随录相机”加入控制中心。快捷入口只在前台打开相机，不会在后台或锁屏摄像。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("关于随录") {
                    LabeledContent("版本", value: "2.2.0")
                    Text("个人录像工具 · 使用 Apple AVFoundation 与 PhotoKit。照片为 JPEG，视频为 MOV，Live Photo 保留配对的照片与动态片段。2× 在部分设备上属于数字变焦；0.5× 仅在当前摄像头和格式支持时显示。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("录像方向在开始时确定。录制中旋转设备会调整预览和操作界面，文件保持开始时的方向。横屏录像请先横放设备再开始。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("拍摄设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(recorder.phase.blocksConfiguration)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if draft != recorder.settings { recorder.apply(draft) }
                        dismiss()
                    }.disabled(!recorder.canConfigure)
                }
            }
            .onChange(of: draft.quality) { _ in
                if !frameRates.contains(draft.fps) { draft.fps = frameRates.contains(30) ? 30 : frameRates.first ?? 30 }
            }
            .onAppear { recorder.refreshLibrary() }
            .sheet(isPresented: $showLibrary) { LibraryView(recorder: recorder) }
            .interactiveDismissDisabled(recorder.phase.blocksConfiguration)
        }
        .preferredColorScheme(.dark)
        .alert(item: Binding(get: { showLibrary ? nil : recorder.message },
                             set: { recorder.message = $0 })) { value in
            Alert(title: Text(value.title), message: Text(value.detail), dismissButton: .default(Text("知道了")))
        }
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

