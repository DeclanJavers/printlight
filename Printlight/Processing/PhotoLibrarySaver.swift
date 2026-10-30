import Photos
import UniformTypeIdentifiers
import os

/// Printlight's photos live in the user's library, not in the app. Each shot is one Photos asset:
/// the DNG is the original, and the developed HEIC is a non-destructive edit carrying the look
/// settings as adjustment data. Photos shows the developed image, "Revert" returns to the RAW,
/// and Printlight reads the RAW and its settings back to re-edit.
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAuthorized
        case notFound
        case noRAW
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Printlight needs permission to add photos. Turn it on in Settings > Printlight > Photos."
            case .notFound: "That photo is no longer in your library."
            case .noRAW: "That photo has no RAW original to develop."
            }
        }
    }

    enum Access: Equatable {
        /// Can save and read back its own photos (full or limited library access).
        case readWrite
        /// Can save, but not read back: no library.
        case addOnly
        case denied
    }

    /// Identifies Printlight's edits in Photos' adjustment data.
    static let adjustmentFormat = "com.declanjavers.printlight.look"
    static let adjustmentVersion = "1"

    private static let log = Logger(subsystem: "com.declanjavers.printlight", category: "library")

    /// Read/write is preferred (Limited is enough: photos an app creates are visible to it).
    /// If that's refused, saving alone still works.
    static func requestAccess() async -> Access {
        switch await PHPhotoLibrary.requestAuthorization(for: .readWrite) {
        case .authorized, .limited:
            return .readWrite
        default:
            let addOnly = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return addOnly == .authorized || addOnly == .limited ? .addOnly : .denied
        }
    }

    /// Saves a new shot. Returns the asset's local identifier when it was saved as one edited
    /// RAW asset; nil when Photos refused that and it fell back to two separate photos.
    static func save(heic: Data, dng: Data, params: LookParameters) async throws -> String? {
        guard await requestAccess() != .denied else { throw SaveError.notAuthorized }

        do {
            let assetID = try await saveEdited(heic: heic, dng: dng, params: params)
            await addToAlbum(assetID)
            return assetID
        } catch {
            let ns = error as NSError
            log.error("Edited save refused: \(ns.domain, privacy: .public) \(ns.code); saving two photos")
        }

        try await create { $0.addResource(with: .photo, data: heic, options: nil) }
        do {
            try await create { $0.addResource(with: .photo, data: dng, options: rawOptions()) }
        } catch {
            // The developed photo is already saved; losing the negative shouldn't read as a failed shot.
            let ns = error as NSError
            log.error("RAW save failed: \(ns.domain, privacy: .public) \(ns.code)")
        }
        return nil
    }

    private static func saveEdited(heic: Data, dng: Data, params: LookParameters) async throws -> String {
        let settings = try JSONEncoder().encode(params)
        var identifier: String?
        var writeError: Error?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: dng, options: rawOptions())
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            let output = PHContentEditingOutput(placeholderForCreatedAsset: placeholder)
            do {
                try fill(output, heic: heic, settings: settings)
                request.contentEditingOutput = output
                identifier = placeholder.localIdentifier
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        guard let identifier else { throw CocoaError(.fileWriteUnknown) }
        return identifier
    }

    /// Puts a shot in the "Printlight" album, creating the album the first time. Best effort:
    /// the shot is already saved, so failures (e.g. add-only access) are only logged.
    private static func addToAlbum(_ assetID: String) async {
        let albumTitle = "Printlight"
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var album: PHAssetCollection?
        albums.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == albumTitle {
                album = collection
                stop.pointee = true
            }
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request: PHAssetCollectionChangeRequest?
                if let album {
                    request = PHAssetCollectionChangeRequest(for: album)
                } else {
                    request = .creationRequestForAssetCollection(withTitle: albumTitle)
                }
                request?.addAssets(assets)
            }
        } catch {
            let ns = error as NSError
            log.error("Album add failed: \(ns.domain, privacy: .public) \(ns.code)")
        }
    }

    /// Replaces the edit on an existing shot: same photo, new look. The RAW original is untouched.
    static func updateEdit(assetID: String, heic: Data, params: LookParameters) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw SaveError.notFound
        }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // Building on the original rather than on our previous render.
        options.canHandleAdjustmentData = { $0.formatIdentifier == adjustmentFormat }
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in continuation.resume(returning: input) }
        }
        guard let input else { throw SaveError.notFound }
        let output = PHContentEditingOutput(contentEditingInput: input)
        try fill(output, heic: heic, settings: try JSONEncoder().encode(params))
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    private static func fill(_ output: PHContentEditingOutput, heic: Data, settings: Data) throws {
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: adjustmentFormat, formatVersion: adjustmentVersion, data: settings
        )
        let url = output.supportedRenderedContentTypes.contains(.heic)
            ? try output.renderedContentURL(for: .heic)
            : output.renderedContentURL
        try heic.write(to: url)
    }

    /// The RAW original and the Printlight settings of a saved shot. Downloads from iCloud if
    /// needed, reporting progress from 0 to 1.
    static func loadNegative(
        assetID: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (dng: Data, params: LookParameters?) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw SaveError.notFound
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let raw = resources.first(where: { resource in
            (resource.type == .photo || resource.type == .alternatePhoto)
                && (UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false)
        }) else { throw SaveError.noRAW }

        let dng = try await data(for: raw, progress: progress)
        var params: LookParameters?
        if let adjustment = resources.first(where: { $0.type == .adjustmentData }),
           let plist = try? await data(for: adjustment, progress: { _ in }) {
            params = settings(fromAdjustmentPlist: plist)
        }
        return (dng, params)
    }

    /// Photos stores adjustment data as a property list around our JSON; find the JSON in it
    /// without depending on Photos' key names.
    private static func settings(fromAdjustmentPlist plist: Data) -> LookParameters? {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) else { return nil }
        func search(_ value: Any) -> LookParameters? {
            if let data = value as? Data { return try? JSONDecoder().decode(LookParameters.self, from: data) }
            if let dict = value as? [String: Any] { return dict.values.lazy.compactMap(search).first }
            if let array = value as? [Any] { return array.lazy.compactMap(search).first }
            return nil
        }
        return search(object)
    }

    private static func data(for resource: PHAssetResource, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress($0) }
        let collected = OSAllocatedUnfairLock(initialState: Data())
        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                collected.withLock { $0.append(chunk) }
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: collected.withLock { $0 })
                }
            }
        }
    }

    private static func rawOptions() -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = "com.adobe.raw-image"
        return options
    }

    private static func create(_ build: @escaping (PHAssetCreationRequest) -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            build(PHAssetCreationRequest.forAsset())
        }
    }
}
