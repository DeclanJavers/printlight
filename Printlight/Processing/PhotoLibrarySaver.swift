import Photos
import os

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAuthorized(PHAuthorizationStatus)
        var errorDescription: String? {
            "Printlight needs permission to add photos. Turn it on in Settings > Printlight > Photos."
        }
    }

    private static let log = Logger(subsystem: "com.declanjavers.printlight", category: "save")

    /// Saves the developed HEIC and the DNG as two separate photos.
    /// Photos refuses them as a RAW+processed pair (PHPhotosError 3300), so they aren't combined.
    static func save(heic: Data, dng: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized(status) }

        try await create { $0.addResource(with: .photo, data: heic, options: nil) }
        do {
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = "com.adobe.raw-image"
            try await create { $0.addResource(with: .photo, data: dng, options: options) }
        } catch {
            // The developed photo is already saved; losing the negative shouldn't read as a failed shot.
            let ns = error as NSError
            log.error("RAW save failed: \(ns.domain, privacy: .public) \(ns.code)")
        }
    }

    private static func create(_ build: @escaping (PHAssetCreationRequest) -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            build(PHAssetCreationRequest.forAsset())
        }
    }
}
