import Foundation

enum VideoQuality: String, Codable, CaseIterable, Identifiable, Hashable {
    case hd720, hd1080, uhd4K
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4K: return "4K"
        }
    }
    var width: Int32 {
        switch self {
        case .hd720: return 1280
        case .hd1080: return 1920
        case .uhd4K: return 3840
        }
    }
    var height: Int32 { width * 9 / 16 }
}

struct VideoMode: Hashable, Identifiable {
    let quality: VideoQuality
    let fps: Int
    var id: String { "\(quality.rawValue)-\(fps)" }
    var title: String { "\(quality.title) · \(fps) fps" }
}

enum BlackScreenRecovery: String, Codable, CaseIterable, Identifiable {
    case singleTap, doubleTap, longPress
    var id: String { rawValue }
    var title: String {
        switch self {
        case .singleTap: return "单击"
        case .doubleTap: return "双击"
        case .longPress: return "长按 0.8 秒"
        }
    }
}

enum CaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case video, photo, livePhoto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: return "录像"
        case .photo: return "拍照"
        case .livePhoto: return "Live Photo"
        }
    }
}

struct RecorderSettings: Codable, Equatable, Sendable {
    var quality: VideoQuality = .hd1080
    var fps = 30
    var frontCamera = false
    var microphoneEnabled = true
    var recovery: BlackScreenRecovery = .doubleTap
    var autoBlackScreen = false
    var reserveMB = 512
    var captureMode: CaptureMode = .video
    var livePhotoEnabled = false
    var dimBlackScreen = true
    var includeLocation = true
    var mode: VideoMode { VideoMode(quality: quality, fps: fps) }
    var reserveBytes: Int64 { Int64(reserveMB) * 1_048_576 }

    static func load() -> RecorderSettings {
        guard let data = UserDefaults.standard.data(forKey: "Recorder.settings.v1"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else {
            // Preserve saved fields when upgrading a version with fewer settings.
            var value = Self()
            if let data = UserDefaults.standard.data(forKey: "Recorder.settings.v1"),
               let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                value.quality = VideoQuality(rawValue: old["quality"] as? String ?? "") ?? .hd1080
                value.fps = old["fps"] as? Int ?? 30
                value.frontCamera = old["frontCamera"] as? Bool ?? false
                value.microphoneEnabled = old["microphoneEnabled"] as? Bool ?? true
                value.recovery = BlackScreenRecovery(rawValue: old["recovery"] as? String ?? "") ?? .doubleTap
                value.autoBlackScreen = old["autoBlackScreen"] as? Bool ?? false
                value.reserveMB = old["reserveMB"] as? Int ?? 512
                value.captureMode = CaptureMode(rawValue: old["captureMode"] as? String ?? "") ?? .video
                value.livePhotoEnabled = old["livePhotoEnabled"] as? Bool ?? (value.captureMode == .livePhoto)
                value.dimBlackScreen = old["dimBlackScreen"] as? Bool ?? true
                value.includeLocation = old["includeLocation"] as? Bool ?? true
            }
            if ![24, 30, 60].contains(value.fps) { value.fps = 30 }
            if ![512, 1024, 2048].contains(value.reserveMB) { value.reserveMB = 512 }
            return value
        }
        if ![24, 30, 60].contains(value.fps) { value.fps = 30 }
        if ![512, 1024, 2048].contains(value.reserveMB) { value.reserveMB = 512 }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "Recorder.settings.v1")
        }
    }
}

enum RecordingPhase: Equatable, Sendable {
    case idle, preparing, recording, photographing, finishing, saving
    var blocksConfiguration: Bool { self != .idle }
    var title: String {
        switch self {
        case .idle: return "准备录像"
        case .preparing: return "正在准备…"
        case .recording: return "录像中"
        case .photographing: return "正在拍摄…"
        case .finishing: return "正在完成录像…"
        case .saving: return "正在保存…"
        }
    }
}

enum CameraPiPState: Sendable {
    case inactive, starting, active
}

struct RecorderMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

struct PendingRecording: Identifiable {
    let url: URL
    let size: Int64
    let date: Date
    var id: String { url.lastPathComponent }
    var title: String { date.formatted(date: .abbreviated, time: .shortened) }
}

enum RecorderFiles {
    // A durable staging directory protects a finished movie if Photos fails or the app exits.
    // Successful Photos saves remove the staged movie; unsuccessful ones remain recoverable.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingRecordings", isDirectory: true)
    }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var value = directory
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try value.setResourceValues(flags)
    }

    static func newURL() throws -> URL {
        try prepareDirectory()
        return directory.appendingPathComponent("Recorder-\(UUID().uuidString).mov")
    }

    static func pending(excluding active: URL? = nil) -> [PendingRecording] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url in
            guard url != active, url.pathExtension == "mov",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return PendingRecording(url: url, size: Int64(values.fileSize ?? 0),
                                    date: values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    static func availableBytes() -> Int64? {
        // The sandbox root exists on the first launch, even before Application
        // Support / PendingRecordings has been created. Both use the same volume.
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let value = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = value.volumeAvailableCapacityForImportantUsage { return bytes }
        if let values = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let bytes = values[.systemFreeSize] as? NSNumber { return bytes.int64Value }
        return nil
    }

    static func sizeLabel(_ bytes: Int64?) -> String {
        guard let bytes = bytes else { return "暂时无法读取" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
