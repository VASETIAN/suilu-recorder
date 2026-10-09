import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct LibraryView: View {
    @ObservedObject var recorder: RecorderController
    @Environment(\.dismiss) private var dismiss
    @State private var filter: CaptureMode?
    @State private var filterByDate = false
    @State private var day = Date()
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var path: [UUID] = []
    @State private var confirmingDelete = false
    @State private var pendingDelete: [MediaItem] = []
    private var items: [MediaItem] { MediaLibrary.filtered(recorder.libraryItems, kind: filter, day: filterByDate ? day : nil) }
    private var selected: [MediaItem] { items.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("类型", selection: $filter) {
                    Text("全部").tag(Optional<CaptureMode>.none)
                    ForEach(CaptureMode.allCases) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented).padding()
                HStack {
                    Toggle("按日期筛选", isOn: $filterByDate)
                    if filterByDate { DatePicker("日期", selection: $day, displayedComponents: .date).labelsHidden() }
                }.padding(.horizontal).padding(.bottom, 8)
                if !recorder.photosExportStatus.isEmpty {
                    Text(recorder.photosExportStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if recorder.preparingShare { ProgressView("正在准备原件与拍摄信息…").padding(8) }
                if items.isEmpty {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 60)).foregroundStyle(.secondary)
                    Text("还没有\(filter?.title ?? "拍摄内容")").font(.headline).padding(.top)
                    Text("拍摄后先保存在这里，可随时导出到系统照片。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 14) {
                            ForEach(items) { item in
                                Button { openOrSelect(item.id) } label: {
                                    tile(item).overlay(alignment: .topTrailing) {
                                        if selecting {
                                            Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(.white).padding(8).background(.black.opacity(0.5), in: Circle())
                                        }
                                    }
                                }.buttonStyle(.plain)
                                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in beginSelection(item.id) })
                                    .accessibilityLabel("\(item.kind.title)，\(item.dateLabel)")
                                    .accessibilityValue(selecting ? selectedIDs.contains(item.id) ? "已选中" : "未选中" : "")
                                    .accessibilityHint(selecting ? "轻点切换选择状态" : "轻点查看，长按多选")
                                    .accessibilityAction(named: "选择此项") { beginSelection(item.id) }
                                    .accessibilityIdentifier("library-item-\(item.id)")
                            }
                        }.padding(.horizontal).padding(.bottom)
                    }
                }
            }
            .navigationTitle("内置图库 · \(recorder.libraryItems.count)")
            .navigationDestination(for: UUID.self) { MediaDetailView(recorder: recorder, itemID: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(selecting ? "取消选择" : "选择") { selecting.toggle(); selectedIDs.removeAll() }
                        .accessibilityIdentifier("library-select")
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    VStack(spacing: 8) {
                        HStack {
                            Text("已选择 \(selected.count) 项").font(.caption)
                            Spacer()
                            Button("全选当前结果") { selectedIDs = Set(items.map(\.id)) }.font(.caption)
                        }
                        HStack {
                            Menu {
                                Button { recorder.exportToPhotos(selected) } label: { Label("导出到系统照片", systemImage: "square.and.arrow.down") }
                                    .disabled(!recorder.exportingPhotoIDs.isEmpty)
                                Button { recorder.prepareShare(selected) } label: { Label("原件与拍摄信息", systemImage: "square.and.arrow.up") }
                                    .disabled(recorder.preparingShare || recorder.shareExport != nil)
                            } label: { Label("导出", systemImage: "square.and.arrow.up") }
                                .disabled(selected.isEmpty || !recorder.deletingMediaIDs.isEmpty)
                                .accessibilityIdentifier("library-export")
                            Spacer()
                            Button(role: .destructive) {
                                pendingDelete = selected
                                confirmingDelete = true
                            } label: { Label("删除", systemImage: "trash") }
                                .disabled(selected.isEmpty || !recorder.canConfigure || !recorder.deletingMediaIDs.isEmpty
                                    || !recorder.exportingPhotoIDs.isDisjoint(with: selectedIDs)
                                    || recorder.preparingShare || recorder.shareExport != nil)
                                .accessibilityIdentifier("library-delete")
                        }
                        if !recorder.deletingMediaIDs.isEmpty { ProgressView("正在删除 \(recorder.deletingMediaIDs.count) 项…") }
                        Text("系统照片批量导出跳过已导出项；原件与信息可在共享页存到文件。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding().recorderGlass(in: RoundedRectangle(cornerRadius: 24))
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .confirmationDialog("删除已选的 \(pendingDelete.count) 项？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除 \(pendingDelete.count) 项", role: .destructive) { recorder.deleteMedia(pendingDelete) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除这些内容的 App 内原件，无法撤销。Live Photo 的照片与动态片段会一起删除；已导出到系统照片的副本不受影响。")
            }
            .sheet(item: $recorder.shareExport, onDismiss: recorder.finishSharing) { export in ShareMediaView(urls: export.urls) }
        }
        .preferredColorScheme(.dark)
        .onAppear { recorder.refreshLibrary() }
        .onChange(of: filter) { _ in selectedIDs.removeAll() }
        .onChange(of: filterByDate) { _ in selectedIDs.removeAll() }
        .onChange(of: day) { _ in selectedIDs.removeAll() }
        .onChange(of: recorder.libraryItems.map(\.id)) { selectedIDs.formIntersection($0) }
        .alert(item: $recorder.message) { value in
            Alert(title: Text(value.title), message: Text(value.detail), dismissButton: .default(Text("知道了")))
        }
    }

    private func beginSelection(_ id: UUID) {
        selecting = true
        selectedIDs.insert(id)
    }

    private func openOrSelect(_ id: UUID) {
        if selecting {
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
        } else { path.append(id) }
    }

    private func tile(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaThumbnail(item: item, generation: recorder.thumbnailGeneration)
                .frame(height: 150).frame(maxWidth: .infinity)
                .background(.gray.opacity(0.15)).clipped()
                .overlay(alignment: .bottomLeading) {
                    Text(item.kind.title).font(.caption.bold()).padding(6)
                        .background(.black.opacity(0.65), in: Capsule()).padding(6)
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.dateLabel).font(.caption).lineLimit(1)
            Text(recorder.exportingPhotoIDs.contains(item.id) ? "正在导出…" : item.exportedAt == nil ? "保存在 App 内" : "已导出到系统照片")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct MediaThumbnail: View {
    let item: MediaItem
    let generation: Int
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image = image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: item.kind == .video ? "video.fill" : "photo.fill").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: "\(item.id)-\(generation)") {
            let url = item.thumbnailURL
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            if let data = data { image = UIImage(data: data) }
        }
    }
}

