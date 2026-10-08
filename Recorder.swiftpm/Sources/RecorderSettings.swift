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

enum VideoDynamicRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case sdr, hdr
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

struct VideoMode: Hashable, Identifiable {
    let quality: VideoQuality
    let fps: Int
    var dynamicRange: VideoDynamicRange = .sdr
    var id: String { "\(quality.rawValue)-\(fps)-\(dynamicRange.rawValue)" }
    var title: String { "\(quality.title) · \(fps) fps · \(dynamicRange.title)" }

    static func closest(to requested: Self, in modes: [Self]) -> Self {
        // Prefer resolution, then frame rate, then dynamic range. Never invent
        // an unsupported combination when changing cameras or quality.
        func distance(_ mode: Self) -> Int {
            abs(Int(mode.quality.width - requested.quality.width)) * 1000
                + abs(mode.fps - requested.fps) * 10
                + (mode.dynamicRange == requested.dynamicRange ? 0 : 1)
        }
        return modes.min { distance($0) < distance($1) } ?? requested
    }
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

enum RearCameraLens: String, Codable, Sendable { case automatic, telephoto }

enum CameraZoom {
    static func telephotoBase(switchOvers: [Double], multiplier: Double) -> Double? {
        guard let last = switchOvers.last, multiplier > 0 else { return nil }
        let value = (last * multiplier * 2).rounded() / 2
        return value > 1 ? value : nil
    }
    static func stops(minimum: Double, maximum: Double, telephoto: Double?) -> [Double] {
        var values = [0.5, 1, 2]
        if let telephoto = telephoto { values += [telephoto, telephoto * 2] }
        return Array(Set(values)).filter { $0 >= minimum - 0.01 && $0 <= maximum + 0.01 }.sorted()
    }
}

struct RecorderSettings: Codable, Equatable, Sendable {
    var quality: VideoQuality = .hd1080
    var fps = 30
    var dynamicRange: VideoDynamicRange = .sdr
    var frontCamera = false
    var rearLens: RearCameraLens = .automatic
    var microphoneEnabled = true
    var recovery: BlackScreenRecovery = .doubleTap
    var autoBlackScreen = false
    var reserveMB = 512
    var captureMode: CaptureMode = .video
    var livePhotoEnabled = false
    var dimBlackScreen = true
    var includeLocation = true
    var resumeAfterBackground = false
    var automaticallyExportToPhotos = false
    var hapticFeedback = true
    var thermalProtection = true
    var mode: VideoMode { VideoMode(quality: quality, fps: fps, dynamicRange: dynamicRange) }
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
                value.dynamicRange = VideoDynamicRange(rawValue: old["dynamicRange"] as? String ?? "") ?? .sdr
                value.frontCamera = old["frontCamera"] as? Bool ?? false
                value.rearLens = RearCameraLens(rawValue: old["rearLens"] as? String ?? "") ?? .automatic
                value.microphoneEnabled = old["microphoneEnabled"] as? Bool ?? true
                value.recovery = BlackScreenRecovery(rawValue: old["recovery"] as? String ?? "") ?? .doubleTap
                value.autoBlackScreen = old["autoBlackScreen"] as? Bool ?? false
                value.reserveMB = old["reserveMB"] as? Int ?? 512
                value.captureMode = CaptureMode(rawValue: old["captureMode"] as? String ?? "") ?? .video
                value.livePhotoEnabled = old["livePhotoEnabled"] as? Bool ?? (value.captureMode == .livePhoto)
                value.dimBlackScreen = old["dimBlackScreen"] as? Bool ?? true
                value.includeLocation = old["includeLocation"] as? Bool ?? true
                value.resumeAfterBackground = old["resumeAfterBackground"] as? Bool ?? false
                value.automaticallyExportToPhotos = old["automaticallyExportToPhotos"] as? Bool ?? false
                value.hapticFeedback = old["hapticFeedback"] as? Bool ?? true
                value.thermalProtection = old["thermalProtection"] as? Bool ?? true
            }
            if ![24, 30, 60, 120].contains(value.fps) { value.fps = 30 }
            if ![512, 1024, 2048].contains(value.reserveMB) { value.reserveMB = 512 }
            return value
        }
        if ![24, 30, 60, 120].contains(value.fps) { value.fps = 30 }
        if ![512, 1024, 2048].contains(value.reserveMB) { value.reserveMB = 512 }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "Recorder.settings.v1")
        }
    }

    func hasSameCaptureConfiguration(as other: Self) -> Bool {
        quality == other.quality && fps == other.fps && dynamicRange == other.dynamicRange
            && frontCamera == other.frontCamera && rearLens == other.rearLens
            && microphoneEnabled == other.microphoneEnabled && captureMode == other.captureMode
            && livePhotoEnabled == other.livePhotoEnabled
    }
}

enum CaptureLoad: Int, Sendable {
    case normal, elevated, critical
    var warning: String? {
        switch self {
        case .normal: return nil
        case .elevated: return "温度或相机负载偏高，建议降低帧率"
        case .critical: return "温度或相机负载过高，请等待设备恢复"
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

enum CameraErrorDetail {
    static func describe(_ error: NSError?) -> String {
        guard let error = error else { return "系统未提供错误代码。" }
        var lines = [error.localizedDescription]
        var current: NSError? = error
        // Keep a bounded underlying-error chain, without dumping paths or userInfo.
        for _ in 0..<3 {
            guard let value = current else { break }
            lines.append("\(value.domain) (\(value.code))")
            if let reason = value.localizedFailureReason { lines.append(reason) }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return lines.joined(separator: "\n")
    }
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
