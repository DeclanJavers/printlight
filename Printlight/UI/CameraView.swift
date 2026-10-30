import SwiftUI

/// The camera: everything for shooting sits in the bottom third, one-handed. The top bar holds
/// only things set once and left alone: zebras, format, and the Look / Apple compare switch.
struct CameraView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingLook = false
    @State private var showingLibrary = false
    @State private var focus: FocusTap?
    @State private var blackout = false
    @State private var shutterPresses = 0
    @State private var focusTaps = 0
    @State private var toggles = 0
    @State private var warnings = 0
    /// Counter-rotation for the square controls (icons, lens discs, thumbnail) when the phone is
    /// held sideways. The layout never moves. Wide labels (RAW pill, EV readout) stay horizontal:
    /// turned 90° they'd overflow their bars.
    @State private var iconAngle: Double = 0

    private let topBarHeight: CGFloat = 44
    private let evHeight: CGFloat = 60
    private let captionHeight: CGFloat = 38

    private var running: Bool { camera.status == .running || Self.uiDemo }
    private var noRAW: Bool { running && camera.rawMode == .unavailable && !Self.uiDemo }

    /// Debug builds launched with `-PrintlightUIDemo` show the camera chrome as if the camera
    /// were running, so the simulator (which has no camera) can be used to check layout.
    #if DEBUG
    private static let uiDemo = ProcessInfo.processInfo.arguments.contains("-PrintlightUIDemo")
    #else
    private static let uiDemo = false
    #endif
    private var filmName: String { FilmLibrary.shared.film(id: model.params.film).name }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let finderHeight = (width * 4 / 3).rounded()
            let below = geo.size.height - topBarHeight - finderHeight
            // Shorter than ~190 pt below the viewfinder: top bar moves over it, caption drops.
            let compact = below < 190
            VStack(spacing: 0) {
                if !compact { topBar.frame(height: topBarHeight) }
                viewfinder
                    .frame(width: width, height: finderHeight)
                    .overlay(alignment: .top) {
                        if compact {
                            topBar.frame(height: topBarHeight)
                                .background(DS.Color.overlay.background(.ultraThinMaterial))
                        }
                    }
                EVDial(bias: $camera.exposureBias)
                    .frame(height: evHeight)
                    .opacity(running ? 1 : 0)
                    .allowsHitTesting(running)
                shutterRow.frame(maxHeight: .infinity)
                if !compact {
                    filmCaption.frame(height: captionHeight)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .top)
        }
        .background(DS.Color.black.ignoresSafeArea())
        .foregroundStyle(DS.Color.label)
        .statusBarHidden(true)
        .dsToast(text: $model.message, isError: model.messageIsError, top: 52)
        .sheet(isPresented: $showingLook) {
            LookControlsView(
                params: $model.params, mode: .camera,
                swatchSource: { model.preview.currentFrame().map { ($0, true) } },
                onClose: { showingLook = false }
            )
            .padding(.top, 8)
            .presentationDetents([.fraction(0.56), .large])
            .presentationBackground(DS.Color.surface1)
            .presentationCornerRadius(DS.radiusSheet)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.56)))
            .environmentObject(model)
        }
        .fullScreenCover(isPresented: $showingLibrary) {
            LibraryView(library: model.library)
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: Binding(get: { model.showPhotosPrePrompt }, set: { _ in })) {
            PhotosPrePromptView { model.continueFromPhotosPrePrompt() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shutterPresses)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: focusTaps)
        .sensoryFeedback(.selection, trigger: toggles)
        .sensoryFeedback(.warning, trigger: warnings)
        .onAppear {
            camera.start()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateIconAngle()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateIconAngle()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: camera.start()
            case .background: camera.stop()
            default: break
            }
        }
        .onChange(of: camera.isCapturing) { _, capturing in
            guard capturing else { return }
            blackout = true
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(DS.Motion.blackout) { blackout = false }
            }
        }
        .accessibilityAction(.magicTap) { shoot() }
    }

    private func updateIconAngle() {
        let angle: Double
        switch UIDevice.current.orientation {
        case .portrait: angle = 0
        case .landscapeLeft: angle = 90
        case .landscapeRight: angle = -90
        default: return // face up/down and upside down keep the last orientation
        }
        guard angle != iconAngle else { return }
        withAnimation(reduceMotion ? DS.Motion.reduced : .spring(response: 0.3, dampingFraction: 0.82)) { iconAngle = angle }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                model.zebras.toggle()
                toggles += 1
                model.show(model.zebras ? "Zebras on" : "Zebras off")
            } label: {
                ZebraGlyph(size: 19)
                    .rotationEffect(.degrees(iconAngle))
                    .foregroundStyle(model.zebras ? Color.black : DS.Color.label)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(model.zebras ? Color.white : DS.Color.surface2))
                    .frame(width: DS.touch, height: DS.touch)
            }
            .buttonStyle(DSScaleButtonStyle(scale: 0.92))
            .accessibilityLabel("Clipping warning")
            .accessibilityValue(model.zebras ? "On" : "Off")

            Spacer()
            if running { rawPill }
            Spacer()

            HStack(spacing: 0) {
                segment("Look", selected: model.lookEnabled) { model.lookEnabled = true }
                segment("Apple", selected: !model.lookEnabled) { model.lookEnabled = false }
            }
            .padding(2)
            .frame(height: 32)
            .background(Capsule().fill(DS.Color.surface2))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview")
        }
        .padding(.horizontal, 12)
    }

    private var rawPill: some View {
        let text = noRAW ? "No RAW" : camera.rawMode == .proRAW ? "ProRAW \(camera.megapixels)MP" : "RAW 12MP"
        return HStack(spacing: 6) {
            if noRAW { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .bold)) }
            Text(text).ds(.chip)
        }
        .foregroundStyle(DS.Color.label)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(noRAW ? DS.Color.red : DS.Color.surface2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Format")
        .accessibilityValue(noRAW ? "No RAW. The shutter is off on this lens."
                            : camera.rawMode == .proRAW ? "ProRAW, \(camera.megapixels) megapixels" : "RAW, 12 megapixels")
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            action()
            toggles += 1
        } label: {
            Text(title)
                .ds(.chip)
                .foregroundStyle(selected ? Color.black : DS.Color.label2)
                .padding(.horizontal, 10)
                .frame(minWidth: 52, minHeight: 28)
                .background(Capsule().fill(selected ? Color.white : .clear))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .padding(.vertical, -6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Look" ? "Film look" : "Apple")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                PreviewView(renderer: model.preview)
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard running else { return }
                        focus = FocusTap(location: tap.location)
                        focusTaps += 1
                        camera.focus(at: model.preview.normalizedFramePoint(for: tap.location, in: geo.size))
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Viewfinder")
                    .accessibilityValue(model.lookEnabled ? filmName : "Apple preview")
                    .accessibilityHint("Double-tap to focus at the centre.")
                    .accessibilityAction { focusAt(CGPoint(x: 0.5, y: 0.5), size: geo.size) }
                    .accessibilityAction(named: "Focus at centre") { focusAt(CGPoint(x: 0.5, y: 0.5), size: geo.size) }
                    .accessibilityAction(named: "Focus upper third") { focusAt(CGPoint(x: 0.5, y: 1.0 / 3), size: geo.size) }
                    .accessibilityAction(named: "Focus lower third") { focusAt(CGPoint(x: 0.5, y: 2.0 / 3), size: geo.size) }

                if let focus {
                    FocusBox(reduceMotion: reduceMotion)
                        .position(focus.location)
                        .id(focus.id)
                        .allowsHitTesting(false)
                }

                if noRAW {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(DS.Color.red)
                        Text("This lens can’t shoot RAW. Switch to 1×.").ds(.chip)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .overlayMaterial(in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 64)
                }

                if running && camera.lenses.count > 1 {
                    lensGroup
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 10)
                }

                if !Self.uiDemo { stateOverlay }

                Color.black
                    .opacity(blackout ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private func focusAt(_ point: CGPoint, size: CGSize) {
        guard running else { return }
        focus = FocusTap(location: CGPoint(x: point.x * size.width, y: point.y * size.height))
        focusTaps += 1
        camera.focus(at: model.preview.normalizedFramePoint(for: focus!.location, in: size))
    }

    private var lensGroup: some View {
        HStack(spacing: 0) {
            ForEach(camera.lenses) { lens in
                let active = lens.id == camera.currentLensID
                Button {
                    guard !active else { return }
                    camera.select(lens: lens)
                    toggles += 1
                } label: {
                    Text(active ? lens.label + "×" : lens.label)
                        .font(.system(size: active ? 13 : 11, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(active ? DS.Color.accent : DS.Color.label)
                        .rotationEffect(.degrees(iconAngle))
                        .frame(width: active ? 38 : 32, height: active ? 38 : 32)
                        .background(Circle().fill(Color(white: 0x14 / 255).opacity(active ? 0.86 : 0.6)))
                        .frame(width: DS.touch, height: DS.touch)
                        .animation(DS.Motion.lens, value: active)
                }
                .buttonStyle(DSPlainButtonStyle())
                .accessibilityLabel("\(lens.label) times")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 2)
        .frame(height: DS.touch)
        .background(Capsule().fill(Color.black.opacity(0.42)).background(.ultraThinMaterial, in: Capsule()))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lens")
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch camera.status {
        case .starting:
            ZStack {
                Color.black
                DSSpinner()
            }
            .accessibilityElement()
            .accessibilityLabel("Starting camera")
        case .denied:
            stateMessage(icon: "camera.fill", slashed: true, title: "Printlight needs the camera",
                         body: "Allow camera access in Settings to take photos.") {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(DSCapsuleButtonStyle())
                .padding(.top, 10)
            }
        case .failed(let reason):
            stateMessage(icon: "exclamationmark.triangle", slashed: false, title: "Camera unavailable", body: reason) {
                EmptyView()
            }
        case .running:
            EmptyView()
        }
    }

    private func stateMessage<A: View>(icon: String, slashed: Bool, title: String, body: String,
                                       @ViewBuilder action: () -> A) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DS.Color.label2)
                    .overlay {
                        if slashed {
                            // Diagonal slash with a black gap, like SF Symbols' .slash variants.
                            Capsule().fill(DS.Color.label2).frame(width: 2.5, height: 54)
                                .background(Capsule().fill(Color.black).frame(width: 7, height: 54))
                                .rotationEffect(.degrees(-45))
                        }
                    }
                Text(title).ds(.title3).padding(.top, 6)
                Text(body).ds(.subheadline).foregroundStyle(DS.Color.label2)
                action()
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
        }
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack {
            thumbnail
            Spacer()
            Button(action: shoot) { EmptyView() }
                .buttonStyle(ShutterButtonStyle(disabled: !running || noRAW, busy: camera.isCapturing))
                .accessibilityLabel("Take photo")
                .accessibilityHint(noRAW ? "Unavailable: this lens can’t shoot RAW." : !running ? "The camera isn’t running." : "")
            Spacer()
            lookButton
        }
        .padding(.horizontal, 30)
    }

    private func shoot() {
        if noRAW {
            model.show("This lens can’t shoot RAW. Switch to 1×.", error: true)
            warnings += 1
            return
        }
        guard running, !camera.isCapturing else { return }
        shutterPresses += 1
        model.capture()
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radiusThumb, style: .continuous)
        let developing = model.developingCount > 0
        return Button { showingLibrary = true } label: {
            ZStack {
                if let image = model.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity.animation(DS.Motion.thumbDeveloped))
                    if developing {
                        Color.black.opacity(0.45)
                        DSSpinner(size: 20)
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(DS.Color.label3)
                }
            }
            .frame(width: 52, height: 52)
            .rotationEffect(.degrees(iconAngle))
            .background(shape.fill(model.thumbnail == nil ? Color.clear : DS.Color.surface1))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(model.thumbnail == nil ? DS.Color.surface3 : Color.white.opacity(0.22),
                                   lineWidth: model.thumbnail == nil ? 1.5 : 1)
            )
            .scaleEffect(thumbPop ? 1 : 0.6)
        }
        .buttonStyle(DSPlainButtonStyle())
        .onChange(of: camera.isCapturing) { _, capturing in
            // A capture lands: the quick preview pops in.
            guard capturing else { return }
            thumbPop = false
            withAnimation(reduceMotion ? DS.Motion.reduced : DS.Motion.thumbIn.delay(0.12)) { thumbPop = true }
        }
        .accessibilityLabel("Last photo")
        .accessibilityValue(developing ? "Developing" : model.thumbnail == nil ? "None yet" : "")
        .accessibilityHint("Opens the Library")
    }

    @State private var thumbPop = true

    private var lookButton: some View {
        let changes = LookSetting.changeCount(model.params)
        return Button { showingLook = true } label: {
            Image(systemName: "camera.filters")
                .font(.system(size: 22, weight: .light))
                .rotationEffect(.degrees(iconAngle))
                .frame(width: 52, height: 52)
                .background(Circle().fill(DS.Color.surface2))
                .overlay(alignment: .topTrailing) {
                    if changes > 0 {
                        Text("\(changes)")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(DS.Color.accent))
                            .background(Capsule().stroke(Color.black, lineWidth: 4))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(DSScaleButtonStyle(scale: 0.94))
        .accessibilityLabel("Look settings")
        .accessibilityValue(filmName + (changes > 0 ? ", \(changes) \(changes == 1 ? "change" : "changes")" : ", Standard"))
    }

    private var filmCaption: some View {
        Button { showingLook = true } label: {
            HStack(spacing: 4) {
                Text(model.lookEnabled ? filmName : "Apple preview").ds(.chip)
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(DS.Color.label2)
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .buttonStyle(DSPlainButtonStyle())
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHint("Opens Look settings")
    }
}

// MARK: - Pieces

private struct FocusTap: Equatable {
    let id = UUID()
    let location: CGPoint
}

/// Amber focus/exposure box: lands with a small zoom, holds, dims to 50%, fades out.
private struct FocusBox: View {
    let reduceMotion: Bool
    @State private var scale: CGFloat = 1.35
    @State private var opacity: Double = 1

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).stroke(DS.Color.accent, lineWidth: 1.5)
            // 7 pt ticks at the midpoint of each edge, pointing inwards.
            ForEach(0..<4) { side in
                Rectangle().fill(DS.Color.accent)
                    .frame(width: side % 2 == 0 ? 1.5 : 7, height: side % 2 == 0 ? 7 : 1.5)
                    .offset(
                        x: side == 1 ? -34.5 : side == 3 ? 34.5 : 0,
                        y: side == 0 ? -34.5 : side == 2 ? 34.5 : 0
                    )
            }
        }
        .frame(width: 76, height: 76)
        .scaleEffect(scale)
        .opacity(opacity)
        .task {
            if reduceMotion {
                scale = 1
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scale = 1 }
            }
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeOut(duration: 0.25)) { opacity = 0.5 }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.35)) { opacity = 0 }
        }
    }
}

