import Foundation

struct CaptureLocation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let timestamp: Date
    var coordinateLabel: String { String(format: "%.6f, %.6f", latitude, longitude) }
    var iso6709: String {
        let locale = Locale(identifier: "en_US_POSIX")
        func coordinate(_ value: Double, digits: Int) -> String {
            let magnitude = String(format: "%.5f", locale: locale, abs(value))
            let integerCount = magnitude.split(separator: ".")[0].count
            return (value < 0 ? "-" : "+") + String(repeating: "0", count: max(0, digits - integerCount)) + magnitude
        }
        let point = coordinate(latitude, digits: 2) + coordinate(longitude, digits: 3)
        if verticalAccuracy >= 0 {
            return point + (altitude < 0 ? "-" : "+") + String(format: "%.2f", locale: locale, abs(altitude)) + "/"
        }
        return point + "/"
    }
}

struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: CaptureMode
    let createdAt: Date
    let camera: String
    var resolution: String
    let fps: Int?
    let hasAudio: Bool
    let location: CaptureLocation?
    var duration: Double?
    var exportedAt: Date?
    var recovered = false
    var folder: URL { MediaLibrary.directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    var imageURL: URL { folder.appendingPathComponent("photo.jpg") }
    var movieURL: URL { folder.appendingPathComponent(kind == .video ? "video.mov" : "live.mov") }
    var thumbnailURL: URL { folder.appendingPathComponent("thumbnail.jpg") }
    var resourceURLs: [URL] {
        switch kind {
        case .video: return [movieURL]
        case .photo: return [imageURL]
        case .livePhoto: return [imageURL, movieURL]
        }
    }
    var size: Int64 {
        resourceURLs.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    var dateLabel: String { createdAt.formatted(date: .abbreviated, time: .shortened) }
}

// Called on RecorderController's captureQueue. A capture is written to Staging,
// then renamed into Library on the same volume. Photos export copies resources.
enum MediaLibrary {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var directory: URL { root.appendingPathComponent("Library", isDirectory: true) }
    static var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    static func stageFolder(_ id: UUID) -> URL { staging.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func prepare() throws {
        for url in [directory, staging] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var value = url
            var flags = URLResourceValues()
            flags.isExcludedFromBackup = url == staging
            try? value.setResourceValues(flags)
        }
    }
    static func write(_ item: MediaItem, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(item).write(to: folder.appendingPathComponent("asset.json"), options: .atomic)
    }
    static func begin(_ item: MediaItem) throws -> URL {
        try prepare()
        let folder = stageFolder(item.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try write(item, in: folder)
        return folder
    }
    static func finish(_ item: MediaItem) throws {
        let folder = stageFolder(item.id)
        let filenames = item.kind == .video ? ["video.mov"] : item.kind == .photo ? ["photo.jpg"] : ["photo.jpg", "live.mov"]
        for filename in filenames {
            guard let bytes = try? folder.appendingPathComponent(filename).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  bytes > 0 else { throw LibraryError("拍摄文件尚未完整写入，已保留暂存内容。") }
        }
        try write(item, in: folder)
        try FileManager.default.moveItem(at: folder, to: item.folder)
    }
    static func items() -> [MediaItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("asset.json")),
                  let item = try? JSONDecoder().decode(MediaItem.self, from: data), item.id == id else { return nil }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }
    static func markExported(_ item: MediaItem) throws {
        var value = item
        value.exportedAt = Date()
        try write(value, in: value.folder)
    }
    static func delete(_ item: MediaItem) throws {
        // Folder comes from a UUID, never from a caller-supplied path.
        try FileManager.default.removeItem(at: item.folder)
    }
    static func recover() throws {
        try prepare()
        let folders = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("asset.json")),
                  var item = try? JSONDecoder().decode(MediaItem.self, from: data), item.id == id else { continue }
            item.recovered = true
            let image = folder.appendingPathComponent("photo.jpg")
            let movie = folder.appendingPathComponent("live.mov")
            let imageBytes = (try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let movieBytes = (try? movie.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if item.kind == .livePhoto && imageBytes > 0 && movieBytes == 0 { item.kind = .photo }
            // Keep malformed / empty captures in Staging; never silently delete.
            try? finish(item)
        }
        // Preserve old-version movies when the application sandbox is reused.
        for old in RecorderFiles.pending() {
            let item = MediaItem(id: UUID(), kind: .video, createdAt: old.date, camera: "旧版录像",
                                resolution: "未知", fps: nil, hasAudio: true, location: nil, recovered: true)
            let folder = try begin(item)
            try FileManager.default.moveItem(at: old.url, to: folder.appendingPathComponent("video.mov"))
            try finish(item)
        }
    }
}

struct LibraryError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}
