"""Encode/decode synthetic front/rear frames with the production Apple writer.

macOS AVFoundation validates files, timing and composition; it does not test
camera hardware, MultiCam resource costs or iPhone performance.
"""
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def build(output: Path):
    writer = (ROOT / 'Recorder.swiftpm/Sources/DualCameraCapture.swift').read_text(encoding='utf-8').split('#if os(iOS)')[0]
    checks = r'''
final class CheckResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var error: Error?
}
let checkQueue = DispatchQueue(label: "DualWriterCheck")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DualWriterCheck-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let render = CIContext(options: [.cacheIntermediates: false])
func pixels(width: Int, height: Int, color: CIColor) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    assert(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    render.render(CIImage(color: color).cropped(to: bounds), to: buffer!, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
    return buffer!
}
func sound(_ frame: Int) -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    assert(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
    var block: CMBlockBuffer?
    assert(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 3200,
        blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 3200, flags: 0, blockBufferOut: &block) == noErr)
    assert(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 3200) == noErr)
    var sample: CMSampleBuffer?
    assert(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
        formatDescription: format!, sampleCount: 1600, presentationTimeStamp: CMTime(value: Int64(frame * 1600), timescale: 48000),
        packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
    return sample!
}
for (width, height, audio) in [(640, 480, true), (480, 640, false)] {
    let url = folder.appendingPathComponent("\(width)x\(height).mov")
    let movie = try DualMovieWriter(url: url, width: width, height: height, fps: 30, audio: audio, metadata: [])
    let rear = pixels(width: width, height: height, color: CIColor(red: 0, green: 0, blue: 1))
    let front = pixels(width: width, height: height, color: CIColor(red: 1, green: 0, blue: 0))
    var began = 0
    for i in 0..<64 {
        if try movie.append(rear: rear, front: front, at: CMTime(value: Int64(i), timescale: 30)) { began += 1 }
        if audio { try movie.appendAudio(sound(i)) }
        Thread.sleep(forTimeInterval: 0.02)
    }
    assert(began == 1 && movie.started && movie.elapsed > 1.9)
    let elapsed = movie.elapsed
    let duplicateStarted = try movie.append(rear: rear, front: front, at: .zero)
    assert(duplicateStarted == false)
    assert(movie.elapsed == elapsed)
    let finished = CheckResult()
    movie.finish(queue: checkQueue) { finished.error = $0; finished.done.signal() }
    assert(finished.done.wait(timeout: .now() + 15) == .success)
    if let error = finished.error { throw error }
    assert(movie.writer.status == .completed)
    let inspected = CheckResult()
    Task.detached {
        do {
            let asset = AVURLAsset(url: url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let sounds = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            assert(videos.count == 1 && sounds.count == (audio ? 1 : 0) && CMTimeGetSeconds(duration) > 1.9)
            let size = try await videos[0].load(.naturalSize)
            assert(Int(size.width) == width && Int(size.height) == height)
            let generator = AVAssetImageGenerator(asset: asset)
            let decoded = try await generator.image(at: CMTime(value: 1, timescale: 1)).image
            let image = CIImage(cgImage: decoded)
            let context = CIContext()
            func rgb(_ x: Double, _ y: Double) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: 4)
                context.render(image, toBitmap: &bytes, rowBytes: 4,
                    bounds: CGRect(x: Double(width) * x, y: Double(height) * y, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                return bytes
            }
            let face = rgb(0.1, 0.85), back = rgb(0.5, 0.5)
            assert(face[0] > 180 && face[2] < 80 && back[2] > 180 && back[0] < 80)
            print("PASS: production dual writer encodes/decodes \(width)x\(height), front red inset + rear blue background, \(audio ? "H.264 + AAC tracks" : "video-only track"), monotonic timing and complete finish")
        } catch { inspected.error = error }
        inspected.done.signal()
    }
    assert(inspected.done.wait(timeout: .now() + 15) == .success)
    if let error = inspected.error { throw error }
}
let empty = try DualMovieWriter(url: folder.appendingPathComponent("empty.mov"), width: 640, height: 480, fps: 30, audio: false, metadata: [])
let stopped = CheckResult()
empty.finish(queue: checkQueue) { stopped.error = $0; stopped.done.signal() }
assert(stopped.done.wait(timeout: .now() + 1) == .success && stopped.error != nil && !empty.started)
print("PASS: stopping dual capture before its first complete pair returns a clear error without hanging")
print("Synthetic macOS files are not a real MultiCam/iPhone recording test.")
'''
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(writer + checks, encoding='utf-8')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, default=ROOT / 'build/dual-capture-check.swift')
    p.add_argument('--generate-only', action='store_true')
    args = p.parse_args()
    build(args.output)
    if not args.generate_only:
        subprocess.run(['swift', str(args.output)], check=True)
