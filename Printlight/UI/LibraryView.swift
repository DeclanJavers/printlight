import Photos
import PhotosUI
import SwiftUI

/// Every RAW photo Printlight can see in the user's library, newest first. Tap to develop.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var library: ShotLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var editing: Shot?

    /// The library is owned by AppModel; observed here directly so the grid updates.
    init(library: ShotLibrary) {
        _library = ObservedObject(wrappedValue: library)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    /// A capture that's still being developed and saved, shown first.
    private var pending: Shot? {
        guard let shot = model.lastShot, shot.assetID == nil, model.developingCount > 0 else { return nil }
        return shot
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if library.isLimited { limitedBanner }
            content
            if selecting { selectionBar }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .overlay { if let progress = model.openingProgress { openingOverlay(progress) } }
        .overlay(alignment: .top) {
            if let message = model.message {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.78)))
                    .padding(.top, 60)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        if model.message == message { model.message = nil }
                    }
            }
        }
        .fullScreenCover(item: $editing) { shot in
            EditorView(shot: shot)
        }
        .onAppear { library.refresh() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Text("DONE").readout(12, weight: .semibold).frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text("LIBRARY").readout(12, weight: .semibold)
                Text("\(library.assets.count) RAW").readout(9).foregroundStyle(Color.white.opacity(0.45))
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                withAnimation(.snappy) {
                    selecting.toggle()
                    selection.removeAll()
                }
            } label: {
                Text(selecting ? "CANCEL" : "SELECT").readout(12, weight: .semibold).frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(library.assets.isEmpty)
            .opacity(library.assets.isEmpty ? 0.35 : 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    @ViewBuilder
    private var content: some View {
        switch library.availability {
        case .unavailable:
            stateMessage(
                "PHOTOS ACCESS NEEDED",
                "Your shots are still saved to Photos. To browse and re-edit them here, allow Printlight to read its photos. Limited access is enough.",
                action: ("OPEN SETTINGS", { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } })
            )
        case .unknown where library.assets.isEmpty && pending == nil, .available where library.assets.isEmpty && pending == nil:
            stateMessage("NO RAW PHOTOS YET", "Photos you take with Printlight, and any other RAW photos in your library, appear here ready to develop.", action: nil)
        default:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    if let pending {
                        Button { editing = pending } label: {
                            cell { Image(uiImage: pending.thumbnail).resizable().scaledToFill() }
                                .overlay { Color.black.opacity(0.35); ProgressView().tint(.white) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Newest shot, still saving")
                    }
                    ForEach(library.assets, id: \.localIdentifier) { asset in
                        Button { tap(asset) } label: {
                            cell { AssetThumbnail(asset: asset, manager: library.imageManager) }
                                .overlay(alignment: .topTrailing) {
                                    if selecting { selectionMark(selection.contains(asset.localIdentifier)) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.creationDate.map { "Shot from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Shot")
                        .accessibilityAddTraits(selection.contains(asset.localIdentifier) ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// With Limited access, lets the user choose more photos for Printlight to see.
    private var limitedBanner: some View {
        HStack {
            Text("Showing Printlight shots and the photos you've allowed.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.55))
            Spacer()
            Button {
                guard let presenter = Self.topViewController() else { return }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { _ in
                    Task { @MainActor in library.refresh() }
                }
            } label: {
                Text("ADD PHOTOS")
                    .readout(10, weight: .semibold)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private func tap(_ asset: PHAsset) {
        if selecting {
            if selection.contains(asset.localIdentifier) {
                selection.remove(asset.localIdentifier)
            } else {
                selection.insert(asset.localIdentifier)
            }
        } else {
            Task { if let shot = await model.open(asset) { editing = shot } }
        }
    }

    private func cell<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Color.white.opacity(0.05)
            .aspectRatio(1, contentMode: .fit)
            .overlay { content() }
            .clipped()
            .contentShape(Rectangle())
    }

    private func selectionMark(_ selected: Bool) -> some View {
        ZStack {
            Circle().fill(selected ? Palette.accent : Color.black.opacity(0.35))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if selected {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
            }
        }
        .frame(width: 22, height: 22)
        .padding(6)
    }

    private var selectionBar: some View {
        HStack {
            Text(selection.isEmpty ? "SELECT SHOTS" : "\(selection.count) SELECTED")
                .readout(11)
                .foregroundStyle(Color.white.opacity(0.6))
            Spacer()
            Button {
                let ids = selection
                Task {
                    do {
                        try await library.delete(ids)
                        withAnimation(.snappy) {
                            selection.removeAll()
                            selecting = false
                        }
                    } catch {
                        // Cancelling Photos' confirmation lands here; nothing to report.
                    }
                }
            } label: {
                Text("DELETE")
                    .readout(11, weight: .bold)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.red.opacity(selection.isEmpty ? 0.3 : 0.85)))
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
        .background(Palette.panel.ignoresSafeArea(edges: .bottom))
    }

    private func stateMessage(_ title: String, _ body: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Text(title).readout(12, weight: .semibold)
            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action.1) {
                    Text(action.0)
                        .readout(11, weight: .semibold)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openingOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: progress)
                    .tint(Palette.accent)
                    .frame(width: 160)
                Text(progress > 0 && progress < 1 ? "DOWNLOADING RAW \(Int(progress * 100))%" : "OPENING RAW")
                    .readout(10, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
    }
}

/// A grid thumbnail from Photos (shows Printlight's developed edit).
private struct AssetThumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.05)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: asset.localIdentifier) {
                let side = geo.size.width * displayScale
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                     contentMode: .aspectFill, options: options) { result, _ in
                    if let result { image = result }
                }
            }
        }
    }
}