@MainActor
private struct MediaDetailView: View {
    @ObservedObject var recorder: RecorderController
    let itemID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var repeatExport = false
    private var item: MediaItem? { recorder.libraryItems.first { $0.id == itemID } }

    var body: some View {
        Group {
            if let item = item {
                ScrollView {
                    VStack(spacing: 20) {
                        MediaPlayerView(item: item).frame(height: 330).background(.black)
                        HStack(spacing: 16) {
                            Button {
                                if item.exportedAt != nil { repeatExport = true }
                                else { recorder.exportToPhotos(item) }
                            } label: {
                                Label(item.exportedAt == nil ? "导出到系统照片" : "再次导出", systemImage: "square.and.arrow.down")
                            }.buttonStyle(.borderedProminent).disabled(recorder.exportingPhotoIDs.contains(item.id))
                            Button { recorder.prepareShare([item]) } label: { Label("原件与信息", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.bordered)
                                .disabled(recorder.preparingShare || !recorder.deletingMediaIDs.isEmpty)
                        }.disabled(!recorder.canConfigure)
                        if recorder.exportingPhotoIDs.contains(item.id) { ProgressView("正在导出…") }
                        if recorder.preparingShare { ProgressView("正在准备原件…") }
                        VStack(spacing: 12) {
                            detailRow("类型", item.kind.title)
                            detailRow("拍摄时间", item.dateLabel)
                            detailRow("摄像头", item.camera)
                            detailRow("分辨率", item.resolution)
                            if let fps = item.fps { detailRow("帧率", "\(fps) fps") }
                            if let range = item.dynamicRange { detailRow("动态范围", range) }
                            if let zoom = item.zoomFactor { detailRow("拍摄倍率", String(format: "%.2f×", zoom)) }
                            if let bias = item.exposureBias { detailRow("曝光补偿", String(format: "%+.1f EV", bias)) }
                            if let locked = item.focusExposureLocked { detailRow("对焦曝光锁定", locked ? "已锁定" : "自动") }
                            if let previous = item.resumedFromID {
                                detailRow("接续录像", String(previous.uuidString.prefix(8)))
                                Text("此文件是返回 App 后新录的一段，离开期间没有画面。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let seconds = item.duration { detailRow("时长", String(format: "%.1f 秒", seconds)) }
                            detailRow("声音", item.hasAudio ? "有声" : "无声")
                            detailRow("文件大小", RecorderFiles.sizeLabel(item.size))
                            if let location = item.location {
                                detailRow("经纬度", location.coordinateLabel)
                                detailRow("定位精度", "约 \(Int(location.horizontalAccuracy)) 米")
                                if location.verticalAccuracy >= 0 { detailRow("海拔", String(format: "%.1f 米", location.altitude)) }
                                detailRow("定位时间", location.timestamp.formatted(date: .abbreviated, time: .standard))
                                Button("在地图查看位置") {
                                    let url = URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=拍摄位置".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
                                    if let url = url { UIApplication.shared.open(url) }
                                }
                            } else { detailRow("拍摄位置", "未取得位置") }
                            if let exported = item.exportedAt { detailRow("导出时间", exported.formatted(date: .abbreviated, time: .shortened)) }
                            if item.recovered { Text("此内容从异常结束的拍摄中恢复，可能不完整。原始文件可导出检查。")
                                .font(.caption).foregroundStyle(.orange) }
                        }.padding().background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                        if item.kind == .livePhoto {
                            Text("长按画面播放 Live Photo。导出到系统照片会保存完整动态照片；导出文件会提供照片与动态片段两个原文件。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("导出后 App 内原件保留。删除 App 或工程的应用数据会失去仅保存在内置图库的内容。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("删除 App 内原件", role: .destructive) { deleting = true }
                            .disabled(!recorder.canConfigure || !recorder.deletingMediaIDs.isEmpty || recorder.exportingPhotoIDs.contains(item.id) || recorder.preparingShare || recorder.shareExport != nil)
                    }.padding()
                }
                .confirmationDialog("再次导出会在系统照片中添加一份副本", isPresented: $repeatExport, titleVisibility: .visible) {
                    Button("再次导出") { recorder.exportToPhotos(item) }
                    Button("取消", role: .cancel) {}
                }
                .alert("删除 App 内原件？", isPresented: $deleting) {
                    Button("删除", role: .destructive) { recorder.deleteMedia(item); dismiss() }
                    Button("取消", role: .cancel) {}
                } message: { Text("这会删除内置图库中的照片或视频。已导出到系统照片的副本不受影响。") }
            } else { Text("这项内容已移除").foregroundStyle(.secondary) }
        }
        .navigationTitle("拍摄详情").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(recorder.phase.blocksConfiguration)
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
            .font(.subheadline)
    }
}

@MainActor
private struct MediaPlayerView: View {
    let item: MediaItem
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var imageLoadingFinished = false
    var body: some View {
        Group {
            if item.kind == .video {
                if let player = player { VideoPlayer(player: player) }
                else { ProgressView() }
            } else if item.kind == .livePhoto {
                LocalLivePhotoView(item: item)
            } else if let image = image { Image(uiImage: image).resizable().scaledToFit() }
            else if imageLoadingFinished {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("无法预览这张照片").font(.headline)
                    Text("原文件仍保留，可以导出检查。").font(.caption).foregroundStyle(.secondary)
                }
            }
            else { ProgressView() }
        }
        .task(id: item.id) {
            if item.kind == .video { player = AVPlayer(url: item.movieURL) }
            else if item.kind == .photo {
                imageLoadingFinished = false
                image = nil
                let url = item.imageURL
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                if let data = data { image = UIImage(data: data) }
                imageLoadingFinished = true
            }
        }
        .onDisappear { player?.pause() }
    }
}

@MainActor
private struct LocalLivePhotoView: UIViewRepresentable {
    let item: MediaItem
    final class Coordinator { var requestID: PHLivePhotoRequestID?; var loadedID: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> LivePhotoContainer {
        let view = LivePhotoContainer()
        view.liveView.isMuted = !item.hasAudio
        view.liveView.accessibilityLabel = "Live Photo，长按播放"
        return view
    }
    func updateUIView(_ view: LivePhotoContainer, context: Context) {
        guard context.coordinator.loadedID != item.id else { return }
        if let old = context.coordinator.requestID { PHLivePhoto.cancelRequest(withRequestID: old) }
        context.coordinator.loadedID = item.id
        let id = item.id
        view.representedID = id
        view.stillView.image = UIImage(contentsOfFile: item.imageURL.path)
        view.liveView.livePhoto = nil
        view.liveView.isHidden = true
        view.notice.isHidden = true
        context.coordinator.requestID = PHLivePhoto.request(withResourceFileURLs: item.resourceURLs,
            placeholderImage: view.stillView.image, targetSize: CGSize(width: 1200, height: 1200),
            contentMode: .aspectFit) { [weak view] livePhoto, info in
                let cancelled = (info[PHLivePhotoInfoCancelledKey] as? NSNumber)?.boolValue == true
                let finalResult = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue != true
                let failed = info[PHLivePhotoInfoErrorKey] != nil
                guard !cancelled else { return }
                DispatchQueue.main.async {
                    guard let view = view, view.representedID == id else { return }
                    if let livePhoto = livePhoto {
                        view.liveView.livePhoto = livePhoto
                        view.liveView.isHidden = false
                        view.notice.isHidden = true
                    } else if finalResult || failed {
                        view.liveView.isHidden = true
                        view.notice.isHidden = false
                    }
                }
            }
    }
    static func dismantleUIView(_ view: LivePhotoContainer, coordinator: Coordinator) {
        view.representedID = nil
        view.liveView.stopPlayback()
        if let id = coordinator.requestID { PHLivePhoto.cancelRequest(withRequestID: id) }
    }
}

@MainActor
private final class LivePhotoContainer: UIView {
    let liveView = PHLivePhotoView()
    let stillView = UIImageView()
    let notice = UILabel()
    var representedID: UUID?
    override init(frame: CGRect) {
        super.init(frame: frame)
        stillView.contentMode = .scaleAspectFit
        liveView.contentMode = .scaleAspectFit
        notice.text = "动态片段暂不可播放，原文件仍可导出。"
        notice.textColor = .white
        notice.font = .preferredFont(forTextStyle: .caption1)
        notice.textAlignment = .center
        notice.numberOfLines = 2
        notice.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        notice.isHidden = true
        addSubview(stillView)
        addSubview(liveView)
        addSubview(notice)
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        stillView.frame = bounds
        liveView.frame = bounds
        notice.frame = CGRect(x: 8, y: max(0, bounds.height - 60), width: max(0, bounds.width - 16), height: 60)
    }
}

@MainActor
private struct ShareMediaView: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
