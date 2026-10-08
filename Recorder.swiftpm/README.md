# 随录 Recorder 2.2.0

个人拍摄工具 App Playground：录像、普通照片、Live Photo、内置图库、拍摄定位、黑屏模式及系统允许时的可见画中画。最低 iOS / iPadOS 16.0；控制中心入口取决于系统版本及独立安装状态。

## 导入和升级

1. 将 **Recorder-2.2.0.swiftpm.zip** 保存到 iPad「文件」，解压到新文件夹。
2. 在 Swift Playgrounds 的「浏览」中打开整个 **Recorder.swiftpm**，点击运行，再点「开启相机」。无需改代码。
3. 按提示允许相机、需要声音时允许麦克风、需要拍摄位置时允许定位。**向系统照片添加权限仅在你主动导出时请求。**
4. 在设置「关于随录」确认版本为 **2.2.0**。

旧工程请先保留。若升级复用同一应用数据目录，会读取旧设置并将旧版未保存录像移入图库；如果 Playgrounds 为新工程使用了不同数据目录，旧工程里的文件不会自动跨目录迁移，请先在旧工程导出。已在系统照片里的内容不受影响。

## 拍摄和图库

- 底部选择 **录像 / 拍照**。拍照界面的倍率旁有 **LIVE** 开关：黄色表示开启动态照片，划线表示普通照片。切换到录像再返回拍照会记住 Live 开关。录像保留原来的画质、帧率、声音、倍率、对焦、补光和空间保护。
- 普通拍照输出 JPEG。Live Photo 使用 Apple 原生照片捕获，保留照片和配对的动态片段；设备或当前镜头不支持时提示并改为普通照片。
- Live Photo 在拍照配置中工作，切换录像时使用另一组输出，避免电影文件输出禁用动态照片。一次只进行一个拍摄任务。
- 所有新内容**先保存到内置图库**。顶部图库按钮可筛选、预览、播放视频、长按播放 Live Photo，以及查看拍摄详情。
- **导出到系统照片**：普通照片 / 视频各创建一项，Live Photo 将照片与 pairedVideo 一起创建为动态照片；保留拍摄时间和位置。
- **导出文件**：使用系统共享面板；Live Photo 提供原始 JPEG 与 MOV 两个文件。要保留系统照片中的 Live Photo 效果，请使用「导出到系统照片」。
- 导出成功或失败都保留 App 内原件；重复导出会先确认。只有你在详情页确认删除才删除 App 内该项内容，不删除系统照片副本。
- 拍摄先写暂存目录，文件和信息齐备后在同一存储卷移动到图库；成功后不留下第二份拍摄暂存副本。异常结束的文件尽量恢复，空文件保留暂存但不伪装成正常成片。

## 拍摄位置和信息

默认启用「记录定位信息」，但仍需你授予使用期间定位权限。只在前台更新位置，拍摄取最近 60 秒内的有效定位；支持系统近似位置，记录实际定位精度。定位被拒绝、过期或不可用时仍可拍摄，详情页显示未取得位置。

详情包括拍摄时间、摄像头、分辨率、视频帧率 / 时长、声音、文件大小、经纬度、有效海拔、定位时间和精度。可在 Apple 地图查看拍摄位置。

照片写入 GPS 元数据；视频和 Live Photo 的动态片段写入 QuickTime ISO 6709 位置。导出到系统照片时另外设置资产位置和拍摄时间。分享原文件也会携带已写入的位置。设置中关闭记录后，新拍摄内容不再添加位置。

## 黑屏与亮度

录像中的黑屏仍是前台遮罩，支持单击、双击或长按 0.8 秒恢复，可设置开始录像后自动黑屏。

默认在黑屏时将整个屏幕亮度调到最低。第一次进入保存原亮度；重复进入不覆盖它。恢复界面、停止 / 完成录制、错误提示、离开活动前台或界面消失时还原。可在设置关闭自动降亮度。

2.1.0 将调亮度放到进入黑屏的操作中直接执行，手动与自动黑屏、手势退出和停止录像共用一条路径。请确认设置中的「黑屏时将屏幕亮度降到最低」已开启。最低亮度是系统允许的数值 0，不代表关闭背光。打开控制中心会离开活动前台并还原原亮度，因此控制中心里的滑块不代表黑屏期间的数值。

系统相机 / 麦克风隐私指示始终正常显示。未开启受支持的画中画时，切换 App 会停止摄像；锁屏和系统相机中断时停止并保存。有限后台任务只负责文件收尾、导出及最长 5 秒的原生画中画启动过渡；画中画确认开启后结束该任务，持续运行依赖系统许可。强制终止进程时应用不能保证执行任何界面清理回调，若亮度未还原可用系统亮度控件恢复。

## 返回相机、画中画和多任务

在 **录像** 模式开始录像后，主界面的 **画中画** 按钮显示当前支持状态。显示“可以开启画中画”时，点击按钮，等正常尺寸的实时小窗出现后，再返回主屏幕或使用其他 App。小窗保留实时画面和红色 REC 标识，使用系统的移动、缩放和关闭控件，不添加隐藏窗口。

启用需同时满足：设备支持画中画、运行 App 加载了 `UIBackgroundModes: audio` 声明、AVKit 认为当前内容可进入画中画，以及相机会话报告支持并启用了多任务相机。工程通过 SwiftPM 的 `additionalInfoPlistContentFilePath` 合并 AdditionalInfo.plist；没有添加 VoIP 或通话服务。只在已有录像时开启，照片和 Live Photo 不使用后台拍摄。

