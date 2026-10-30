import Combine
import CoreImage
import Photos
import SwiftUI

/// A negative open for editing: its RAW, a thumbnail, the settings it was developed with, and
/// the Photos asset it lives in (nil until a new capture has finished saving).
struct Shot: Identifiable {
    let id: UUID
    let dng: Data
    let thumbnail: UIImage
    let params: LookParameters
    var assetID: String?

    init(id: UUID = UUID(), dng: Data, thumbnail: UIImage, params: LookParameters, assetID: String? = nil) {
        self.id = id
        self.dng = dng
        self.thumbnail = thumbnail
        self.params = params
        self.assetID = assetID
    }
}

/// Glue between the camera, the live preview and the develop/save pipeline.
@MainActor
final class AppModel: ObservableObject {
    let camera = CameraController()
    let preview = PreviewRenderer()
    let library = ShotLibrary()

    @Published var params: LookParameters = .load() {
        didSet {
            preview.params = params
            params.save()
        }
    }
    @Published var lookEnabled = true {
        didSet { preview.lookEnabled = lookEnabled }
    }
    @Published var zebras = UserDefaults.standard.object(forKey: "printlight.zebras") as? Bool ?? true {
        didSet {
            preview.zebras = zebras
            UserDefaults.standard.set(zebras, forKey: "printlight.zebras")
        }
    }
    @Published private(set) var lastShot: Shot?
    /// Shown on the thumbnail button: the viewfinder frame at the moment of capture, replaced by
    /// the real develop when it's ready.
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var developingCount = 0
    @Published var message: String?
    /// Download progress while a library shot's RAW is fetched (from iCloud if needed).
    @Published private(set) var openingProgress: Double?

    private let developQueue = DispatchQueue(label: "printlight.develop", qos: .userInitiated)
    private var libraryWatch: AnyCancellable?

    init() {
        preview.params = params
        preview.zebras = zebras
        let preview = self.preview
        camera.onPreviewFrame = { @Sendable frame in preview.enqueue(frame) }
        camera.onRawCaptured = { [weak self] dng in self?.handleCapture(dng) }
        camera.onCaptureError = { [weak self] text in self?.message = text }
        // Until something is shot this session, the thumbnail shows the newest library shot.
        libraryWatch = library.$assets.sink { [weak self] assets in
            guard let self, self.thumbnail == nil, let newest = assets.first else { return }
            Task { @MainActor in
                let image = await self.libraryThumbnail(for: newest, side: 200)
                if self.thumbnail == nil { self.thumbnail = image }
            }
        }
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
            let shotID = UUID()
            Task { @MainActor in
                if let thumb {
                    self.lastShot = Shot(id: shotID, dng: dng, thumbnail: thumb, params: params)
                    self.thumbnail = thumb
                }
            }

            let result = Result { try RawDeveloper.heic(from: dng, params: params) }
            let heicDone = clock.now
            Task { @MainActor in
                defer { self.developingCount -= 1 }
                switch result {
                case .success(let heic):
                    if let assetID = await self.saveNew(heic: heic, dng: dng, params: params),
                       self.lastShot?.id == shotID {
                        self.lastShot?.assetID = assetID
                    }
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

    /// Saves a new shot to Photos and registers it in the library. Returns its asset ID when it
    /// was saved as one edited RAW asset (the normal case).
    @discardableResult
    private func saveNew(heic: Data, dng: Data, params: LookParameters) async -> String? {
        do {
            let assetID = try await PhotoLibrarySaver.save(heic: heic, dng: dng, params: params)
            if let assetID { library.add(assetID) } else { library.refresh() }
            return assetID
        } catch {
            let ns = error as NSError
            message = "Couldn't save: \(error.localizedDescription) (\(ns.code))"
            return nil
        }
    }

    /// Re-develops a shot at full resolution and saves it. A shot that's already in Photos gets
    /// its edit replaced (same photo, new look); otherwise it's saved as a new photo.
    func saveEdit(of shot: Shot, params: LookParameters) async {
        developingCount += 1
        defer { developingCount -= 1 }
        let dng = shot.dng
        let assetID = shot.assetID ?? (lastShot?.id == shot.id ? lastShot?.assetID : nil)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await withCheckedContinuation { continuation in
            developQueue.async {
                continuation.resume(returning: Result { try RawDeveloper.heic(from: dng, params: params) })
            }
        }
        let developed = clock.now
        switch result {
        case .success(let heic):
            var saved = false
            if let assetID {
                do {
                    try await PhotoLibrarySaver.updateEdit(assetID: assetID, heic: heic, params: params)
                    saved = true
                    library.refresh()
                } catch {
                    message = "Couldn't save: \(error.localizedDescription)"
                }
            } else {
                saved = await saveNew(heic: heic, dng: dng, params: params) != nil
            }
            Self.logTiming(thumb: .zero, heic: developed - start, save: clock.now - developed, bytes: dng.count)
            if saved, message == nil {
                message = "Saved"
            }
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    /// Loads a library shot for editing: its RAW (downloading from iCloud if needed) and the
    /// settings it was saved with.
    func open(_ asset: PHAsset) async -> Shot? {
        openingProgress = 0
        defer { openingProgress = nil }
        let assetID = asset.localIdentifier
        do {
            let (dng, saved) = try await PhotoLibrarySaver.loadNegative(assetID: assetID) { fraction in
                Task { @MainActor in self.openingProgress = fraction }
            }
            let thumbnail = await libraryThumbnail(for: asset, side: 1200) ?? UIImage()
            return Shot(dng: dng, thumbnail: thumbnail, params: saved ?? params, assetID: assetID)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    private func libraryThumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            library.imageManager.requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
    }
}
