import SwiftUI

// Printlight design system: tokens and shared components from the interface design
// (claude.ai artifact "Printlight: interface design"). The app is always dark; all chrome is
// true neutral grey so the image is the only colour.

// MARK: - Colour

enum DS {
    enum Color {
        /// Camera background, viewfinder surround, Library and Editor canvas.
        static let black = SwiftUI.Color.black
        /// Look sheet, Editor panel, Photos pre-prompt. Opaque.
        static let surface1 = SwiftUI.Color(white: 0x1C / 255)
        /// Grouped rows, top-bar buttons, Look button, segmented controls, banners.
        static let surface2 = SwiftUI.Color(white: 0x2A / 255)
        /// Slider tracks, reset buttons, selected filter segment, placeholders.
        static let surface3 = SwiftUI.Color(white: 0x3A / 255)
        static let label = SwiftUI.Color.white
        /// Descriptions, inactive values, EV at zero.
        static let label2 = SwiftUI.Color.white.opacity(0.62)
        /// Slider end labels, disabled text, credit line. Never for anything essential.
        static let label3 = SwiftUI.Color.white.opacity(0.34)
        static let separator = SwiftUI.Color.white.opacity(0.14)
        /// Safelight amber: active lens, focus box, EV needle, changed values, selected film,
        /// change badge. Never a large fill.
        static let accent = SwiftUI.Color(red: 1, green: 0xB3 / 255, blue: 0x40 / 255)
        /// No RAW pill, error icons, destructive actions. Always with an icon or words.
        static let red = SwiftUI.Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)
        /// Base of the overlay material drawn over the image (#141414 at 72% + blur).
        static let overlay = SwiftUI.Color(white: 0x14 / 255).opacity(0.72)
        /// iOS system-alert blue, only for alert-style buttons.
        static let alertBlue = SwiftUI.Color(red: 0x0A / 255, green: 0x84 / 255, blue: 1)
    }

    // MARK: Type (SF Pro; tracking per Apple's optical sizes)

    enum TextStyle {
        case largeTitle, title1, title3, title3Bold, headline, body, subheadline, subheadlineMedium,
             footnote, footnoteSemibold, chip, caption1, caption2, caption2Semibold, ruler

        var size: CGFloat {
            switch self {
            case .largeTitle: 34
            case .title1: 28
            case .title3, .title3Bold: 20
            case .headline, .body: 17
            case .subheadline, .subheadlineMedium: 15
            case .footnote, .footnoteSemibold, .chip: 13
            case .caption1: 12
            case .caption2, .caption2Semibold: 11
            case .ruler: 10
            }
        }

        var weight: Font.Weight {
            switch self {
            case .largeTitle, .title1, .title3Bold: .bold
            case .title3, .headline, .footnoteSemibold, .chip, .caption2Semibold, .ruler: .semibold
            case .subheadlineMedium: .medium
            default: .regular
            }
        }

        var tracking: CGFloat {
            switch self {
            case .largeTitle: 0.37
            case .title1: 0.36
            case .title3, .title3Bold: 0.38
            case .headline, .body: -0.43
            case .subheadline, .subheadlineMedium: -0.23
            case .footnote, .footnoteSemibold, .chip: -0.08
            case .caption1, .ruler: 0
            case .caption2, .caption2Semibold: 0.06
            }
        }

        /// Text style the size scales with under Dynamic Type.
        var relativeTo: Font.TextStyle {
            switch self {
            case .largeTitle: .largeTitle
            case .title1: .title
            case .title3, .title3Bold: .title3
            case .headline: .headline
            case .body: .body
            case .subheadline, .subheadlineMedium: .subheadline
            case .footnote, .footnoteSemibold, .chip: .footnote
            case .caption1: .caption
            case .caption2, .caption2Semibold, .ruler: .caption2
            }
        }
    }

    // MARK: Spacing, radii, strokes

    static let margin: CGFloat = 16
    static let rowPadding: CGFloat = 14
    static let touch: CGFloat = 44
    static let radiusSheet: CGFloat = 38
    static let radiusPanel: CGFloat = 24
    static let radiusGroup: CGFloat = 12
    static let radiusSwatch: CGFloat = 10
    static let radiusThumb: CGFloat = 10

    // MARK: Motion

    enum Motion {
        static let sheet = Animation.spring(response: 0.44, dampingFraction: 1)
        static let shutterPress = Animation.easeOut(duration: 0.09)
        static let blackout = Animation.easeOut(duration: 0.22)
        static let thumbIn = Animation.spring(response: 0.32, dampingFraction: 0.7)
        static let thumbDeveloped = Animation.easeInOut(duration: 0.35)
        static let lens = Animation.smooth(duration: 0.2)
        static let value = Animation.easeOut(duration: 0.15)
        static let snap = Animation.easeOut(duration: 0.12)
        static let toastIn = Animation.spring(response: 0.32, dampingFraction: 0.75)
        static let toastOut = Animation.easeOut(duration: 0.25)
        /// Reduce Motion: every movement becomes a 0.2 s crossfade.
        static let reduced = Animation.easeInOut(duration: 0.2)
    }
}

