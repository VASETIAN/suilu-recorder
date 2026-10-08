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
    private var items: [MediaItem] { recorder.libraryItems.filter { filter == nil || $0.kind == filter } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("类型", selection: $filter) {
                    Text("全部").tag(Optional<CaptureMode>.none)
                    ForEach(CaptureMode.allCases) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented).padding()
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
                                NavigationLink {
                                    MediaDetailView(recorder: recorder, itemID: item.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        MediaThumbnail(item: item)
                                            .frame(height: 150).frame(maxWidth: .infinity)
                                            .background(.gray.opacity(0.15)).clipped()
                                            .overlay(alignment: .bottomLeading) {
                                                Text(item.kind.title).font(.caption.bold()).padding(6)
                                                    .background(.black.opacity(0.65), in: Capsule()).padding(6)
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(item.dateLabel).font(.caption).lineLimit(1)
                                        Text(item.exportedAt == nil ? "保存在 App 内" : "已导出到系统照片")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal).padding(.bottom)
                    }
                }
            }
            .navigationTitle("内置图库 · \(recorder.libraryItems.count)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { recorder.refreshLibrary() }
        .alert(item: $recorder.message) { value in
            Alert(title: Text(value.title), message: Text(value.detail), dismissButton: .default(Text("知道了")))
        }
    }
}

@MainActor
private struct MediaThumbnail: View {
    let item: MediaItem
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image = image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: item.kind == .video ? "video.fill" : "photo.fill").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: item.id) {
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
    @State private var share = false
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
                            }.buttonStyle(.borderedProminent)
                            Button { share = true } label: { Label("导出文件", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.bordered)
                        }.disabled(!recorder.canConfigure)
                        if recorder.phase == .saving { ProgressView("正在导出…") }
                        VStack(spacing: 12) {
                            detailRow("类型", item.kind.title)
                            detailRow("拍摄时间", item.dateLabel)
                            detailRow("摄像头", item.camera)
                            detailRow("分辨率", item.resolution)
                            if let fps = item.fps { detailRow("帧率", "\(fps) fps") }
                            if let range = item.dynamicRange { detailRow("动态范围", range) }
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
                            .disabled(!recorder.canConfigure)
                    }.padding()
                }
                .sheet(isPresented: $share) { ShareMediaView(urls: item.resourceURLs) }
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
