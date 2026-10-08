"""Run real Foundation models with Swift; no camera hardware is simulated."""
from pathlib import Path
import argparse
import re
import subprocess

root = Path(__file__).resolve().parent.parent
sources = root / 'Recorder.swiftpm/Sources'
code = (sources / 'RecorderSettings.swift').read_text(encoding='utf-8')
library = (sources / 'MediaLibrary.swift').read_text(encoding='utf-8')
# Redirect only storage paths into a disposable test folder; all model, file,
# metadata and original-copy methods below remain the production implementations.
library = re.sub(r'static var root: URL \{.*?\n    \}', 'static var root: URL { checkDirectory }', library, count=1, flags=re.S)
library = library.replace('FileManager.default.temporaryDirectory', 'checkDirectory')
code = 'import Foundation\nlet checkDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RecorderModelCheck-" + UUID().uuidString)\n' + code
code += '\n' + library
code += r'''
let hdr120 = VideoMode(quality: .uhd4K, fps: 120, dynamicRange: .hdr)
let sdr120 = VideoMode(quality: .uhd4K, fps: 120)
let hdr60 = VideoMode(quality: .uhd4K, fps: 60, dynamicRange: .hdr)
let hd30 = VideoMode(quality: .hd1080, fps: 30)
assert(VideoMode.closest(to: hdr120, in: [hd30, sdr120, hdr60]) == sdr120)
assert(VideoMode.closest(to: hdr120, in: [hd30, hdr120, hdr60]) == hdr120)
assert(VideoMode.closest(to: sdr120, in: [hd30, hdr60]) == hdr60)
assert(VideoMode.closest(to: hd30, in: [hdr60, hd30]) == hd30)
assert(Set([sdr120, hdr120]).count == 2)
assert(CameraZoom.telephotoBase(switchOvers: [2, 8], multiplier: 0.5) == 4)
assert(CameraZoom.telephotoBase(switchOvers: [2, 10], multiplier: 0.5) == 5)
assert(CameraZoom.telephotoBase(switchOvers: [], multiplier: 1) == nil)
assert(CameraZoom.stops(minimum: 0.5, maximum: 15, telephoto: 4) == [0.5, 1, 2, 4, 8])
assert(CameraZoom.stops(minimum: 4, maximum: 16, telephoto: 4) == [4, 8])
assert(CameraZoom.stops(minimum: 1, maximum: 3, telephoto: nil) == [1, 2])

let key = "Recorder.settings.v1"
let previous = UserDefaults.standard.data(forKey: key)
defer {
    if let previous = previous { UserDefaults.standard.set(previous, forKey: key) }
    else { UserDefaults.standard.removeObject(forKey: key) }
}
let old: [String: Any] = ["quality": "uhd4K", "fps": 60, "includeLocation": false,
    "captureMode": "photo", "livePhotoEnabled": true, "recovery": "longPress"]
UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: old), forKey: key)
let migrated = RecorderSettings.load()
assert(migrated.fps == 60 && migrated.dynamicRange == .sdr && !migrated.includeLocation)
assert(migrated.recovery == .longPress && migrated.livePhotoEnabled)
assert(migrated.rearLens == .automatic)
assert(!migrated.resumeAfterBackground && !migrated.automaticallyExportToPhotos)
assert(migrated.thermalProtection && migrated.hapticFeedback)
assert(migrated.interfaceMode == .camera && migrated.obscureAppSwitcher)
var new = migrated
new.fps = 120; new.dynamicRange = .hdr; new.rearLens = .telephoto
new.resumeAfterBackground = true; new.automaticallyExportToPhotos = true
new.thermalProtection = false; new.hapticFeedback = false
new.interfaceMode = .browser; new.obscureAppSwitcher = false; new.captureMode = .video; new.save()
assert(RecorderSettings.load() == new)
var preferenceOnly = new
preferenceOnly.resumeAfterBackground.toggle(); preferenceOnly.hapticFeedback.toggle()
preferenceOnly.interfaceMode = .camera; preferenceOnly.obscureAppSwitcher.toggle()
assert(preferenceOnly.hasSameCaptureConfiguration(as: new))
preferenceOnly.fps = 30
assert(!preferenceOnly.hasSameCaptureConfiguration(as: new))
new.fps = 999; new.save()
assert(RecorderSettings.load().fps == 30)
new.captureMode = .photo; new.save()
assert(RecorderSettings.load().captureMode == .video) // Browser form always uses movie output.

assert(BrowserAddress.destination("  https://www.xiaoheihe.cn/app/bbs/home  ") == BrowserAddress.community)
assert(BrowserAddress.destination("example.com/test?q=1")?.absoluteString == "https://example.com/test?q=1")
let search = URLComponents(url: BrowserAddress.destination("苹果 & 相机 #测试")!, resolvingAgainstBaseURL: false)!
assert(search.host == "www.bing.com" && search.queryItems?.first?.value == "苹果 & 相机 #测试")
for invalid in ["", "  ", "javascript:alert(1)", "DATA:text/html,test", "file:///tmp/test",
                "xiaoheihe://feed", "https://user:password@example.com/", "user:password@example.com"] {
    assert(BrowserAddress.destination(invalid) == nil, "Unsafe/empty input: \(invalid)")
}
assert(BrowserAddress.allows(URL(string: "https://example.com/path")!))
assert(!BrowserAddress.allows(URL(string: "about:blank")!))
assert(!BrowserAddress.allows(URL(string: "file:///tmp/test")!))
for enabled in [false, true] {
    for active in [false, true] {
        assert(ScreenPrivacyState.shouldCover(enabled: enabled, active: active) == (enabled && !active))
    }
}
print("PASS: mobile community URL, web/search input escaping and blocked schemes/credentials, UI preferences and foreground/switcher privacy states")

let item = MediaItem(id: UUID(), kind: .video, createdAt: Date(), camera: "后置",
    resolution: "3840 × 2160", fps: 120, dynamicRange: "HDR", hasAudio: true, location: nil)
let roundTripped = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
assert(roundTripped == item)
var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
legacy.removeValue(forKey: "dynamicRange")
let restored = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: legacy))
assert(restored.id == item.id && restored.dynamicRange == nil)
assert(restored.zoomFactor == nil && restored.resumedFromID == nil && restored.exposureBias == nil)
let before = Date(timeIntervalSince1970: 1_780_000_000)
let position = CaptureLocation(latitude: 18.25, longitude: 109.5, altitude: 3,
    horizontalAccuracy: 4, verticalAccuracy: 5, timestamp: before)
let first = MediaItem(id: UUID(), kind: .video, createdAt: before, camera: "后置长焦",
    resolution: "3840 × 2160", fps: 60, dynamicRange: "HDR", hasAudio: true, location: position,
    zoomFactor: 4, exposureBias: 0.7, focusExposureLocked: true)
let second = MediaItem(id: UUID(), kind: .livePhoto, createdAt: before.addingTimeInterval(86400), camera: "后置主摄",
    resolution: "4032 × 3024", fps: nil, hasAudio: true, location: position, resumedFromID: first.id)
try FileManager.default.createDirectory(at: checkDirectory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: checkDirectory) }
let firstStage = try MediaLibrary.begin(first), secondStage = try MediaLibrary.begin(second)
let original = Data([0, 1, 5, 10, 128, 255])
try original.write(to: firstStage.appendingPathComponent("video.mov"))
try original.write(to: secondStage.appendingPathComponent("photo.jpg"))
try original.write(to: secondStage.appendingPathComponent("live.mov"))
try MediaLibrary.finish(first); try MediaLibrary.finish(second)
assert(!FileManager.default.fileExists(atPath: firstStage.path))
try MediaLibrary.markExported(first)
try MediaLibrary.setDuration(first, seconds: 10.5)
var refreshed = try MediaLibrary.item(first.id)
assert(refreshed.exportedAt != nil && refreshed.duration == 10.5 && refreshed.zoomFactor == 4)
try MediaLibrary.setDuration(first, seconds: 11.5)
try MediaLibrary.markExported(first) // Intentionally use the stale original metadata.
refreshed = try MediaLibrary.item(first.id)
assert(refreshed.duration == 11.5 && refreshed.exportedAt != nil && refreshed.location == position)
let values = MediaLibrary.items()
assert(values.count == 2 && values.first?.id == second.id)
assert(MediaLibrary.filtered(values, kind: .video, day: before).map(\.id) == [first.id])
assert(MediaLibrary.filtered(values, kind: .video, day: second.createdAt).isEmpty)
assert(MediaLibrary.filtered(values, kind: nil, day: nil).count == 2)
let shared = try MediaLibrary.prepareExport([first, second])
assert(shared.urls.count == 4 && Set(shared.urls.map(\.lastPathComponent)).count == 4)
for url in shared.urls where url.pathExtension != "json" {
    let bytes = try Data(contentsOf: url); assert(bytes == original)
}
let information = try JSONSerialization.jsonObject(with: Data(contentsOf: shared.urls.last!)) as! [String: Any]
let records = information["items"] as! [[String: Any]]
assert(records.count == 2 && records[0]["zoomFactor"] as? Double == 4)
assert(records[0]["location"] != nil && records[1]["resumedFromID"] as? String == first.id.uuidString)
assert((records[1]["files"] as? [String])?.count == 2)
MediaLibrary.cleanOldShareExports()
assert(!FileManager.default.fileExists(atPath: shared.folder.path))
for url in first.resourceURLs + second.resourceURLs {
    let bytes = try Data(contentsOf: url); assert(bytes == original)
}
let foldersBefore = try FileManager.default.contentsOfDirectory(at: checkDirectory, includingPropertiesForKeys: nil)
// A metadata-only record has no original resource.
let missing = MediaItem(id: UUID(), kind: .video, createdAt: before, camera: "test", resolution: "test", fps: 30, hasAudio: false, location: nil)
try FileManager.default.createDirectory(at: missing.folder, withIntermediateDirectories: false)
try MediaLibrary.write(missing, in: missing.folder)
do { _ = try MediaLibrary.prepareExport([first, missing]); assertionFailure("Missing original must reject export") }
catch {}
let foldersAfter = try FileManager.default.contentsOfDirectory(at: checkDirectory, includingPropertiesForKeys: nil)
assert(foldersAfter.count == foldersBefore.count && FileManager.default.fileExists(atPath: first.movieURL.path))
print("PASS: HDR/SDR modes, telephoto zoom stops, 120fps/lens persistence, old settings and gallery compatibility")
print("PASS: opt-in preferences, storage moves, stale metadata updates, date/type filtering, paired originals + metadata and failed-export cleanup")
print("These model checks do not verify camera formats or encoded video on a device.")
'''
parser = argparse.ArgumentParser()
parser.add_argument('--generate-only', action='store_true')
parser.add_argument('--output', type=Path, default=root / 'build/video-mode-check.swift')
args = parser.parse_args()
path = args.output
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(code, encoding='utf-8')
if not args.generate_only:
    subprocess.run(['swift', str(path)], check=True)
