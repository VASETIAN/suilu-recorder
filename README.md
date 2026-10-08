# 随心记 Recorder

个人拍摄工具：录像、照片、Live Photo、内置图库、拍摄位置、前台黑屏和系统允许时的正常可见画中画。

`Recorder.swiftpm` 可直接在 iPad Swift Playgrounds 打开。设备的相机、帧率、镜头、Live Photo 和多任务相机能力均需实际检测；保留系统隐私指示。关闭或收起后台画中画、锁屏和系统中断时停止并保存。

## 免费 iPhone 构建

GitHub Actions 使用标准 macOS 环境和 Xcode，编译此仓库中的实际 Swift 源文件，输出真正的 arm64 iPhoneOS App 和 unsigned IPA。云端不需要 Apple 账户、密码或签名证书。

Actions → Build iPhone App → 选择成功的运行 → 下载 Recorder-iPhone-unsigned。

将 IPA 下载到 Windows 后，可通过 iLoader 用自己的免费 Apple 账户签名并安装。免费签名有效 7 天，需要刷新；手机须支持开发者模式并信任自己的开发者证书。未签名 IPA 不能直接安装。真机拍摄、保存与画中画结果需设备验证。

源码公开以使用 GitHub 公共仓库的免费标准运行环境。构建产物仅保留 3 天，可重新触发构建；应用录制内容保存在设备中，不进入本仓库。

完整功能及导入说明见 [工程 README](Recorder.swiftpm/README.md)。
