import Photos
import PhotosUI
import SwiftUI

/// Every RAW Printlight can see, newest first, as a contact sheet: 3:4 cells, 2 pt gutters,
/// grouped by day. Tap to develop in the Editor.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var library: ShotLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Filter: String, CaseIterable {
        case all = "All", printlight = "Printlight", other = "Other RAW"
    }

    @State private var filter: Filter = .all
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var editing: Shot?
    @State private var openingID: String?
    @State private var openTask: Task<Void, Never>?
    @State private var selectionTicks = 0

    /// The library is owned by AppModel; observed here directly so the grid updates.
    init(library: ShotLibrary) {
        _library = ObservedObject(wrappedValue: library)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    /// A capture that's still being developed and saved, shown first.
    private var pending: Shot? {
        guard let shot = model.lastShot, shot.assetID == nil, model.developingCount > 0 else { return nil }
        return shot
    }

    private func isOther(_ asset: PHAsset) -> Bool { !library.ownIDs.contains(asset.localIdentifier) }

    private var visible: [PHAsset] {
        switch filter {
        case .all: library.assets
        case .printlight: library.assets.filter { !isOther($0) }
        case .other: library.assets.filter(isOther)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            content
        }
        .background(DS.Color.black.ignoresSafeArea())
        .foregroundStyle(DS.Color.label)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            if selecting { selectionToolbar }
            else if openingID != nil, let progress = model.openingProgress, progress > 0, progress < 1 {
                downloadCard(progress)
            }
        }
        .dsToast(text: $model.message, isError: model.messageIsError, top: 52)
        .sensoryFeedback(.selection, trigger: selectionTicks)
        .fullScreenCover(item: $editing) { shot in
            EditorView(shot: shot).environmentObject(model)
        }
        .onAppear { library.refresh() }
    }

    // MARK: Navigation

    private var navRow: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                    Text("Camera").ds(.body)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: DS.touch)
            }
            .buttonStyle(DSPlainButtonStyle())
            .accessibilityLabel("Back to camera")
            Spacer()
            if library.availability == .available && !library.assets.isEmpty {
                Button(selecting ? "Cancel" : "Select") {
                    withAnimation(DS.Motion.sheet) {
                        selecting.toggle()
                        selection.removeAll()
                    }
                }
                .ds(.headline)
                .padding(.horizontal, 8)
                .frame(minHeight: DS.touch)
                .buttonStyle(DSPlainButtonStyle())
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch library.availability {
        case .unavailable:
            stateView(icon: "photo", title: "Allow photo access to see your shots",
                      body: "Your shots still save to Photos, but Printlight can’t list them here.",
                      note: "Limited access is enough.", button: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .unknown:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    largeTitle
                    HStack {
                        Text("Loading photos").ds(.headline)
                        Spacer()
                        DSSpinner(size: 14, lineWidth: 2)
                    }
                    .padding(.horizontal, DS.margin)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(0..<16, id: \.self) { _ in
                            DS.Color.surface2.aspectRatio(3 / 4, contentMode: .fit)
                        }
                    }
                }
            }
        case .available where library.assets.isEmpty && pending == nil:
            stateView(icon: "photo", title: "No RAW photos yet",
                      body: "Shots you take with Printlight appear here, with RAW photos from other apps.",
                      note: nil, button: "Take a photo") { dismiss() }
        case .available:
            grid
        }
    }

    private var largeTitle: some View {
        Text("Library")
            .ds(.largeTitle)
            .padding(.horizontal, DS.margin)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                largeTitle
                filterControl
                if library.isLimited { limitedBanner }
                ForEach(sections, id: \.title) { section in
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.title).ds(.headline)
                        Spacer()
                        Text("\(section.count) \(section.count == 1 ? "photo" : "photos")")
                            .ds(.footnote)
                            .foregroundStyle(DS.Color.label2)
                    }
                    .padding(.horizontal, DS.margin)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 2) {
                        if section.includesPending, let pending { pendingCell(pending) }
                        ForEach(section.assets, id: \.localIdentifier) { asset in cell(asset) }
                    }
                }
                footer
            }
            .padding(.bottom, selecting ? 80 : 24)
        }
    }

    private var filterControl: some View {
        HStack(spacing: 0) {
            ForEach(Filter.allCases, id: \.self) { option in
                Button {
                    guard filter != option else { return }
                    filter = option
                    selectionTicks += 1
                } label: {
                    Text(option.rawValue)
                        .ds(.chip)
                        .foregroundStyle(filter == option ? Color.white : DS.Color.label2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(filter == option ? DS.Color.surface3 : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Color.surface2))
        .padding(.horizontal, DS.margin)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }

    private var limitedBanner: some View {
        HStack(spacing: 12) {
            Text("Printlight can see its own shots and the photos you chose.")
                .ds(.footnote)
                .foregroundStyle(DS.Color.label2)
            Spacer(minLength: 0)
            Button("Add photos") {
                guard let presenter = Self.topViewController() else { return }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { _ in
                    Task { @MainActor in library.refresh() }
                }
            }
            .ds(.subheadline)
            .fontWeight(.semibold)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(DS.Color.surface3))
            .buttonStyle(DSPlainButtonStyle())
        }
        .padding(.horizontal, DS.rowPadding)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: DS.radiusGroup, style: .continuous).fill(DS.Color.surface2))
        .padding(.horizontal, DS.margin)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        let others = visible.filter(isOther).count
        return VStack(spacing: 2) {
            Text("\(visible.count) \(visible.count == 1 ? "Photo" : "Photos")").ds(.subheadline).fontWeight(.semibold)
            if others > 0 {
                Text("\(others) RAW \(others == 1 ? "photo" : "photos") from other apps")
                    .ds(.footnote)
                    .foregroundStyle(DS.Color.label2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sections

    private struct Section {
        let title: String
        var assets: [PHAsset]
        var includesPending: Bool
        var count: Int { assets.count + (includesPending ? 1 : 0) }
    }

    private var sections: [Section] {
        var result: [Section] = []
        let calendar = Calendar.current
        if pending != nil, filter != .other {
            result.append(Section(title: "Today", assets: [], includesPending: true))
        }
        for asset in visible {
            let title = Self.dayTitle(asset.creationDate, calendar: calendar)
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].assets.append(asset)
            } else {
                result.append(Section(title: title, assets: [asset], includesPending: false))
            }
        }
        return result
    }

    static func dayTitle(_ date: Date?, calendar: Calendar = .current) -> String {
        guard let date else { return "Undated" }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: Cells

    private func pendingCell(_ shot: Shot) -> some View {
        Button { editing = shot } label: {
            DS.Color.surface2
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { Image(uiImage: shot.thumbnail).resizable().scaledToFill() }
                .clipped()
                .overlay { progressOverlay(label: "Developing", progress: nil) }
        }
        .buttonStyle(DSPlainButtonStyle())
        .accessibilityLabel("Developing")
    }

    private func cell(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        let selected = selection.contains(id)
        let other = isOther(asset)
        return Button { tap(asset) } label: {
            DS.Color.surface2
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    AssetThumbnail(asset: asset, manager: library.imageManager)
                        .opacity(selected ? 0.62 : 1)
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if other {
                        Text("RAW")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.2)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6)))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        ZStack {
                            Circle().fill(selected ? Color.white : Color.clear)
                            Circle().strokeBorder(Color.white, lineWidth: 1.5)
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .padding(5)
                    }
                }
                .overlay {
                    if openingID == id {
                        let progress = model.openingProgress
                        progressOverlay(label: progress.map { $0 > 0 && $0 < 1 ? "\(Int($0 * 100))%" : "Opening" } ?? "Opening",
                                        progress: progress.flatMap { $0 > 0 && $0 < 1 ? $0 : nil })
                    }
                }
        }
        .buttonStyle(DSPlainButtonStyle())
        .accessibilityLabel(cellLabel(asset, other: other))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cellLabel(_ asset: PHAsset, other: Bool) -> String {
        let when = asset.creationDate.map {
            "\(Self.dayTitle($0).lowercased()) at \($0.formatted(date: .omitted, time: .shortened))"
        } ?? ""
        return other ? "RAW from another app, \(when)" : "Photo, \(when)"
    }

    private func progressOverlay(label: String, progress: Double?) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 6) {
                if let progress {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: progress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 30, height: 30)
                } else {
                    DSSpinner(size: 18, lineWidth: 2)
                }
                Text(label).font(.system(size: 11, weight: .semibold))
            }
        }
    }

    private func tap(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selecting {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionTicks += 1
            return
        }
        guard openingID == nil else { return }
        openingID = id
        openTask = Task {
            let shot = await model.open(asset)
            guard !Task.isCancelled else { return }
            openingID = nil
            if let shot { editing = shot }
        }
    }

    // MARK: Bottom bars

    private var selectionToolbar: some View {
        HStack {
            Text(selection.isEmpty ? "Select photos"
                 : "\(selection.count) \(selection.count == 1 ? "Photo" : "Photos") Selected")
                .ds(.subheadline)
                .fontWeight(.semibold)
                .padding(.leading, 12)
            Spacer()
            Button {
                let ids = selection
                Task {
                    do {
                        try await library.delete(ids)
                        withAnimation(DS.Motion.sheet) {
                            selection.removeAll()
                            selecting = false
                        }
                    } catch {
                        // Cancelling Photos' own confirmation lands here; nothing to report.
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 19))
                    .foregroundStyle(selection.isEmpty ? DS.Color.label3 : DS.Color.red)
                    .frame(width: DS.touch, height: DS.touch)
            }
            .buttonStyle(DSPlainButtonStyle())
            .disabled(selection.isEmpty)
            .accessibilityLabel("Delete selected photos")
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0x1C / 255).opacity(0.92).background(.ultraThinMaterial).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.separator).frame(height: 1 / 3) }
        .transition(.move(edge: .bottom))
    }

    private func downloadCard(_ progress: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 19))
            VStack(alignment: .leading, spacing: 0) {
                Text("Downloading from iCloud").ds(.subheadlineMedium)
                Text("\(Int(progress * 100))%").ds(.footnote).foregroundStyle(DS.Color.label2).monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Color.surface3)
                        Capsule().fill(Color.white).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 4)
                .padding(.top, 7)
            }
            Button("Cancel") {
                openTask?.cancel()
                openTask = nil
                openingID = nil
            }
            .ds(.subheadline)
            .foregroundStyle(DS.Color.accent)
            .padding(.horizontal, 4)
            .frame(minHeight: DS.touch)
            .buttonStyle(DSPlainButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlayMaterial(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, DS.margin)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: States

    private func stateView(icon: String, title: String, body: String, note: String?, button: String,
                           action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            largeTitle
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(DS.Color.label2)
                Text(title).ds(.title3).padding(.top, 6)
                Text(body).ds(.subheadline).foregroundStyle(DS.Color.label2)
                if let note { Text(note).ds(.footnote).foregroundStyle(DS.Color.label2).padding(.top, 2) }
                Button(button, action: action)
                    .buttonStyle(DSCapsuleButtonStyle())
                    .padding(.top, 10)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// A grid thumbnail from Photos (shows the photo as it looks there), centre-cropped to fill the
/// 3:4 cell whatever its orientation, so horizontal shots sit in the grid like vertical ones.
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
                    DS.Color.surface2
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: asset.localIdentifier) {
                let side = max(geo.size.width, geo.size.height) * displayScale
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
