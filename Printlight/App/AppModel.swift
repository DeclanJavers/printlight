import CoreImage
import SwiftUI

/// A captured negative and its developed thumbnail.
struct Shot: Identifiable {
    let id = UUID()
    let dng: Data
    let thumbnail: UIImage
}

/// Glue between the camera, the live preview and the develop/save pipeline.
@MainActor
final class AppModel: ObservableObject {
    let camera = CameraController()
    let preview = PreviewRenderer()

    @Published var params: LookParameters = .load() {
        didSet {
            preview.params = params
            params.save()
        }
    }
    @Published var lookEnabled = true {
        didSet { preview.lookEnabled = lookEnabled }
    }
    @Published private(set) var lastShot: Shot?
    /// Shown on the thumbnail button: the viewfinder frame at the moment of capture, replaced by
    /// the real develop when it's ready.
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var developingCount = 0
    @Published var message: String?

    private let developQueue = DispatchQueue(label: "printlight.develop", qos: .userInitiated)

    init() {
        preview.params = params
        let preview = self.preview
        camera.onPreviewFrame = { @Sendable frame in preview.enqueue(frame) }
        camera.onRawCaptured = { [weak self] dng in self?.handleCapture(dng) }
        camera.onCaptureError = { [weak self] text in self?.message = text }
    }

    func capture() {
        if let snapshot = preview.snapshot() { thumbnail = snapshot }
        camera.capture()
    }

    /// Thumbnail first so the shot shows up quickly, then the full-resolution develop and save.
    private func handleCapture(_ dng: Data) {
        let params = self.params
        developingCount += 1
        developQueue.async {
            let clock = ContinuousClock()
            let start = clock.now
            let thumb = RawDeveloper.develop(dng, params: params, scale: 0.15).flatMap(RawDeveloper.uiImage)
            let thumbDone = clock.now
            Task { @MainActor in
                if let thumb {
                    self.lastShot = Shot(dng: dng, thumbnail: thumb)
                    self.thumbnail = thumb
                }
            }

            let result = Result { try RawDeveloper.heic(from: dng, params: params) }
            let heicDone = clock.now
            Task { @MainActor in
                defer { self.developingCount -= 1 }
                switch result {
                case .success(let heic):
                    await self.save(heic: heic, dng: dng)
                    Self.logTiming(thumb: thumbDone - start, heic: heicDone - thumbDone, save: clock.now - heicDone, bytes: dng.count)
                case .failure(let error):
                    self.message = error.localizedDescription
                }
            }
        }
    }

    private static func logTiming(thumb: Duration, heic: Duration, save: Duration, bytes: Int) {
        func s(_ d: Duration) -> String { String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        print("PRINTLIGHT TIMING dng \(bytes / 1_000_000)MB  thumbnail \(s(thumb))  develop+encode \(s(heic))  save \(s(save))")
    }

    @discardableResult
    func save(heic: Data, dng: Data) async -> Bool {
        do {
            try await PhotoLibrarySaver.save(heic: heic, dng: dng)
            return true
        } catch {
            let ns = error as NSError
            message = "Couldn't save: \(error.localizedDescription) (\(ns.code))"
            return false
        }
    }

    /// Re-develop a shot at full resolution with different settings and save it as a new photo.
    func saveVariant(of shot: Shot, params: LookParameters) async {
        developingCount += 1
        defer { developingCount -= 1 }
        let dng = shot.dng
        let result = await withCheckedContinuation { continuation in
            developQueue.async {
                continuation.resume(returning: Result { try RawDeveloper.heic(from: dng, params: params) })
            }
        }
        switch result {
        case .success(let heic):
            if await save(heic: heic, dng: dng), message == nil {
                message = "Saved to Photos"
            }
        case .failure(let error):
            message = error.localizedDescription
        }
    }
}