**支持 iPad 不代表支持 iPhone。**普通 iPhone 或 Playgrounds 宿主可能返回“系统未允许画中画相机”或“运行环境未加载画中画声明”。此时按钮禁用，离开前台会停止保存；改窗口大小或重新导入不能补足系统没有授予的权限。未来独立安装到 iPhone 仍以实际能力检测为准。

关闭后台小窗会停止并保存；将小窗收起、锁屏、其他 App 占用相机或系统中断，也会停止保存，不再自动续录。回到随录前台后关闭画中画，已有录像可以继续；点击停止后归档到内置图库。画中画启动失败或过渡超过 5 秒时，后台录制停止并保存，前台录像按正常流程处理。

没有开启受支持的画中画时，离开前台仍停止并保存。返回后恢复预览和录像按钮，手动开始新的一段。恢复同时依据拍摄队列状态、UIKit 前后台通知、相机中断结束及运行状态通知。

只有系统报告支持时，才启用公开多任务相机功能；分屏、侧拉和台前调度也取决于设备、系统和宿主。多任务下性能可能下降，可降低画质。

## 快捷启动

你当前仅在 Swift Playgrounds 运行，控制中心能启动的是宿主 **Swift Playgrounds**，系统没有这个工程预览的独立 App 入口。可在支持自定义控制的系统中添加「打开 App → Swift Playgrounds」，或创建同样的「打开 App」快捷指令并加入控制中心，然后进入工程运行。

要一键直接打开「随录」，需先将其签名并独立安装。之后可设置控制中心「打开 App → 随录」。源码还包含 App Intent「开启随录相机」和 App Shortcuts Provider：在支持其元数据提取的独立 App 构建中，可在快捷指令选择并加入控制中心。该 Intent 只打开前台相机，不自动开始录制。

详见压缩包旁「快捷启动说明.md」。这里不把启动 Playgrounds 说成直接启动随录。

## 检查范围

本次使用官方 Swift 5.10.1 编译器解析清单及全部 13 个源文件，并检查全工程语法树、异步条件、图标、资源、清单、额外 plist 和 ZIP。直接提取生产生命周期及画中画资格判断方法，使用队列 / 会话替身检查：有效画中画继续、未开启时停止、关闭后台小窗后保存、前台返回、能力拒绝、相机中断、迟到回调和最长 5 秒启动过渡。2.1.0 在同一画中画回放场景失败，本版通过；原有返回相机时序检查保持通过。

**没有 Apple iOS SDK，没有对整个 App 完成 iOS 类型检查或构建，也未在 iPad / iPhone 实测本版。**上述回放不执行 AVKit，不证明真实小窗、相机、Playgrounds 宿主或设备续录成功。此前图库 / 设置 / 坐标和亮度逻辑检查使用平台替身，相关实现保留，未把旧检查算作本次设备验证。完整范围及待测步骤见压缩包旁“验证结果.md”。

Mac 上可用 Xcode 打开 App Playground；只检查源文件类型时可执行：

```sh
xcrun swiftc -parse-as-library -typecheck -swift-version 5 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -target arm64-apple-ios16.0 Sources/*.swift
```

## Apple / Swift 依据

- [原生 Live Photo 捕获与保存](https://developer.apple.com/documentation/avfoundation/capturing-and-saving-live-photos)
- [Live Photo 与电影文件输出不能共存](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput)
- [附加照片 GPS 元数据](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/metadata)
- [Live Photo 自动生成配对标识并允许附加电影元数据](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/livephotomoviemetadata)
- [视频标准位置键](https://developer.apple.com/documentation/avfoundation/avmetadatakey/quicktimemetadatakeylocationiso6709)
- [系统照片的位置](https://developer.apple.com/documentation/photos/phassetchangerequest/location)
- [本地文件加载 Live Photo](https://developer.apple.com/documentation/photos/phlivephoto/request(withresourcefileurls:placeholderimage:targetsize:contentmode:resulthandler:))
- [在 iPad 上使用和自定义控制中心](https://support.apple.com/zh-cn/guide/ipad/ipade572ca56/ipados)
- [iPad 多任务相机支持及限制](https://developer.apple.com/documentation/avkit/accessing-the-camera-while-multitasking-on-ipad)
- [当前环境是否支持多任务相机](https://developer.apple.com/documentation/avfoundation/avcapturesession/ismultitaskingcameraaccesssupported)
- [系统亮度的数值范围](https://developer.apple.com/documentation/uikit/uiscreen/brightness)

2.0.1 中的照片解码失败提示、Live Photo 静态画面回退和取消回调处理均保留。2.1.0 增加相机返回恢复、拍照界面内 Live 开关、黑屏入口直接调亮度及受支持环境中的多任务相机。

2.2.0 增加正常可见的手动系统画中画、运行条件提示和结束保存流程。其实现使用 AVKit 的相机内容源，不注册或模拟视频通话。

- [Apple：画中画中的相机内容与生命周期](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls)
- [Apple：画中画控制器和背景音频声明](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller)
- [SwiftPM：附加 Info.plist 的原生清单接口](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/AppleProductTypes/Product.swift)
