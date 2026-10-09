# 畅游 Recorder

个人拍摄与浏览工具：录像、照片、Live Photo、内置图库、位置、前台浏览录像和任务切换器隐私遮罩。Recorder.swiftpm 可直接在 iPad Swift Playgrounds 打开，最低 iOS／iPadOS 16。

1.4.6 为社区与视频页面分别使用浅色、深色主题，搜索栏、底栏、状态栏外观、安全区域和网页回弹背景一并切换；打开、返回、前进及主页面导航都更新主题，加载中的旧网址不会覆盖刚选择的主题。相机页与设置存储信息新增预计可录时长，按所选规格和扣除预留空间后的容量估算，开始录像后按实际写入量更新。估算不是保证时长，手机渲染与实际误差仍需真机核对。

1.4.5 的音频混合及中断分类沿用：普通录像与双摄在 iOS 18 及以上开启 Apple AVCaptureSession 的公开音频混合选项，保留自动麦克风配置。真正发生中断仍停止并保存当前录像。没有手机中断日志及真机复现，尚不能确认抖音打断拍摄的根因或保证有声播放始终不受系统限制。iOS 16／17 保留原来的系统音频默认行为。

新增默认关闭的前后同步录像：Apple AVCaptureMultiCamSession 获取后置主摄＋前置画面，Core Image 合成大画面与可拖动小画面，AVAssetWriter 编码一个带声音的视频。双摄提供设备支持的 720p／1080p、24／30fps、SDR，并检查资源预算；单摄原有 HDR、长焦及设备支持的 4K120 保留。拍照与 Live Photo 使用单摄。

移除无法可靠使用的画中画及背景音频声明。返回主屏幕会停止保存，可选的返回后分段恢复仍默认关闭；没有离开期间的画面。保留系统隐私指示和后台相机限制。不卸载旧 App，用同一 Apple 账号覆盖升级保留内置图库。

## iPhone 构建

GitHub Actions 用 Xcode 26.3 与实际 iPhoneOS SDK 编译全部 Swift 文件、图标、App Intents 和原生控制中心扩展，输出真实 arm64 未签名 IPA；云端不需要 Apple 账号或证书。

Actions → Build iPhone App → 成功运行 → 下载 Recorder-iPhone-unsigned。Windows 可在 iLoader 中用自己的免费 Apple 账号签名安装；密码与验证码由本人输入，免费签名通常需每 7 天刷新。未签名 IPA 不能直接安装。

源码公开以使用公共仓库的免费标准 macOS 构建环境，产物保留 3 天，可重新触发；设备拍摄内容不进入仓库。SDK 编译、合成文件和桌面 WebKit 检查不能代替 iPhone 的拍摄、性能、音频及网页测试。

安装版包含 iOS 18+ 原生控制中心扩展，打开 App 一次后在「添加控制」中搜索「畅游」。Controls/ 保存扩展源文件；Swift Playgrounds 的 .swiftpm 本身仅运行 App，不能安装扩展。

详细说明见 [工程 README](Recorder.swiftpm/README.md)。
