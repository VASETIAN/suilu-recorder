@preconcurrency import AVFoundation
import CoreImage
import Foundation

// All writer/capture state is confined to RecorderController's capture queue.
final class DualMovieWriter: @unchecked Sendable {
    let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let bounds: CGRect
    private let fps: Int
    private(set) var started = false
    private var closing = false
    private var firstTime = CMTime.invalid
    private var lastTime = CMTime.invalid

    init(url: URL, width: Int, height: Int, fps: Int, audio: Bool, metadata: [AVMetadataItem]) throws {
        self.fps = fps
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6,
                                               AVVideoExpectedSourceFrameRateKey: fps]])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        let sound = audio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000]) : nil
        sound?.expectsMediaDataInRealTime = true
        self.audio = sound
        guard writer.canAdd(video), sound.map({ writer.canAdd($0) }) ?? true else {
            throw Self.error("无法创建双摄视频或声音输出。")
        }
        writer.add(video)
        if let sound { writer.add(sound) }
    }

    static func composite(rear: CIImage, front: CIImage, bounds: CGRect) -> CIImage {
        func fill(_ image: CIImage, in rect: CGRect) -> CIImage {
            let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return scaled.transformed(by: CGAffineTransform(
                translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY)).cropped(to: rect)
        }
        let inset = bounds.width * 0.035
        let small = CGRect(x: inset, y: bounds.height * 0.72 - inset,
                           width: bounds.width * 0.28, height: bounds.height * 0.28)
        return fill(front, in: small).composited(over: fill(rear, in: bounds)).cropped(to: bounds)
    }

    var elapsed: Double {
        guard firstTime.isValid, lastTime.isValid else { return 0 }
        return max(0, CMTimeGetSeconds(lastTime - firstTime))
    }

    @discardableResult
    func append(rear: CVPixelBuffer, front: CVPixelBuffer, at time: CMTime) throws -> Bool {
        guard !closing else { return false }
        if started && time <= lastTime { return false }
        if !firstTime.isValid {
            guard writer.startWriting() else { throw writer.error ?? Self.error("双摄录像无法开始。") }
            writer.startSession(atSourceTime: time)
            firstTime = time
        }
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return false }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            throw Self.error("双摄视频缓冲区不足。")
        }
        let image = Self.composite(rear: CIImage(cvPixelBuffer: rear), front: CIImage(cvPixelBuffer: front), bounds: bounds)
        context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        guard adaptor.append(output, withPresentationTime: time) else {
            throw writer.error ?? Self.error("双摄视频写入失败。")
        }
        let justStarted = !started
        started = true
        lastTime = time
        return justStarted
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        guard started, !closing, let audio, audio.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= firstTime else { return }
        guard audio.append(sample) else { throw writer.error ?? Self.error("双摄声音写入失败。") }
    }

    func finish(queue: DispatchQueue, completion: @escaping @Sendable (Error?) -> Void) {
        guard !closing else { return }
        closing = true
        guard started else {
            writer.cancelWriting()
            completion(Self.error("没有收到完整的前后摄像头画面，本次未生成录像。"))
            return
        }
        guard writer.status == .writing else {
            completion(writer.error ?? Self.error("双摄视频写入已中断。"))
            return
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting { [self] in
            let error = writer.status == .completed ? nil : writer.error ?? Self.error("双摄视频保存未完成。")
            queue.async { completion(error) }
        }
    }

    static func error(_ text: String) -> NSError {
        NSError(domain: "Recorder.DualCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

#if os(iOS)
final class DualCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                               AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureMultiCamSession()
    private(set) var rearInput: AVCaptureDeviceInput?
    private(set) var frontInput: AVCaptureDeviceInput?
    private let rear = AVCaptureVideoDataOutput(), front = AVCaptureVideoDataOutput()
    private let sound = AVCaptureAudioDataOutput()
    private let queue: DispatchQueue
    private var latestFront: CVPixelBuffer?
    private var latestFrontTime = CMTime.invalid
    private var movie: DualMovieWriter?
    private var pendingURL: URL?
    private var includeAudio = false
    private var fps = 30
    private var metadata: [AVMetadataItem] = []
    private var onStart: (() -> Void)?
    private var onFinish: ((URL, Error?) -> Void)?
    private var generation = 0
    private var ending = false
    private var expectedWidth = 0, expectedHeight = 0
    var elapsed: Double { movie?.elapsed ?? 0 }

    static var devices: (AVCaptureDevice, AVCaptureDevice)? {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
                                                         mediaType: .video, position: .unspecified)
        for group in discovery.supportedMultiCamDeviceSets {
            if let back = group.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }),
               let face = group.first(where: { $0.position == .front }) { return (back, face) }
        }
        return nil
    }

    static func format(_ device: AVCaptureDevice, mode: VideoMode) -> AVCaptureDevice.Format? {
        device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return $0.isMultiCamSupported && size.width == mode.quality.width && size.height == mode.quality.height
                && [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(CMFormatDescriptionGetMediaSubType($0.formatDescription))
                && $0.supportedColorSpaces.contains(.sRGB)
                && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(mode.fps) && $0.maxFrameRate >= Double(mode.fps) }
        }.min { ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) < ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) }
    }

    static var modes: [VideoMode] {
        guard let (back, face) = devices else { return [] }
        return [VideoQuality.hd720, .hd1080].flatMap { quality in
            [24, 30].compactMap { rate in
                let mode = VideoMode(quality: quality, fps: rate)
                return format(back, mode: mode) != nil && format(face, mode: mode) != nil ? mode : nil
            }
        }
    }

    init(queue: DispatchQueue) { self.queue = queue; super.init() }

    func configure(mode: VideoMode, audio: Bool) throws -> VideoMode {
        let modes = Self.modes
        guard let (back, face) = Self.devices, !modes.isEmpty else {
            throw DualMovieWriter.error("当前设备没有可用的前后同步摄像组合。")
        }
        let desired = VideoMode.closest(to: mode, in: modes)
        let candidates = [desired] + modes.filter { $0 != desired }.sorted {
            $0.quality.width == $1.quality.width ? $0.fps < $1.fps : $0.quality.width > $1.quality.width
        }
        for candidate in candidates {
            try configureDevices(back, face, mode: candidate, audio: audio)
            if session.hardwareCost <= 1 { fps = candidate.fps; includeAudio = audio; return candidate }
        }
        throw DualMovieWriter.error("双摄组合超过设备资源预算，请关闭双摄使用单镜头录像。")
    }

    private func configureDevices(_ back: AVCaptureDevice, _ face: AVCaptureDevice, mode: VideoMode, audio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for connection in session.connections { session.removeConnection(connection) }
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        let backInput = try AVCaptureDeviceInput(device: back), faceInput = try AVCaptureDeviceInput(device: face)
        for input in [backInput, faceInput] {
            guard let format = Self.format(input.device, mode: mode), session.canAddInput(input) else {
                throw DualMovieWriter.error("双摄镜头或格式不可用。")
            }
            try input.device.lockForConfiguration()
            input.device.activeFormat = format
            input.device.automaticallyAdjustsVideoHDREnabled = false
            if format.isVideoHDRSupported { input.device.isVideoHDREnabled = false }
            input.device.activeColorSpace = .sRGB
            let duration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
            input.device.activeVideoMinFrameDuration = duration
            input.device.activeVideoMaxFrameDuration = duration
            if input.device.isFocusModeSupported(.continuousAutoFocus) { input.device.focusMode = .continuousAutoFocus }
            if input.device.isExposureModeSupported(.continuousAutoExposure) { input.device.exposureMode = .continuousAutoExposure }
            if input.device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { input.device.whiteBalanceMode = .continuousAutoWhiteBalance }
            input.device.unlockForConfiguration()
            input.videoMinFrameDurationOverride = duration
            session.addInputWithNoConnections(input)
        }
        for (input, output) in [(backInput, rear), (faceInput, front)] {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output), let port = input.ports.first(where: { $0.mediaType == .video }) else {
                throw DualMovieWriter.error("双摄视频输出不可用。")
            }
            session.addOutputWithNoConnections(output)
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw DualMovieWriter.error("双摄视频连接不可用。") }
            session.addConnection(connection)
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
        if audio {
            guard let device = AVCaptureDevice.default(for: .audio) else { throw DualMovieWriter.error("麦克风不可用。") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(sound) else { throw DualMovieWriter.error("双摄声音输出不可用。") }
            session.addInputWithNoConnections(input)
            session.addOutputWithNoConnections(sound)
            sound.setSampleBufferDelegate(self, queue: queue)
            let connection = AVCaptureConnection(inputPorts: input.ports.filter { $0.mediaType == .audio }, output: sound)
            guard session.canAddConnection(connection) else { throw DualMovieWriter.error("麦克风连接不可用。") }
            session.addConnection(connection)
        }
        rearInput = backInput; frontInput = faceInput
        latestFront = nil
    }

    func attachPreview(_ back: AVCaptureVideoPreviewLayer, _ face: AVCaptureVideoPreviewLayer) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for (layer, input) in [(back, rearInput), (face, frontInput)] {
            if layer.session === session { continue }
            layer.session = nil
            guard let port = input?.ports.first(where: { $0.mediaType == .video }) else { continue }
            layer.setSessionWithNoConnection(session)
            let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            if session.canAddConnection(connection) { session.addConnection(connection) }
        }
    }

    func detach() {
        // Release device connections before configuring the next capture session.
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for connection in session.connections { session.removeConnection(connection) }
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        rearInput = nil; frontInput = nil; latestFront = nil
    }

    func start(url: URL, orientation: AVCaptureVideoOrientation, metadata: [AVMetadataItem],
               began: @escaping () -> Void, finished: @escaping (URL, Error?) -> Void) {
        generation += 1
        let request = generation
        ending = false; pendingURL = url; self.metadata = metadata; onStart = began; onFinish = finished
        latestFront = nil
        if let format = rearInput?.device.activeFormat {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let portrait = orientation == .portrait || orientation == .portraitUpsideDown
            expectedWidth = Int(portrait ? size.height : size.width)
            expectedHeight = Int(portrait ? size.width : size.height)
        }
        for output in [rear, front] {
            if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == request, self.pendingURL != nil, self.movie?.started != true else { return }
            self.stop(error: DualMovieWriter.error("双摄未及时就绪，没有开始录像，请重试。"))
        }
    }

    func stop(error: Error? = nil) {
        guard let url = pendingURL, !ending else { return }
        ending = true
        let complete = onFinish
        let finish: @Sendable (Error?) -> Void = { [self] failure in
            movie = nil; pendingURL = nil; onStart = nil; onFinish = nil; latestFront = nil; ending = false
            complete?(url, error ?? failure)
        }
        if let movie { movie.finish(queue: queue, completion: finish) }
        else { finish(error ?? DualMovieWriter.error("尚未收到完整双摄画面，本次未生成录像。")) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard pendingURL != nil, !ending else { return }
        do {
            if output === sound { try movie?.appendAudio(sampleBuffer); return }
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            guard CVPixelBufferGetWidth(pixels) == expectedWidth, CVPixelBufferGetHeight(pixels) == expectedHeight else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if output === front { latestFront = pixels; latestFrontTime = time; return }
            guard let face = latestFront else { return }
            let difference = abs(CMTimeGetSeconds(time - latestFrontTime))
            if difference > 0.25 {
                if movie?.started == true { stop(error: DualMovieWriter.error("前置画面中断，双摄录像已停止并保存。")) }
                return
            }
            if movie == nil, let url = pendingURL {
                movie = try DualMovieWriter(url: url, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                            fps: fps, audio: includeAudio, metadata: metadata)
            }
            if try movie?.append(rear: pixels, front: face, at: time) == true { onStart?() }
        } catch { stop(error: error) }
    }
}
#endif
