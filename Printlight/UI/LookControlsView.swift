import SwiftUI
import UniformTypeIdentifiers

// MARK: - Design system

/// Shared look for Printlight's chrome: black, white at varying opacity, one warm accent.
enum Palette {
    /// Warm amber, #F2A93B.
    static let accent = Color(red: 242 / 255, green: 169 / 255, blue: 59 / 255)
    /// Near-black used for panels that sit on top of the image.
    static let panel = Color(white: 0.07)
    static let hairline = Color.white.opacity(0.1)
}

extension View {
    /// Small monospaced, tracked text used for readouts and labels (RAW badge, EV, lens, headers).
    func readout(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
            .tracking(size * 0.14)
    }
}

/// Dark translucent background for sheets presented over the viewfinder.
struct PanelBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.62)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// A thin, precise slider: 2pt track, accent fill from the origin, a tick at the default value,
/// and a small white thumb. Drags are relative, so touching the track never makes the value jump.
struct InstrumentSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double?

    @State private var dragStartValue: Double?

    private let thumb: CGFloat = 14
    private var span: Double { range.upperBound - range.lowerBound }

    /// Fill grows from zero when the range spans it (exposure-like values), otherwise from the minimum.
    private var origin: Double {
        range.lowerBound < 0 && range.upperBound > 0 ? 0 : range.lowerBound
    }

    private var isAtDefault: Bool {
        guard let defaultValue else { return false }
        return abs(value - defaultValue) < span * 1e-6
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = x(for: value, in: width)
            let originX = x(for: origin, in: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: max(width - thumb, 0), height: 2)
                    .offset(x: thumb / 2)

                Capsule()
                    .fill(Palette.accent)
                    .frame(width: abs(thumbX - originX), height: 2)
                    .offset(x: min(thumbX, originX))

                if let defaultValue {
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 1, height: 8)
                        .offset(x: x(for: defaultValue, in: width) - 0.5)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .scaleEffect(dragStartValue != nil ? 1.25 : 1)
                    .offset(x: thumbX - thumb / 2)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStartValue ?? value
                        if dragStartValue == nil { dragStartValue = value }
                        let travel = max(width - thumb, 1)
                        var next = start + Double(drag.translation.width / travel) * span
                        next = min(max(next, range.lowerBound), range.upperBound)
                        // Detent at the default so it's easy to find again.
                        if let defaultValue, abs(next - defaultValue) < span * 0.015 { next = defaultValue }
                        value = next
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: dragStartValue != nil)
        }
        .frame(height: 28)
        .sensoryFeedback(trigger: isAtDefault) { _, atDefault in atDefault ? .selection : nil }
    }

    private func x(for v: Double, in width: CGFloat) -> CGFloat {
        let t = span > 0 ? (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
        return thumb / 2 + CGFloat(t) * max(width - thumb, 0)
    }
}

// MARK: - Look controls

/// One adjustable look parameter.
struct LookParameterSpec: Identifiable {
    let title: String
    let keyPath: WritableKeyPath<LookParameters, Double>
    let range: ClosedRange<Double>
    let format: String

    var id: String { title }
    var defaultValue: Double { LookParameters.standard[keyPath: keyPath] }

    func isDefault(_ value: Double) -> Bool {
        abs(value - defaultValue) < (range.upperBound - range.lowerBound) * 1e-6
    }
}

private struct LookSection: Identifiable {
    let title: String
    let rows: [LookParameterSpec]
    var id: String { title }

    static var all: [LookSection] {
        [
            LookSection(title: "TONE", rows: [
                LookParameterSpec(title: "Exposure", keyPath: \.exposure, range: -3...3, format: "%+.2f"),
                LookParameterSpec(title: "Black lift", keyPath: \.blackLift, range: 0...0.04, format: "%.3f"),
            ]),
            LookSection(title: "COLOUR", rows: [
                LookParameterSpec(title: "Warmth", keyPath: \.warmth, range: -1...1, format: "%+.2f"),
                LookParameterSpec(title: "Tint", keyPath: \.tint, range: -1...1, format: "%+.2f"),
            ]),
            LookSection(title: "TEXTURE", rows: [
                LookParameterSpec(title: "Clarity", keyPath: \.clarity, range: 0...1, format: "%.2f"),
                LookParameterSpec(title: "Halation", keyPath: \.halation, range: 0...0.5, format: "%.2f"),
                LookParameterSpec(title: "Halation threshold", keyPath: \.halationThreshold, range: -1...3, format: "%+.1f"),
                LookParameterSpec(title: "Grain", keyPath: \.grain, range: 0...0.04, format: "%.3f"),
            ]),
        ]
    }
}

