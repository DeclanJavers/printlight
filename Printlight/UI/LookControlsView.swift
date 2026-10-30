import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// One adjustable setting in the Look panel.
struct LookSetting: Identifiable {
    let title: String
    var subtitle: String?
    let keyPath: WritableKeyPath<LookParameters, Double>
    let range: ClosedRange<Double>
    let step: Double
    var ends: (String, String)?
    let format: (Double) -> String

    var id: String { title }
    var defaultValue: Double { LookParameters.standard[keyPath: keyPath] }
    func isDefault(_ value: Double) -> Bool { abs(value - defaultValue) < 1e-9 }

    static let tone: [LookSetting] = [
        LookSetting(title: "Exposure", subtitle: "Brightens or darkens after capture", keyPath: \.exposure,
                    range: -3...3, step: 0.1, format: { DSFormat.signed($0, decimals: 1) + " stops" }),
        LookSetting(title: "Black lift", subtitle: "How deep the blacks go", keyPath: \.blackLift,
                    range: 0...0.04, step: 0.001, format: { DSFormat.fixed($0, decimals: 3) }),
    ]
    static let colour: [LookSetting] = [
        LookSetting(title: "Warmth", keyPath: \.warmth, range: -1...1, step: 0.01, ends: ("Cooler", "Warmer"),
                    format: { DSFormat.signed($0, decimals: 2) }),
        LookSetting(title: "Tint", keyPath: \.tint, range: -1...1, step: 0.01, ends: ("Green", "Magenta"),
                    format: { DSFormat.signed($0, decimals: 2) }),
    ]
    static let texture: [LookSetting] = [
        LookSetting(title: "Clarity", keyPath: \.clarity, range: 0...1, step: 0.01, format: { DSFormat.fixed($0, decimals: 2) }),
        LookSetting(title: "Halation", subtitle: "Red glow around bright lights", keyPath: \.halation,
                    range: 0...0.5, step: 0.01, format: { DSFormat.fixed($0, decimals: 2) }),
        LookSetting(title: "Halation threshold", subtitle: "How bright something must be to glow", keyPath: \.halationThreshold,
                    range: -1...3, step: 0.1, format: { DSFormat.signed($0, decimals: 1) + " stops" }),
        LookSetting(title: "Grain", keyPath: \.grain, range: 0...0.04, step: 0.001, format: { DSFormat.fixed($0, decimals: 3) }),
    ]
    static let lutStrength = LookSetting(title: "Strength", keyPath: \.customLUTStrength, range: 0...1, step: 0.01,
                                         format: { DSFormat.fixed($0, decimals: 2) })
    static let all = tone + colour + texture

    /// Settings that differ from Standard: the film, each changed slider, and a loaded LUT.
    static func changeCount(_ params: LookParameters) -> Int {
        (params.film == LookParameters.standard.film ? 0 : 1)
            + all.filter { !$0.isDefault(params[keyPath: $0.keyPath]) }.count
            + (params.customLUT == nil ? 0 : 1)
    }
}

/// The Look panel: film, development settings and a custom LUT. Hosted by the camera's sheet
/// (edits the default for new shots) and the Editor's bottom panel (edits one photo).
struct LookControlsView: View {
    enum Mode {
        case camera
        case editor(isDefault: Bool, useAsDefault: () -> Void)
    }

    @Binding var params: LookParameters
    let mode: Mode
    let swatchSource: () -> (CIImage, Bool)?
    var busy = false
    let onClose: () -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var swatches = FilmSwatches()
    @State private var importingLUT = false
    @State private var lutError: String?
    @State private var resetAllPulses = 0
    @State private var resetOnePulses = 0
    @State private var successPulses = 0

    init(params: Binding<LookParameters>, mode: Mode, swatchSource: @escaping () -> (CIImage, Bool)?,
         busy: Bool = false, onClose: @escaping () -> Void) {
        _params = params
        self.mode = mode
        self.swatchSource = swatchSource
        self.busy = busy
        self.onClose = onClose
    }

    private var isCamera: Bool { if case .camera = mode { true } else { false } }
    private var changes: Int { LookSetting.changeCount(params) }