/// 80 pt white ring (4 pt) around a 64 pt disc that sinks to 0.88 when pressed.
private struct ShutterButtonStyle: ButtonStyle {
    let disabled: Bool
    let busy: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = (configuration.isPressed && !disabled) || busy
        return ZStack {
            Circle().strokeBorder(Color.white.opacity(disabled ? 0.3 : 1), lineWidth: 4)
            Circle()
                .fill(Color.white.opacity(disabled ? 0.22 : busy ? 0.55 : 1))
                .frame(width: 64, height: 64)
                .scaleEffect(pressed ? 0.88 : 1)
                .animation(DS.Motion.shutterPress, value: pressed)
        }
        .frame(width: 80, height: 80)
        .contentShape(Circle())
    }
}

/// Capture exposure: a ruler in thirds of a stop moving under a fixed amber needle.
/// 14 pt per third; long ticks and numbers at whole stops. Distinct from the Look panel's
/// development Exposure (a slider in stops) on purpose.
private struct EVDial: View {
    @Binding var bias: Float
    @State private var dragStart: Int?
    @State private var resets = 0

    private let spacing: CGFloat = 14
    private var thirds: Int { Int((bias * 3).rounded()) }

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            ZStack(alignment: .top) {
                readout
                    .zIndex(1)
                Canvas { context, size in
                    let origin = mid - CGFloat(thirds) * spacing
                    // Numbers on their own row above the ticks; ticks hang from a common baseline.
                    let labelY: CGFloat = 5, baseline = size.height - 2
                    for n in -9...9 {
                        let x = origin + CGFloat(n) * spacing
                        let whole = n % 3 == 0
                        let height: CGFloat = whole ? 12 : 7
                        let color: Color = n == 0 ? .white : whole ? DS.Color.label2 : DS.Color.label3
                        context.fill(Path(roundedRect: CGRect(x: x - 0.75, y: baseline - height, width: 1.5, height: height), cornerRadius: 1),
                                     with: .color(color))
                        guard whole else { continue }
                        // Centre the digit on its tick; the sign hangs to its left so "+1" and
                        // "−1" sit over their ticks the same way "0" does.
                        let digit = context.resolve(Text("\(abs(n / 3))").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(n == 0 ? DS.Color.label2 : DS.Color.label3))
                        let digitWidth = digit.measure(in: CGSize(width: 40, height: 20)).width
                        context.draw(digit, at: CGPoint(x: x, y: labelY), anchor: .center)
                        if n != 0 {
                            let sign = context.resolve(Text(n > 0 ? "+" : DSFormat.minus).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.Color.label3))
                            context.draw(sign, at: CGPoint(x: x - digitWidth / 2, y: labelY), anchor: .trailing)
                        }
                    }
                }
                .frame(height: 28)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22),
                                             .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .padding(.top, 30)
                .animation(.easeOut(duration: 0.14), value: thirds)
                // Covers only the tick row, so the "0" above it stays readable.
                RoundedRectangle(cornerRadius: 1).fill(DS.Color.accent)
                    .frame(width: 2, height: 17)
                    .padding(.top, 41)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { drag in
                        let start = dragStart ?? thirds
                        if dragStart == nil { dragStart = start }
                        let next = min(max(start - Int((drag.translation.width / spacing).rounded()), -9), 9)
                        if next != thirds { bias = Float(next) / 3 }
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .sensoryFeedback(trigger: thirds) { _, new in
            new == 0 || abs(new) == 9 ? .impact(flexibility: .rigid, intensity: 0.7) : .selection
        }
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: resets)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(DSFormat.thirdsSpoken(thirds))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: bias = Float(min(thirds + 1, 9)) / 3
            case .decrement: bias = Float(max(thirds - 1, -9)) / 3
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset to zero") { bias = 0 }
    }

    private var readout: some View {
        Button {
            guard thirds != 0 else { return }
            bias = 0
            resets += 1
        } label: {
            HStack(spacing: 5) {
                Text(thirds == 0 ? "EV ±0" : "\(DSFormat.thirds(thirds)) EV")
                    .ds(.chip)
                    .monospacedDigit()
                if thirds != 0 {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .heavy))
                }
            }
            .foregroundStyle(thirds == 0 ? DS.Color.label2 : DS.Color.accent)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(thirds == 0 ? Color.clear : DS.Color.accent.opacity(0.14)))
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .padding(.horizontal, -8)
            .padding(.vertical, -10)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityHidden(true)
    }
}

