import AVFoundation

/// One-shot delegate for a single RAW capture. Kept alive by CameraController until it calls back.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    enum CaptureError: LocalizedError {
        case noData
        var errorDescription: String? { "The camera returned no RAW data." }
    }

    private let completion: (Result<Data, Error>) -> Void
    private var dng: Data?
    private var error: Error?

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            self.error = error
            return
        }
        guard photo.isRawPhoto else { return }
        dng = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error ?? self.error {
            completion(.failure(error))
        } else if let dng {
            completion(.success(dng))
        } else {
            completion(.failure(CaptureError.noData))
        }
    }
}