    var body: some View {
        VStack(spacing: 0) {
            header
            summary
                .opacity(busy ? 0.4 : 1)
                .allowsHitTesting(!busy)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Film").padding(.top, 8)
                    filmCards
                    sectionHeader("Tone")
                    group(LookSetting.tone)
                    sectionHeader("Colour")
                    group(LookSetting.colour)
                    sectionHeader("Texture")
                    group(LookSetting.texture)
                    sectionHeader("Custom LUT")
                    lutGroup
                    Text("Use standard Rec.709 look LUTs, not camera log LUTs. Applied on top of the film.")
                        .ds(.footnote)
                        .foregroundStyle(DS.Color.label2)
                        .padding(.horizontal, 32)
                        .padding(.top, 6)
                    Text("Film data: spektrafilm profiles by Andrea Volpato, CC BY-SA 4.0.")
                        .ds(.caption1)
                        .foregroundStyle(DS.Color.label3)
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .opacity(busy ? 0.4 : 1)
            .allowsHitTesting(!busy)
            if case .editor(let isDefault, let useAsDefault) = mode {
                footer(isDefault: isDefault, useAsDefault: useAsDefault)
                    .opacity(busy ? 0.4 : 1)
                    .allowsHitTesting(!busy)
            }
        }
        .foregroundStyle(DS.Color.label)
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.impact(weight: .medium), trigger: resetAllPulses)
        .sensoryFeedback(.impact(weight: .light), trigger: resetOnePulses)
        .sensoryFeedback(.success, trigger: successPulses)
        .sensoryFeedback(.selection, trigger: params.film)
        .task(id: params) {
            // Debounced so dragging a slider doesn't queue a swatch render per tick. The source
            // may not exist yet (the editor's negative is still decoding, the camera has no frame
            // yet), so keep looking for a few seconds.
            try? await Task.sleep(for: .milliseconds(140))
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                if let (source, displayReferred) = swatchSource() {
                    swatches.update(source: source, displayReferred: displayReferred, params: params)
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .data]) { result in
            do {
                let name = try CustomLUTLibrary.shared.importLUT(from: result.get())
                lutError = nil
                params.customLUT = name
                params.customLUTStrength = 1
                successPulses += 1
            } catch {
                lutError = error.localizedDescription
                model.show(error.localizedDescription, error: true)
            }
        }
    }

    // MARK: Header and summary

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Look").ds(.title3Bold)
                Text(isCamera ? "Default for new shots" : "This photo only")
                    .ds(.footnote)
                    .foregroundStyle(DS.Color.label2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            if isCamera {
                Button("Done", action: onClose)
                    .ds(.headline)
                    .padding(.horizontal, 4)
                    .frame(minHeight: DS.touch)
                    .buttonStyle(DSPlainButtonStyle())
            } else {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.label2)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.Color.surface2))
                        .frame(width: DS.touch, height: DS.touch)
                }
                .buttonStyle(DSPlainButtonStyle())
                .accessibilityLabel("Hide controls")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isCamera ? 0 : 14)
        .padding(.bottom, 10)
    }

    private var summary: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(changes > 0 ? DS.Color.accent : DS.Color.label3).frame(width: 8, height: 8)
                Text(changes == 0 ? "Standard" : "\(changes) \(changes == 1 ? "change" : "changes")")
                    .ds(.subheadline)
                    .fontWeight(.semibold)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Reset all") {
                withAnimation(DS.Motion.value) {
                    params = LookParameters.standard
                    lutError = nil
                }
                resetAllPulses += 1
                model.show("Look reset to Standard")
            }
            .ds(.subheadlineMedium)
            .foregroundStyle(changes == 0 ? DS.Color.label3 : DS.Color.accent)
            .padding(.horizontal, 12)
            .frame(minHeight: DS.touch)
            .buttonStyle(DSPlainButtonStyle())
            .disabled(changes == 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: DS.radiusGroup, style: .continuous).fill(DS.Color.surface2))
        .padding(.horizontal, DS.margin)
        .padding(.bottom, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .ds(.footnoteSemibold)
            .foregroundStyle(DS.Color.label2)
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Film cards

    private var filmCards: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(FilmLibrary.shared.films) { film in
                    filmCard(film)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, DS.margin)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Film")
    }

    private func filmCard(_ film: Film) -> some View {
        let selected = params.film == film.id
        let description = film.detail.replacingOccurrences(of: " · ", with: ", ")
        return Button {
            params.film = film.id
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let image = swatches.images[film.id] {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            DS.Color.surface2
                        }
                    }
                    .frame(width: 96, height: 72)
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
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSwatch + 4, style: .continuous)
                        .strokeBorder(selected ? DS.Color.accent : .clear, lineWidth: 2)
                )
                .padding(-4)
                Text(film.name)
                    .ds(.chip)
                    .foregroundStyle(DS.Color.label)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .padding(.top, 8)
                Text(description)
                    .ds(.caption2)
                    .foregroundStyle(DS.Color.label2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .frame(width: 96, alignment: .leading)
        }
        .buttonStyle(DSPlainButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(film.name), \(description.lowercased())")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Setting rows

    private func group(_ settings: [LookSetting]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(settings.enumerated()), id: \.element.id) { index, setting in
                if index > 0 {
                    Rectangle().fill(DS.Color.separator).frame(height: 1 / 3).padding(.leading, DS.rowPadding)
                }
                row(setting)
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.radiusGroup, style: .continuous).fill(DS.Color.surface2))
        .padding(.horizontal, DS.margin)
    }

    private func row(_ setting: LookSetting) -> some View {
        let value = params[keyPath: setting.keyPath]
        let changed = !setting.isDefault(value)
        let valueText = Text(setting.format(value))
            .ds(.subheadlineMedium)
            .monospacedDigit()
            .foregroundStyle(changed ? DS.Color.accent : DS.Color.label2)
            .contentTransition(.numericText())
        let resetButton = Button {
            withAnimation(DS.Motion.value) { params[keyPath: setting.keyPath] = setting.defaultValue }
            resetOnePulses += 1
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.Color.label2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(DS.Color.surface3))
                .frame(width: 44, height: 32)
        }
        .buttonStyle(DSPlainButtonStyle())
        .opacity(changed ? 1 : 0)
        .disabled(!changed)
        .accessibilityLabel("Reset \(setting.title) to default")
        .accessibilityHidden(!changed)

        let label = VStack(alignment: .leading, spacing: 0) {
            Text(setting.title).ds(.subheadline)
            if let subtitle = setting.subtitle {
                Text(subtitle).ds(.caption1).foregroundStyle(DS.Color.label2)
            }
        }

        return VStack(alignment: .leading, spacing: 0) {
            if typeSize.isAccessibilitySize {
                label
                HStack { valueText; Spacer(); resetButton }
            } else {
                HStack(alignment: .center, spacing: 6) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    valueText
                    resetButton.padding(.trailing, -8)
                }
                .frame(minHeight: 24)
            }
            DSSlider(
                value: Binding(get: { params[keyPath: setting.keyPath] }, set: { params[keyPath: setting.keyPath] = $0 }),
                range: setting.range, step: setting.step, defaultValue: setting.defaultValue,
                label: setting.title, valueText: setting.format
            )
            .padding(.horizontal, -2)
            .onTapGesture(count: 2) {
                withAnimation(DS.Motion.snap) { params[keyPath: setting.keyPath] = setting.defaultValue }
                resetOnePulses += 1
            }
            if let ends = setting.ends {
                HStack {
                    Text(ends.0)
                    Spacer()
                    Text(ends.1)
                }
                .ds(.caption2)
                .foregroundStyle(DS.Color.label3)
                .padding(.horizontal, 12)
                .padding(.top, -2)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DS.rowPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Custom LUT

    private var lutGroup: some View {
        VStack(spacing: 0) {
            if let lutError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Color.red)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lutError).ds(.subheadline)
                        Text("The LUT wasn’t loaded. The film look is unchanged.")
                            .ds(.footnote)
                            .foregroundStyle(DS.Color.label2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.rowPadding)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                Rectangle().fill(DS.Color.separator).frame(height: 1 / 3)
                lutButton("Choose another file")
            } else if let name = params.customLUT {
                HStack(spacing: 12) {
                    Image(systemName: "cube")
                        .font(.system(size: 17))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.surface3))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).ds(.subheadlineMedium).lineLimit(1).truncationMode(.middle)
                        if let size = CustomLUTLibrary.shared.cube(named: name)?.size {
                            Text("\(size)-point 3D LUT").ds(.caption1).foregroundStyle(DS.Color.label2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.rowPadding)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                Rectangle().fill(DS.Color.separator).frame(height: 1 / 3)
                row(LookSetting.lutStrength)
                Rectangle().fill(DS.Color.separator).frame(height: 1 / 3)
                HStack(spacing: 0) {
                    Button("Replace") { importingLUT = true }
                        .foregroundStyle(DS.Color.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Rectangle().fill(DS.Color.separator).frame(width: 1 / 3, height: 44)
                    Button("Remove") {
                        params.customLUT = nil
                        params.customLUTStrength = 1
                        resetOnePulses += 1
                    }
                    .foregroundStyle(DS.Color.red)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .ds(.subheadline)
                .buttonStyle(DSPlainButtonStyle())
            } else {
                lutButton("Import .cube file")
            }
        }
        .background(RoundedRectangle(cornerRadius: DS.radiusGroup, style: .continuous).fill(DS.Color.surface2))
        .padding(.horizontal, DS.margin)
    }

    private func lutButton(_ title: String) -> some View {
        Button { importingLUT = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 17))
                Text(title).ds(.subheadline)
                Spacer()
            }
            .foregroundStyle(DS.Color.accent)
            .padding(.horizontal, DS.rowPadding)
            .frame(minHeight: 48)
        }
        .buttonStyle(DSPlainButtonStyle())
    }

    // MARK: Editor footer

    private func footer(isDefault: Bool, useAsDefault: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(DS.Color.separator).frame(height: 1 / 3)
            Button {
                useAsDefault()
                successPulses += 1
                model.show("Now the default for new shots")
            } label: {
                HStack(spacing: 8) {
                    if isDefault { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)) }
                    Text(isDefault ? "This is your default" : "Use as default for new shots").ds(.headline)
                }
                .foregroundStyle(isDefault ? DS.Color.label2 : DS.Color.label)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Color.surface2))
            }
            .buttonStyle(DSPlainButtonStyle())
            .disabled(isDefault)
            .padding(.horizontal, DS.margin)
            .padding(.top, 10)
        }
        .background(DS.Color.surface1)
    }
}