/// Shown once, just before the first save: where shots go, and that Limited Access is enough.
/// Continue brings up the system prompt; the first shot waits in memory meanwhile.
struct PhotosPrePromptView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(DS.Color.surface2)
                Image(systemName: "photo")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.white)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(DS.Color.accent).frame(width: 9, height: 9).offset(x: -9, y: 9)
                    }
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            Text("Your shots go to Photos")
                .ds(.title1)
                .padding(.top, 22)
                .padding(.bottom, 10)
            Text("Every shot is saved to your photo library as a RAW with Printlight’s look attached. Photos can always undo the look.")
                .ds(.body)
                .foregroundStyle(DS.Color.label2)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 0) {
                option("Limited Access is enough", "Printlight can always see the photos it takes.")
                Rectangle().fill(DS.Color.separator).frame(height: 1 / 3)
                option("Full Access adds your other RAWs", "Re-develop ProRAW from the Camera app and other apps too.")
            }
            .background(RoundedRectangle(cornerRadius: DS.radiusGroup, style: .continuous).fill(DS.Color.surface2))
            .padding(.top, 10)
            Spacer()
            Button(action: onContinue) {
                Text("Continue")
                    .ds(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            }
            .buttonStyle(DSPlainButtonStyle())
            .padding(.bottom, 24)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(DS.Color.label)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface1.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    private func option(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).ds(.subheadline)
            Text(detail).ds(.footnote).foregroundStyle(DS.Color.label2)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.rowPadding)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