extension View {
    /// Applies a DS text style: SF Pro at the spec's size, weight and tracking, scaling with
    /// Dynamic Type relative to the matching system style.
    func ds(_ style: DS.TextStyle) -> some View {
        modifier(DSTextModifier(style: style))
    }

    /// The overlay material for anything drawn over the image: #141414 at 72% on a 20 pt blur.
    /// Reduce Transparency makes it opaque; Increase Contrast adds a 1 pt white 40% border.
    func overlayMaterial<S: InsettableShape>(in shape: S) -> some View {
        modifier(OverlayMaterialModifier(shape: shape))
    }
}

private struct DSTextModifier: ViewModifier {
    let style: DS.TextStyle
    @ScaledMetric private var scale: CGFloat = 1

    init(style: DS.TextStyle) {
        self.style = style
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: style.size * scale, weight: style.weight))
            .tracking(style.tracking)
    }
}

private struct OverlayMaterialModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(white: 0x14 / 255))
                } else {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(DS.Color.overlay))
                }
            }
            .overlay {
                if contrast == .increased { shape.strokeBorder(Color.white.opacity(0.4), lineWidth: 1) }
            }
    }
}

// MARK: - Number formatting (U+2212 minus, as in the design)

enum DSFormat {
    static let minus = "\u{2212}"

    /// Signed value with fixed decimals; zero has no sign.
    static func signed(_ value: Double, decimals: Int) -> String {
        let magnitude = String(format: "%.\(decimals)f", abs(value))
        if Double(magnitude) == 0 { return String(format: "%.\(decimals)f", 0.0) }
        return (value > 0 ? "+" : minus) + magnitude
    }

    static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    /// EV in thirds of a stop: "±0", "+⅓", "−1⅔".
    static func thirds(_ thirds: Int) -> String {
        guard thirds != 0 else { return "±0" }
        let whole = abs(thirds) / 3, rest = abs(thirds) % 3
        return (thirds > 0 ? "+" : minus) + (whole > 0 ? "\(whole)" : "") + (rest == 1 ? "⅓" : rest == 2 ? "⅔" : "")
    }

    /// VoiceOver wording for thirds: "Zero", "Plus one third stop", "Minus 1 and two thirds stops".
    static func thirdsSpoken(_ thirds: Int) -> String {
        guard thirds != 0 else { return "Zero" }
        let whole = abs(thirds) / 3, rest = abs(thirds) % 3
        var text = thirds > 0 ? "Plus " : "Minus "
        if whole > 0 { text += "\(whole)" + (rest > 0 ? " and " : "") }
        if rest == 1 { text += "one third" } else if rest == 2 { text += "two thirds" }
        return text + (abs(thirds) == 3 ? " stop" : " stops")
    }
}

// MARK: - Buttons

/// Primary: white capsule, black text. Secondary: surface.2 capsule. Pressed: opacity 0.7.
struct DSCapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary
    var height: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ds(.headline)
            .foregroundStyle(!isEnabled ? DS.Color.label3 : kind == .primary ? Color.black : DS.Color.label)
            .padding(.horizontal, 22)
            .frame(height: height)
            .background(Capsule().fill(!isEnabled ? DS.Color.surface2 : kind == .primary ? Color.white : DS.Color.surface2))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Plain text-only control, pressed at opacity 0.7.
struct DSPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1).contentShape(Rectangle())
    }
}

