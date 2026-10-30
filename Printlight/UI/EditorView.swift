import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Re-develops one shot. The photo fills most of the screen; below it, one tool at a time:
/// pick a tool from the row, adjust its single full-width control. Save updates the same photo
/// in Photos (the RAW original is never touched, and Photos can always revert).
struct EditorView: View {
    let shot: Shot
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var params: LookParameters
    /// The settings as last saved; the edit is dirty when `params` differs.
    @State private var saved: LookParameters
    @State private var savedOnce = false
    @StateObject private var renderer = EditorRenderer()
    @StateObject private var swatches = FilmSwatches()
    @State private var tool: EditorTool = .film
    @State private var saving = false
    @State private var confirmingLeave = false
    @State private var importingLUT = false
    @State private var toolTicks = 0
    @State private var resets = 0
    @State private var successes = 0

    init(shot: Shot) {
        self.shot = shot
        _params = State(initialValue: shot.params)
        _saved = State(initialValue: shot.params)
    }

    private var dirty: Bool { params != saved }
    private var ready: Bool { renderer.isLoaded && !saving }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            saveProgress
            photo
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            controls
                .opacity(ready ? 1 : 0.4)
                .allowsHitTesting(ready)
        }
        .background(DS.Color.black.ignoresSafeArea())
        .foregroundStyle(DS.Color.label)
        .environment(\.colorScheme, .dark)
        .dsToast(text: $model.message, isError: model.messageIsError, top: 52)
        .sensoryFeedback(.selection, trigger: toolTicks)
        .sensoryFeedback(.selection, trigger: params.film)
        .sensoryFeedback(.impact(weight: .light), trigger: resets)
        .sensoryFeedback(.success, trigger: successes)
        .confirmationDialog("Save your changes to this photo?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Save to Photos") { save(thenLeave: true) }
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Leaving now keeps the photo as it was.")
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .data]) { result in
            do {
                params.customLUT = try CustomLUTLibrary.shared.importLUT(from: result.get())
                params.customLUTStrength = 1
                successes += 1
            } catch {
                model.show(error.localizedDescription, error: true)
            }
        }
        .task { await renderer.load(shot.dng, params: params) }
        .onChange(of: params) { _, new in renderer.request(new) }
        .task(id: SwatchKey(params: params, loaded: renderer.isLoaded)) {
            // Film cards follow the other settings, debounced so slider drags don't queue renders.
            guard renderer.isLoaded, let scene = renderer.scene else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            swatches.update(source: scene, displayReferred: false, params: params)
        }
    }

    private struct SwatchKey: Equatable {
        var params: LookParameters
        var loaded: Bool
    }

    // MARK: Top bar

    private var title: String {
        guard let date = shot.date else { return "Photo" }
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "Today"
            : calendar.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.day().month(.wide))
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var subtitle: (String, Bool) {
        if dirty { return ("Unsaved changes", true) }
        if !shot.hasPrintlightSettings && !savedOnce { return ("RAW from another app", false) }
        return (FilmLibrary.shared.film(id: params.film).name, false)
    }

    private var navRow: some View {
        HStack(spacing: 4) {
            Button("Done") {
                guard !saving else { return }
                if dirty { confirmingLeave = true } else { dismiss() }
            }
            .ds(.headline)
            .padding(.horizontal, 8)
            .frame(minHeight: DS.touch)
            .buttonStyle(DSPlainButtonStyle())

            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Text(title).ds(.headline).lineLimit(1)
                Text(subtitle.0)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(subtitle.1 ? DS.Color.accent : DS.Color.label2)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)

            Menu {
                Button {
                    model.params = params
                    successes += 1
                    model.show("Now the default for new shots")
                } label: {
                    Label(params == model.params ? "This is your default" : "Use as default for new shots",
                          systemImage: params == model.params ? "checkmark" : "camera")
                }
                .disabled(params == model.params)
                Button(role: .destructive) {
                    withAnimation(DS.Motion.value) { params = .standard }
                    resets += 1
                } label: {
                    Label("Reset all to Standard", systemImage: "arrow.uturn.backward")
                }
                .disabled(params == .standard)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DS.Color.surface2))
                    .frame(width: DS.touch, height: DS.touch)
            }
            .accessibilityLabel("More")

            Button { save(thenLeave: false) } label: {
                HStack(spacing: 8) {
                    if saving { DSSpinner(size: 14, lineWidth: 2, color: .black) }
                    Text(saving ? "Saving" : "Save").ds(.subheadline).fontWeight(.semibold)
                }
                .foregroundStyle(saving || (dirty && ready) ? Color.black : DS.Color.label3)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Capsule().fill(saving || (dirty && ready) ? Color.white : DS.Color.surface2))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(DSPlainButtonStyle())
            .disabled(!dirty || !ready)
            .padding(.trailing, 8)
            .accessibilityLabel(saving ? "Saving" : "Save")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    /// Amber 2 pt line under the bar while saving. The develop has no measurable progress, so it
    /// sweeps steadily rather than pretending to a percentage.
    private var saveProgress: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(DS.Color.accent)
                .frame(width: saving ? geo.size.width * 0.9 : 0, height: 2)
                .animation(saving ? .easeOut(duration: 4) : .easeOut(duration: 0.2), value: saving)
        }
        .frame(height: 2)
        .opacity(saving ? 1 : 0)
    }

    // MARK: Photo

    private var photo: some View {
        ZStack {
            Image(uiImage: renderer.image ?? shot.thumbnail)
                .resizable()
                .scaledToFit()
                .opacity(renderer.isLoaded ? 1 : 0.35)
                .accessibilityLabel("Photo")
            if !renderer.isLoaded {
                VStack(spacing: 12) {
                    DSSpinner()
                    Text("Preparing RAW…").ds(.subheadline).foregroundStyle(DS.Color.label2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            toolControl
                .frame(height: 132)
                .padding(.horizontal, DS.margin)
            toolRow
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .background(DS.Color.surface1.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.separator).frame(height: 1 / 3) }
    }

    @ViewBuilder
    private var toolControl: some View {
        switch tool {
        case .film: filmStrip
        case .lut: lutControl
        case .setting(let setting): sliderControl(setting)
        }
    }

    private func sliderControl(_ setting: LookSetting) -> some View {
        let value = params[keyPath: setting.keyPath]
        let changed = !setting.isDefault(value)
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(setting.title).ds(.headline)
                    if let subtitle = setting.subtitle {
                        Text(subtitle).ds(.caption1).foregroundStyle(DS.Color.label2)
                    }
                }
                Spacer()
                Text(setting.format(value))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(changed ? DS.Color.accent : DS.Color.label)
                    .contentTransition(.numericText())
                Button {
                    withAnimation(DS.Motion.value) { params[keyPath: setting.keyPath] = setting.defaultValue }
                    resets += 1
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.label2)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.Color.surface3))
                        .frame(width: DS.touch, height: DS.touch)
                }
                .buttonStyle(DSPlainButtonStyle())
                .opacity(changed ? 1 : 0)
                .disabled(!changed)
                .accessibilityLabel("Reset \(setting.title) to default")
            }
            .padding(.top, 10)
            DSSlider(
                value: Binding(get: { params[keyPath: setting.keyPath] }, set: { params[keyPath: setting.keyPath] = $0 }),
                range: setting.range, step: setting.step, defaultValue: setting.defaultValue,
                label: setting.title, valueText: setting.format
            )
            .frame(height: 44)
            .onTapGesture(count: 2) {
                withAnimation(DS.Motion.snap) { params[keyPath: setting.keyPath] = setting.defaultValue }
                resets += 1
            }
            HStack {
                Text(setting.ends?.0 ?? DSFormat.fixed(setting.range.lowerBound, decimals: setting.step < 0.01 ? 3 : 1))
                Spacer()
                Text(setting.ends?.1 ?? DSFormat.fixed(setting.range.upperBound, decimals: setting.step < 0.01 ? 3 : 1))
            }
            .ds(.caption2)
            .foregroundStyle(DS.Color.label3)
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
    }

    private var filmStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(FilmLibrary.shared.films) { film in
                        let selected = params.film == film.id
                        Button { params.film = film.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    Group {
                                        if let image = swatches.images[film.id] {
                                            Image(uiImage: image).resizable().scaledToFill()
                                        } else {
                                            DS.Color.surface2
                                        }
                                    }
                                    .frame(width: 112, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusSwatch, style: .continuous))
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .heavy))
                                            .foregroundStyle(.black)
                                            .frame(width: 20, height: 20)
                                            .background(Circle().fill(DS.Color.accent))
                                            .padding(5)
                                    }
                                }
                                .padding(3)
                                .overlay(RoundedRectangle(cornerRadius: DS.radiusSwatch + 3, style: .continuous)
                                    .strokeBorder(selected ? DS.Color.accent : .clear, lineWidth: 2))
                                .padding(-3)
                                Text(film.name)
                                    .ds(.chip)
                                    .foregroundStyle(selected ? DS.Color.accent : DS.Color.label)
                                    .lineLimit(1)
                            }
                            .frame(width: 112)
                        }
                        .buttonStyle(DSPlainButtonStyle())
                        .id(film.id)
                        .accessibilityLabel(film.name)
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -DS.margin + 4)
            .onAppear { proxy.scrollTo(params.film, anchor: .center) }
        }
    }

    private var lutControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = params.customLUT {
                HStack(spacing: 10) {
                    Image(systemName: "cube").font(.system(size: 16))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.surface3))
                    Text(name).ds(.subheadlineMedium).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Replace") { importingLUT = true }.foregroundStyle(DS.Color.accent)
                    Button("Remove") {
                        params.customLUT = nil
                        params.customLUTStrength = 1
                        resets += 1
                    }
                    .foregroundStyle(DS.Color.red)
                }
                .ds(.subheadline)
                .buttonStyle(DSPlainButtonStyle())
                .padding(.top, 12)
                DSSlider(
                    value: $params.customLUTStrength, range: 0...1, step: 0.01, defaultValue: 1,
                    label: "LUT strength", valueText: { DSFormat.fixed($0, decimals: 2) }
                )
                .frame(height: 44)
                Text("Strength \(DSFormat.fixed(params.customLUTStrength, decimals: 2))")
                    .ds(.caption1).foregroundStyle(DS.Color.label2).monospacedDigit()
            } else {
                Spacer(minLength: 0)
                Button { importingLUT = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 17))
                        Text("Import .cube file").ds(.headline)
                    }
                    .foregroundStyle(DS.Color.accent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Color.surface2))
                }
                .buttonStyle(DSPlainButtonStyle())
                Text("Standard Rec.709 look LUTs, applied on top of the film.")
                    .ds(.footnote).foregroundStyle(DS.Color.label2)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
    }

    private var toolRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(EditorTool.all) { item in
                        let selected = item == tool
                        let changed = item.isChanged(params)
                        Button {
                            guard !selected else { return }
                            tool = item
                            toolTicks += 1
                            withAnimation(DS.Motion.value) { proxy.scrollTo(item.id, anchor: .center) }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(selected ? Color.black : DS.Color.label)
                                    .frame(width: 46, height: 46)
                                    .background(Circle().fill(selected ? DS.Color.accent : DS.Color.surface2))
                                    .overlay(alignment: .topTrailing) {
                                        if changed && !selected {
                                            Circle().fill(DS.Color.accent).frame(width: 8, height: 8)
                                                .overlay(Circle().stroke(DS.Color.surface1, lineWidth: 2))
                                        }
                                    }
                                Text(item.title)
                                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? DS.Color.accent : DS.Color.label2)
                                    .lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(DSPlainButtonStyle())
                        .id(item.id)
                        .accessibilityLabel(item.title + (changed ? ", changed" : ""))
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Saving

    private func save(thenLeave: Bool) {
        guard !saving else { return }
        let snapshot = params
        saving = true
        Task {
            let ok = await model.saveEdit(of: shot, params: snapshot)
            saving = false
            if ok {
                saved = snapshot
                savedOnce = true
                if thenLeave { dismiss() }
            }
        }
    }
}

