"""Run real Foundation models with Swift; no camera hardware is simulated."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
sources = root / 'Recorder.swiftpm/Sources'
code = (sources / 'RecorderSettings.swift').read_text(encoding='utf-8')
code += '\n' + (sources / 'MediaLibrary.swift').read_text(encoding='utf-8')
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
var new = migrated
new.fps = 120; new.dynamicRange = .hdr; new.rearLens = .telephoto; new.save()
assert(RecorderSettings.load() == new)
new.fps = 999; new.save()
assert(RecorderSettings.load().fps == 30)

let item = MediaItem(id: UUID(), kind: .video, createdAt: Date(), camera: "后置",
    resolution: "3840 × 2160", fps: 120, dynamicRange: "HDR", hasAudio: true, location: nil)
let roundTripped = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
assert(roundTripped == item)
var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
legacy.removeValue(forKey: "dynamicRange")
let restored = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: legacy))
assert(restored.id == item.id && restored.dynamicRange == nil)
print("PASS: HDR/SDR modes, telephoto zoom stops, 120fps/lens persistence, old settings and gallery compatibility")
print("These model checks do not verify camera formats or encoded video on a device.")
'''
folder = root / 'build'
folder.mkdir(exist_ok=True)
path = folder / 'video-mode-check.swift'
path.write_text(code, encoding='utf-8')
subprocess.run(['swift', str(path)], check=True)
