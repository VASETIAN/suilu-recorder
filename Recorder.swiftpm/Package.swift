// swift-tools-version: 5.7
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Recorder",
    platforms: [.iOS("16.0")],
    products: [
        .iOSApplication(
            name: "畅游",
            targets: ["AppModule"],
            bundleIdentifier: "com.tians.recorder",
            displayVersion: "1.4.1",
            bundleVersion: "16",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.red),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait, .landscapeLeft, .landscapeRight,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .camera(purposeString: "畅游使用摄像头预览和录制你主动拍摄的视频。"),
                .microphone(purposeString: "畅游使用麦克风为你录制的视频添加声音。"),
                .photoLibraryAdd(purposeString: "畅游在你选择导出时，将内置图库中的照片、Live Photo 和视频添加到系统照片。"),
                .locationWhenInUse(purposeString: "畅游在拍摄时记录你授权提供的位置，用于图库详情和照片、视频的位置元数据。")
            ],
            additionalInfoPlistContentFilePath: "AdditionalInfo.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            exclude: ["README.md", "AdditionalInfo.plist"],
            sources: ["Sources"],
            resources: [.process("Resources")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