/// The editor's tools, one shown at a time.
private enum EditorTool: Identifiable, Equatable {
    case film
    case setting(LookSetting)
    case lut

    static var all: [EditorTool] {
        [.film] + LookSetting.all.map { .setting($0) } + [.lut]
    }

    var id: String {
        switch self {
        case .film: "film"
        case .setting(let setting): setting.id
        case .lut: "lut"
        }
    }

    var title: String {
        switch self {
        case .film: "Film"
        case .setting(let setting): setting.title == "Halation threshold" ? "Threshold" : setting.title
        case .lut: "LUT"
        }
    }

    var symbol: String {
        switch self {
        case .film: "film"
        case .lut: "cube"
        case .setting(let setting):
            switch setting.title {
            case "Exposure": "plusminus.circle"
            case "Black lift": "circle.lefthalf.filled"
            case "Warmth": "thermometer.medium"
            case "Tint": "drop"
            case "Clarity": "triangle.lefthalf.filled"
            case "Halation": "sun.max"
            case "Halation threshold": "sun.horizon"
            case "Grain": "circle.dotted"
            default: "slider.horizontal.3"
            }
        }
    }

    func isChanged(_ params: LookParameters) -> Bool {
        switch self {
        case .film: params.film != LookParameters.standard.film
        case .lut: params.customLUT != nil
        case .setting(let setting): !setting.isDefault(params[keyPath: setting.keyPath])
        }
    }

