import Photos
import UIKit

/// Every RAW photo in the user's library that Printlight can see: its own shots plus Photos' RAW
/// album (ProRAW from the Camera app, other apps' RAWs, older Printlight negatives). The app stores
/// nothing but the identifiers of its own shots; images and settings stay in Photos.
@MainActor
final class ShotLibrary: NSObject, ObservableObject {
    enum Availability: Equatable {
        case unknown
        case available
        /// Photos access is add-only or denied: shots are saved, but can't be read back.
        case unavailable
    }

    /// Newest first.
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var availability: Availability = .unknown
    /// Limited access: only photos the user picked (plus Printlight's own) are visible.
    @Published private(set) var isLimited = false

    let imageManager = PHCachingImageManager()
    private let indexKey = "printlight.library.assetIDs"

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        refresh()
    }

    private var index: [String] {
        get { UserDefaults.standard.stringArray(forKey: indexKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: indexKey) }
    }

    func add(_ assetID: String) {
        if !index.contains(assetID) { index.append(assetID) }
        refresh()
    }

    /// Re-reads the library. Printlight shots deleted in Photos drop out of the index.
    func refresh() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        isLimited = status == .limited
        guard status == .authorized || status == .limited else {
            availability = status == .notDetermined ? .unknown : .unavailable
            assets = []
            return
        }
        availability = .available

        var byID: [String: PHAsset] = [:]
        let ids = index
        if !ids.isEmpty {
            var existing = Set<String>()
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                byID[asset.localIdentifier] = asset
                existing.insert(asset.localIdentifier)
            }
            if existing.count != ids.count { index = ids.filter(existing.contains) }
        }
        let ownCount = byID.count
        var albumCount = -1
        if let rawAlbum = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumRAW, options: nil).firstObject {
            let inAlbum = PHAsset.fetchAssets(in: rawAlbum, options: nil)
            albumCount = inAlbum.count
            inAlbum.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        }
        assets = byID.values.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        print("PRINTLIGHT LIBRARY access \(status == .limited ? "limited" : "full"), own \(ownCount)/\(ids.count), RAW album \(albumCount < 0 ? "missing" : "\(albumCount)"), showing \(assets.count)")
    }


    /// Asks Photos to delete; Photos shows its own confirmation.
    func delete(_ ids: Set<String>) async throws {
        let targets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(targets)
        }
        refresh()
    }
}

extension ShotLibrary: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.refresh() }
    }
}
