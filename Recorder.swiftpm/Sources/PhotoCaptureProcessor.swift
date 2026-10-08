import AVFoundation
import Foundation

// Delegate callbacks take immutable snapshots immediately, then collect them
// on the same serial queue as the recorder. No delegate state crosses queues.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private let completion: @Sendable (Data?, String, Bool, String?) -> Void
    private var image: Data?
    private var resolution = "未知"
    private var movieSucceeded = false
    private var failures: [String] = []

    init(queue: DispatchQueue, completion: @escaping @Sendable (Data?, String, Bool, String?) -> Void) {
        self.queue = queue
        self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let dimensions = photo.resolvedSettings.photoDimensions
        let label = "\(dimensions.width) × \(dimensions.height)"
        let detail = error?.localizedDescription
        queue.async {
            self.image = data
            self.resolution = label
            if let detail = detail { self.failures.append(detail) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let detail = error?.localizedDescription
        queue.async {
            self.movieSucceeded = detail == nil
            if let detail = detail { self.failures.append(detail) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let detail = error?.localizedDescription
        queue.async {
            if let detail = detail { self.failures.append(detail) }
            self.completion(self.image, self.resolution, self.movieSucceeded,
                            self.failures.isEmpty ? nil : self.failures.joined(separator: "\n"))
        }
    }
}