    static func == (lhs: EditorTool, rhs: EditorTool) -> Bool { lhs.id == rhs.id }
}

/// Renders the editor preview. Decodes the negative once at screen size, then keeps at most one
/// look render in flight: slider moves only replace the pending settings, and each finished
/// render immediately starts on the newest ones. (Unbounded per-tick renders used to pile up on
/// the GPU, freezing the preview and starving the full-resolution save.)
@MainActor
final class EditorRenderer: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoaded = false

    /// The decoded scene-linear negative; also the source for the film-card swatches.
    private(set) var scene: CIImage?
    private var pending: LookParameters?
    private var rendering = false

    func load(_ dng: Data, params: LookParameters) async {
        // 0.2 of a 48MP frame is about 1600px on the long side: screen size, and small enough
        // for the decode to double as the exposure-match reference.
        scene = await Task.detached(priority: .userInitiated) {
            RawDeveloper.sceneLinear(from: dng, scale: 0.2)
        }.value
        request(params)
    }

    func request(_ params: LookParameters) {
        pending = params
        pump()
    }

    private func pump() {
        guard !rendering, let scene, let params = pending else { return }
        pending = nil
        rendering = true
        Task.detached(priority: .userInitiated) {
            let image = RawDeveloper.uiImage(from: FilmLook.shared.render(sceneLinear: scene, params: params))
            await MainActor.run {
                if let image { self.image = image }
                // Shown once the first develop exists, so the photo never flashes the thumbnail.
                self.isLoaded = true
                self.rendering = false
                self.pump()
            }
        }
    }
}
