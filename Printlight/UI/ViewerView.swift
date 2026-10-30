import Photos
import SwiftUI

/// Full-screen photo viewer: swipe left and right through the Library's photos, pinch or
/// double-tap to zoom, swipe down to close, Edit to develop the current shot. Shows each photo
/// as Photos stores it (Printlight's edit included), so paging is instant; only Edit loads the RAW.
struct ViewerView: View {
    let assets: [PHAsset]
    @ObservedObject var library: ShotLibrary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var index: Int
    @State private var chromeHidden = false
    @State private var dragDown: CGFloat = 0
    @State private var editing: Shot?
    @State private var opening = false
    @State private var zoomed = false
    @State private var pageTicks = 0

    init(assets: [PHAsset], startIndex: Int, library: ShotLibrary) {
        self.assets = assets
        self.library = library
        _index = State(initialValue: startIndex)
    }

    private var current: PHAsset? { assets.indices.contains(index) ? assets[index] : nil }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(dragDown / 400, 0.6))
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { i, asset in
                    ZoomablePhoto(asset: asset, manager: library.imageManager, isCurrent: i == index, zoomed: $zoomed) {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragDown)
            .scaleEffect(1 - min(dragDown / 2000, 0.15))
            .simultaneousGesture(dismissDrag)

            if !chromeHidden { topBar.transition(.opacity) }

            if opening, let progress = model.openingProgress {
                openingPill(progress).transition(.opacity)
            }
        }
        .foregroundStyle(DS.Color.label)
        .environment(\.colorScheme, .dark)
        .statusBarHidden(chromeHidden)
        .sensoryFeedback(.selection, trigger: pageTicks)
        .onChange(of: index) { _, _ in pageTicks += 1 }
        .dsToast(text: $model.message, isError: model.messageIsError, top: 52)
        .fullScreenCover(item: $editing) { shot in
            EditorView(shot: shot).environmentObject(model)
        }
        .onChange(of: library.assets) { _, new in
            // The current photo was deleted elsewhere: close rather than show a stale page.
            if let current, !new.contains(where: { $0.localIdentifier == current.localIdentifier }) { dismiss() }
        }
    }

    /// Swipe down to close, only when not zoomed and the drag is mostly vertical.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { drag in
                guard !zoomed, drag.translation.height > 0,
                      abs(drag.translation.height) > abs(drag.translation.width) * 1.4 else { return }
                dragDown = drag.translation.height
            }
            .onEnded { drag in
                guard dragDown > 0 else { return }
                if dragDown > 140 || drag.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? DS.Motion.reduced : .spring(response: 0.3, dampingFraction: 0.85)) { dragDown = 0 }
                }
            }
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack {
            HStack {
                Button("Done") { dismiss() }
                    .ds(.headline)
                    .padding(.horizontal, 8)
                    .frame(minHeight: DS.touch)
                    .buttonStyle(DSPlainButtonStyle())
                Spacer()
                Button { edit() } label: {
                    HStack(spacing: 6) {
                        if opening { DSSpinner(size: 14, lineWidth: 2, color: .black) }
                        Text(opening ? "Opening" : "Edit").ds(.subheadline).fontWeight(.semibold)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.white))
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DSPlainButtonStyle())
                .disabled(opening || current == nil)
                .padding(.trailing, 8)
                .accessibilityLabel("Edit this photo")
            }
            .overlay {
                if let current {
                    VStack(spacing: 0) {
                        Text(title(for: current)).ds(.headline)
                        Text(subtitle(for: current))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Color.label2)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 96)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -30)
                    .ignoresSafeArea(edges: .top)
            )
            Spacer()
        }
    }

    private func title(for asset: PHAsset) -> String {
        guard let date = asset.creationDate else { return "Photo" }
        let day = LibraryView.dayTitle(date)
        return "\(day == "Today" || day == "Yesterday" ? day : date.formatted(.dateTime.day().month(.wide))), \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func subtitle(for asset: PHAsset) -> String {
        let source = library.ownIDs.contains(asset.localIdentifier) ? "Printlight" : "RAW from another app"
        return "\(source) · \(index + 1) of \(assets.count)"
    }

    private func openingPill(_ progress: Double) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                if progress > 0 && progress < 1 {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 15))
                    Text("Downloading RAW \(Int(progress * 100))%").ds(.subheadline).monospacedDigit()
                } else {
                    DSSpinner(size: 16, lineWidth: 2)
                    Text("Opening RAW").ds(.subheadline)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlayMaterial(in: Capsule())
            .padding(.bottom, 24)
        }
    }

    private func edit() {
        guard let asset = current, !opening else { return }
        opening = true
        Task {
            let shot = await model.open(asset)
            opening = false
            if let shot { editing = shot }
        }
    }
}

/// One page: the photo fitted to the screen, pinch or double-tap to zoom, drag to pan when zoomed.
private struct ZoomablePhoto: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let isCurrent: Bool
    @Binding var zoomed: Bool
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var loadedLarge = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    DSSpinner()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(baseScale * value.magnification, 1), 6)
                        zoomed = scale > 1.01
                    }
                    .onEnded { _ in
                        baseScale = scale
                        if scale <= 1.01 { reset() } else { loadLargeIfNeeded(geo.size) }
                    }
            )
            // While zoomed, dragging pans the photo instead of paging.
            .highPriorityGesture(
                DragGesture()
                    .onChanged { drag in
                        offset = CGSize(width: baseOffset.width + drag.translation.width,
                                        height: baseOffset.height + drag.translation.height)
                    }
                    .onEnded { _ in baseOffset = clamped(offset, in: geo.size); withAnimation(.easeOut(duration: 0.2)) { offset = baseOffset } },
                including: scale > 1.01 ? .all : .subviews
            )
            .onTapGesture(count: 2) { location in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    if scale > 1.01 {
                        reset()
                    } else {
                        // Zoom 2.5x towards the tapped point.
                        scale = 2.5; baseScale = 2.5
                        let dx = (geo.size.width / 2 - location.x) * 1.5
                        let dy = (geo.size.height / 2 - location.y) * 1.5
                        offset = clamped(CGSize(width: dx, height: dy), in: geo.size)
                        baseOffset = offset
                        zoomed = true
                    }
                }
                if scale > 1.01 { loadLargeIfNeeded(geo.size) }
            }
            .onTapGesture(count: 1) { onTap() }
            .task(id: asset.localIdentifier + "\(asset.modificationDate?.timeIntervalSince1970 ?? 0)") {
                request(size: geo.size, factor: 1)
            }
            .onChange(of: isCurrent) { _, current in
                if !current { reset() }
            }
            .accessibilityElement()
            .accessibilityLabel("Photo")
            .accessibilityHint("Swipe left or right with three fingers for other photos.")
        }
    }

    private func reset() {
        scale = 1; baseScale = 1
        offset = .zero; baseOffset = .zero
        zoomed = false
    }

    /// Keeps the zoomed photo from being dragged entirely off screen.
    private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2, maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(value.width, -maxX), maxX), height: min(max(value.height, -maxY), maxY))
    }

    private func loadLargeIfNeeded(_ size: CGSize) {
        guard !loadedLarge else { return }
        loadedLarge = true
        request(size: size, factor: 3)
    }

    private func request(size: CGSize, factor: CGFloat) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let target = CGSize(width: size.width * displayScale * factor, height: size.height * displayScale * factor)
        manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { result, _ in
            if let result { image = result }
        }
    }
}