/// Scales the label while pressed (top-bar toggles 0.92, Look button 0.94).
struct DSScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(DS.Motion.shutterPress, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Spinner

/// The design's spinner: a white arc on a faint ring.
struct DSSpinner: View {
    var size: CGFloat = 22
    var lineWidth: CGFloat = 2.5
    var color: Color = .white
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.25).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Slider

/// The design's setting slider: 4 pt surface.3 track, white 88% fill from the default to the
/// value, a 2 × 14 default tick, and a 28 pt white knob with the only shadow in the app.
/// Within 2.5% of the default the knob snaps onto it with a light impact.
struct DSSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    var label: String = ""
    var valueText: (Double) -> String = { String(format: "%.2f", $0) }

    @State private var dragging = false
    @State private var snapPulses = 0
    @GestureState private var isDown = false

    private let knob: CGFloat = 28
    private var span: Double { range.upperBound - range.lowerBound }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackLeft: CGFloat = 14, trackWidth = max(width - 28, 1)
            let t = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            let d = CGFloat((defaultValue - range.lowerBound) / span)
            ZStack(alignment: .topLeading) {
                Capsule().fill(DS.Color.surface3)
                    .frame(width: trackWidth, height: 4)
                    .offset(x: trackLeft, y: 16)
                Capsule().fill(Color.white.opacity(0.88))
                    .frame(width: abs(t - d) * trackWidth, height: 4)
                    .offset(x: trackLeft + min(t, d) * trackWidth, y: 16)
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.55))
                    .frame(width: 2, height: 14)
                    .offset(x: trackLeft + d * trackWidth - 1, y: 11)
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 6)
                    .scaleEffect(dragging ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: dragging)
                    .offset(x: trackLeft + t * trackWidth - knob / 2, y: 4)
            }
            .frame(width: width, height: 36, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let fraction = min(max((drag.location.x - trackLeft) / trackWidth, 0), 1)
                        var next = range.lowerBound + Double(fraction) * span
                        next = (next / step).rounded() * step
                        if abs(next - defaultValue) < span * 0.025 {
                            if value != defaultValue { snapPulses += 1 }
                            withAnimation(DS.Motion.snap) { value = defaultValue }
                        } else {
                            value = min(max(next, range.lowerBound), range.upperBound)
                        }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 36)
        .sensoryFeedback(.impact(weight: .light), trigger: snapPulses)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText(value) + (abs(value - defaultValue) < 1e-9 ? ", default" : ", default \(valueText(defaultValue))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset to default") { value = defaultValue }
    }
}

// MARK: - Toast

/// Capsule of overlay material with an icon and one line, dropped in below the top bar.
/// Never takes touches. Info toasts last 2.5 s, errors 4 s with a red warning icon.
struct DSToast: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isError ? DS.Color.red : DS.Color.label)
            Text(text)
                .ds(.subheadlineMedium)
                .foregroundStyle(DS.Color.label)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .overlayMaterial(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    static func duration(isError: Bool) -> Duration { isError ? .seconds(4) : .milliseconds(2500) }
}

extension View {
    /// Shows the model's current message as a toast at `top`, auto-dismissing it.
    func dsToast(text: Binding<String?>, isError: Bool, top: CGFloat) -> some View {
        modifier(DSToastHost(text: text, isError: isError, top: top))
    }
}

private struct DSToastHost: ViewModifier {
    @Binding var text: String?
    let isError: Bool
    let top: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let current = text {
                DSToast(text: current, isError: isError)
                    .padding(.top, top)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -14)))
                    .task(id: current) {
                        try? await Task.sleep(for: DSToast.duration(isError: isError))
                        if text == current {
                            withAnimation(DS.Motion.toastOut) { text = nil }
                        }
                    }
                    .sensoryFeedback(trigger: current) { _, _ in isError ? .error : nil }
            }
        }
        .animation(reduceMotion ? DS.Motion.reduced : DS.Motion.toastIn, value: text)
    }
}

// MARK: - Icons

/// The one custom glyph: the zebra toggle, drawn to match SF Symbols at Regular weight
/// (24 × 24 design: rounded square with three diagonal stripes).
struct ZebraGlyph: View {
    var size: CGFloat = 19

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 24
            var path = Path(roundedRect: CGRect(x: 3.5 * s, y: 3.5 * s, width: 17 * s, height: 17 * s), cornerRadius: 4.5 * s)
            path.move(to: CGPoint(x: 4.5 * s, y: 13.5 * s)); path.addLine(to: CGPoint(x: 13.5 * s, y: 4.5 * s))
            path.move(to: CGPoint(x: 7 * s, y: 20 * s)); path.addLine(to: CGPoint(x: 20 * s, y: 7 * s))
            path.move(to: CGPoint(x: 13.5 * s, y: 20 * s)); path.addLine(to: CGPoint(x: 20 * s, y: 13.5 * s))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