/// Every look parameter as a dark instrument panel. Shared by the camera sheet and the editor.
struct LookControlsView: View {
    @Binding var params: LookParameters

    @State private var importingLUT = false
    @State private var lutError: String?

    private let sections = LookSection.all

    private var adjustedCount: Int {
        sections.flatMap(\.rows).filter { !$0.isDefault(params[keyPath: $0.keyPath]) }.count
            + (params.film == LookParameters.standard.film ? 0 : 1)
            + (params.customLUT == nil ? 0 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    filmSection
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                    lutSection
                    Text("Film data: spektrafilm profiles by Andrea Volpato, CC BY-SA 4.0.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        let isStandard = params == .standard
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LOOK")
                    .readout(13, weight: .semibold)
                Text(isStandard ? "STANDARD" : (adjustedCount == 0 ? "CUSTOM" : "\(adjustedCount) ADJUSTED"))
                    .readout(10)
                    .foregroundStyle(isStandard ? Color.white.opacity(0.4) : Palette.accent)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button {
                withAnimation(.snappy) { params = .standard }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("RESET")
                        .readout(11, weight: .semibold)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isStandard)
            .opacity(isStandard ? 0.35 : 1)
            .accessibilityLabel("Reset look to default")
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .sensoryFeedback(.impact(weight: .light), trigger: isStandard) { _, new in new }
    }

    private var filmSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("FILM")
            ForEach(FilmLibrary.shared.films) { film in
                FilmRow(film: film, isSelected: params.film == film.id) {
                    withAnimation(.snappy) { params.film = film.id }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: params.film)
    }

    /// A creative `.cube` grade on top of the film, imported from Files.
    private var lutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("CUSTOM LUT")
            HStack(spacing: 12) {
                if let name = params.customLUT {
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(.snappy) { params.customLUT = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove custom LUT")
                } else {
                    Text("Rec.709 .cube looks, applied after the film")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                }
                Button {
                    importingLUT = true
                } label: {
                    Text(params.customLUT == nil ? "IMPORT" : "CHANGE")
                        .readout(11, weight: .semibold)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if let lutError {
                Text(lutError)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
            }
            if params.customLUT != nil {
                ParameterRow(
                    spec: LookParameterSpec(title: "Strength", keyPath: \.customLUTStrength, range: 0...1, format: "%.2f"),
                    value: $params.customLUTStrength
                )
            }
        }
        .fileImporter(
            isPresented: $importingLUT,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .data]
        ) { result in
            do {
                let name = try CustomLUTLibrary.shared.importLUT(from: result.get())
                lutError = nil
                withAnimation(.snappy) { params.customLUT = name }
            } catch {
                lutError = error.localizedDescription
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .readout(10, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.42))
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 0.5)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func sectionView(_ section: LookSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(section.title)

            ForEach(section.rows) { spec in
                ParameterRow(spec: spec, value: $params[dynamicMember: spec.keyPath])
            }
        }
    }
}

/// One film stock: name and negative/print pairing, accent ring when selected.
private struct FilmRow: View {
    let film: Film
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(isSelected ? Palette.accent : Color.white.opacity(0.3), lineWidth: 1.5)
                    .background(Circle().fill(isSelected ? Palette.accent : .clear).padding(4))
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(film.name.uppercased())
                        .readout(12, weight: .semibold)
                        .foregroundStyle(isSelected ? Palette.accent : Color.white.opacity(0.88))
                    Text(film.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accent.opacity(0.5) : Palette.hairline, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(film.name), \(film.detail)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ParameterRow: View {
    let spec: LookParameterSpec
    @Binding var value: Double

    private var formatted: String { String(format: spec.format, value) }

    var body: some View {
        let isDefault = spec.isDefault(value)
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.88))
                Spacer()
                Text(formatted)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isDefault ? Color.white.opacity(0.5) : Palette.accent)
            }
            .contentShape(Rectangle())
            // Double-tap the label line to return the parameter to its default.
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { value = spec.defaultValue }
            }
            InstrumentSlider(value: $value, range: spec.range, defaultValue: spec.defaultValue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.title)
        .accessibilityValue(formatted)
        .accessibilityAdjustableAction { direction in
            let step = (spec.range.upperBound - spec.range.lowerBound) / 40
            switch direction {
            case .increment: value = min(value + step, spec.range.upperBound)
            case .decrement: value = max(value - step, spec.range.lowerBound)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset to default") { value = spec.defaultValue }
    }
}
