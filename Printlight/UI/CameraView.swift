import SwiftUI

struct CameraView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var showingLook = false
    @State private var editingShot: Shot?
    @State private var focusTap: FocusTap?
    @State private var shutterPresses = 0
    @State private var blackout = false

    private let topBarHeight: CGFloat = 48
    /// Height the exposure dial and shutter row need below the viewfinder.
    private let controlsMinHeight: CGFloat = 172

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                // Lay out explicitly so the 3:4 viewfinder keeps full width whenever the
                // controls fit, and shrinks (centered) only on short screens.
                let available = geo.size.height - topBarHeight - controlsMinHeight
                let finderHeight = max(min(geo.size.width * 4 / 3, available), 0)

                VStack(spacing: 0) {
                    topBar
                        .frame(height: topBarHeight)
                    viewfinder
                        .frame(width: finderHeight * 3 / 4, height: finderHeight)
                    bottomControls
                        .frame(maxHeight: .infinity)
                }
                .frame(width: geo.size.width)
            }

            if let message = model.message {
                toast(message)
                    .padding(.top, topBarHeight + 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.message)
        .sheet(isPresented: $showingLook) {
            LookControlsView(params: $model.params)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground { PanelBackground() }
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $editingShot) { shot in
            EditorView(shot: shot, initialParams: model.params)
        }
        .onAppear { camera.start() }
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
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.easeOut(duration: 0.22)) { blackout = false }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 2) {
            rawBadge

            Spacer()

            Button {
                model.lookEnabled.toggle()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.lookEnabled ? Palette.accent : Color.white.opacity(0.35))
                        .frame(width: 5, height: 5)
                    Text(model.lookEnabled ? "LOOK" : "APPLE")
                        .readout(11, weight: .semibold)
                }
                .foregroundStyle(model.lookEnabled ? Palette.accent : Color.white.opacity(0.6))
                .frame(minWidth: 72, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.lookEnabled ? "Showing Printlight look" : "Showing Apple preview")
            .accessibilityHint("Switches the viewfinder between the Printlight look and Apple's preview")

            Button {
                showingLook = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Look settings")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .sensoryFeedback(.selection, trigger: model.lookEnabled)
    }

    private var rawBadge: some View {
        let mode = camera.rawMode
        let warn = mode == .unavailable && camera.status == .running
        let tint: Color = warn ? Palette.accent : Color.white.opacity(camera.status == .running ? 0.9 : 0.45)
        return HStack(spacing: 7) {
            Text(mode.label.uppercased())
            if mode == .proRAW {
                Rectangle()
                    .fill(tint.opacity(0.45))
                    .frame(width: 1, height: 9)
                Text("\(camera.megapixels)MP")
            }
        }
        .readout(10, weight: .semibold)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(warn ? Palette.accent.opacity(0.6) : Color.white.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .proRAW ? "\(mode.label), \(camera.megapixels) megapixels" : mode.label)
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                PreviewView(renderer: model.preview)
                    .gesture(SpatialTapGesture().onEnded { tap in
                        focusTap = FocusTap(point: tap.location)
                        camera.focus(at: model.preview.normalizedFramePoint(for: tap.location, in: geo.size))
                    })

                FrameLines()
                    .allowsHitTesting(false)

                if let focusTap {
                    FocusReticle()
                        .id(focusTap.id)
                        .position(focusTap.point)
                        .allowsHitTesting(false)
                        .task(id: focusTap) {
                            try? await Task.sleep(for: .seconds(1.2))
                            if self.focusTap == focusTap { self.focusTap = nil }
                        }
                }

                Color.black
                    .opacity(blackout ? 0.85 : 0)
                    .allowsHitTesting(false)

                statusOverlay

                VStack {
                    Spacer()
                    lensSelector
                        .padding(.bottom, 14)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: focusTap) { _, new in new != nil }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .denied:
            statusCard(
                icon: "camera",
                title: "CAMERA ACCESS OFF",
                detail: "Camera access is off. Turn it on in Settings > Printlight.",
                actionTitle: "OPEN SETTINGS"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .failed(let reason):
            statusCard(icon: "exclamationmark.triangle", title: "CAMERA UNAVAILABLE", detail: reason)
        case .starting, .running:
            EmptyView()
        }
    }

    private func statusCard(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(title)
                .readout(11, weight: .semibold)
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .readout(11, weight: .semibold)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: 320)
    }

    @ViewBuilder
    private var lensSelector: some View {
        if camera.lenses.count > 1 {
            HStack(spacing: 4) {
                ForEach(camera.lenses) { lens in
                    let active = lens.id == camera.currentLensID
                    Button {
                        camera.select(lens: lens)
                    } label: {
                        Text(active ? lens.label + "×" : lens.label)
                            .font(.system(size: active ? 12 : 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(active ? Palette.accent : Color.white.opacity(0.85))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.black.opacity(active ? 0.65 : 0.35)))
                            .overlay(
                                Circle().strokeBorder(
                                    active ? Palette.accent.opacity(0.55) : Color.white.opacity(0.12),
                                    lineWidth: 0.75
                                )
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lens.label)× lens")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Capsule().fill(Color.black.opacity(0.25)))
            .animation(.easeOut(duration: 0.15), value: camera.currentLensID)
            .sensoryFeedback(.selection, trigger: camera.currentLensID)
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)

            ExposureDial(bias: $camera.exposureBias)

            Spacer(minLength: 10)

            HStack {
                thumbnailButton
                Spacer()
                shutterButton
                Spacer()
                Color.clear.frame(width: 52, height: 52)
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 8)
        }
    }

    private var thumbnailButton: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            editingShot = model.lastShot
        } label: {
            ZStack {
                shape.fill(Color.white.opacity(0.05))
                if let thumb = model.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .transition(.opacity)
                }
                if model.developingCount > 0 {
                    Color.black.opacity(0.45)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(model.lastShot == nil ? 0.15 : 0.32), lineWidth: 1))
            .animation(.easeOut(duration: 0.3), value: model.lastShot?.id)
        }
        .buttonStyle(.plain)
        .disabled(model.lastShot == nil)
        .accessibilityLabel(model.developingCount > 0 ? "Last photo, developing" : "Last photo")
        .accessibilityHint("Opens the last shot to re-develop it")
    }

    private var shutterButton: some View {
        Button {
            shutterPresses += 1
            model.capture()
        } label: {
            EmptyView()
        }
        .buttonStyle(ShutterButtonStyle(busy: camera.isCapturing))
        .disabled(camera.isCapturing || camera.status != .running || camera.rawMode == .unavailable)
        .sensoryFeedback(.impact(weight: .medium), trigger: shutterPresses)
        .accessibilityLabel("Take photo")
    }

    // MARK: - Toast

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .padding(.horizontal, 24)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(2.5))
                model.message = nil
            }
    }
}

// MARK: - Pieces

private struct FocusTap: Equatable {
    let id = UUID()
    let point: CGPoint
}

/// Thin corner marks and rule-of-thirds hairlines, like a rangefinder's frame lines.
private struct FrameLines: View {
    var body: some View {
        ZStack {
            ThirdsGrid()
                .stroke(Color.white.opacity(0.09), lineWidth: 0.5)
            CornerMarks(inset: 12, length: 16)
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .square))
        }
    }
}

private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

private struct CornerMarks: Shape {
    let inset: CGFloat
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.minX, y: r.minY), 1, 1),
            (CGPoint(x: r.maxX, y: r.minY), -1, 1),
            (CGPoint(x: r.minX, y: r.maxY), 1, -1),
            (CGPoint(x: r.maxX, y: r.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return path
    }
}

/// Classic AF box: thin accent square with ticks at the middle of each edge. Lands with a small zoom.
private struct FocusReticle: View {
    @State private var landed = false

    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(Palette.accent, lineWidth: 1)
            ReticleTicks(length: 6)
                .stroke(Palette.accent, lineWidth: 1)
        }
        .frame(width: 72, height: 72)
        .scaleEffect(landed ? 1 : 1.35)
        .opacity(landed ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { landed = true }
        }
    }
}

private struct ReticleTicks: Shape {
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + length))
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - length))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.midY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.midY))
        return path
    }
}

/// White ring and inner disc; the disc sinks while pressed. Dims when disabled.
private struct ShutterButtonStyle: ButtonStyle {
    let busy: Bool

    func makeBody(configuration: Configuration) -> some View {
        ShutterBody(pressed: configuration.isPressed, busy: busy)
    }

    private struct ShutterBody: View {
        let pressed: Bool
        let busy: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let live = isEnabled || busy
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(live ? 1 : 0.3), lineWidth: 3)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(Color.white.opacity(busy ? 0.35 : (isEnabled ? 1 : 0.22)))
                    .frame(width: 64, height: 64)
                    .scaleEffect(pressed ? 0.86 : 1)
            }
            .contentShape(Circle())
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            .animation(.easeOut(duration: 0.2), value: busy)
            .animation(.easeOut(duration: 0.2), value: isEnabled)
        }
    }
}

/// Exposure compensation as a scrubbable tick ruler: −3…+3 EV in third stops.
/// Drag to scrub (a selection tick per third), double-tap to return to zero.
private struct ExposureDial: View {
    @Binding var bias: Float

    private let spacing: CGFloat = 14
    private let steps = 9 // third stops either side of zero

    @State private var dragStartIndex: Int?
    @State private var dragTranslation: CGFloat = 0

    private var index: Int { Int((bias * 3).rounded()) }

    /// Horizontal offset of the ruler so the current value sits under the centre mark.
    private var position: CGFloat {
        if let start = dragStartIndex {
            let limit = CGFloat(steps) * spacing
            return min(max(CGFloat(start) * spacing - dragTranslation, -limit), limit)
        }
        return CGFloat(index) * spacing
    }

    private var valueText: String {
        index == 0 ? "±0.0" : String(format: "%+.1f", Double(index) / 3).replacingOccurrences(of: "-", with: "−")
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("EV")
                    .foregroundStyle(Color.white.opacity(0.4))
                Text(valueText)
                    .foregroundStyle(index == 0 ? Color.white.opacity(0.85) : Palette.accent)
            }
            .readout(12, weight: .semibold)

            ZStack(alignment: .top) {
                ruler
                    .offset(x: -position)
                    .animation(
                        dragStartIndex == nil ? .spring(response: 0.3, dampingFraction: 0.85) : .interactiveSpring(),
                        value: position
                    )
                Capsule()
                    .fill(index == 0 ? Color.white : Palette.accent)
                    .frame(width: 2, height: 18)
                    .offset(y: -3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30, alignment: .top)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.22),
                        .init(color: .black, location: 0.78),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .frame(height: 56)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { drag in
                    if dragStartIndex == nil { dragStartIndex = index }
                    dragTranslation = drag.translation.width
                    let raw = CGFloat(dragStartIndex ?? 0) - drag.translation.width / spacing
                    set(Int(raw.rounded()))
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragStartIndex = nil
                        dragTranslation = 0
                    }
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { set(0) }
        }
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(index == 0 ? "0 EV" : String(format: "%+.1f EV", Double(index) / 3))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(index + 1)
            case .decrement: set(index - 1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset to zero") { set(0) }
    }

    private func set(_ newIndex: Int) {
        let clamped = min(max(newIndex, -steps), steps)
        if clamped != index { bias = Float(clamped) / 3 }
    }

    private var ruler: some View {
        let width = CGFloat(steps * 2) * spacing + 40
        let active = index == 0 ? 0...0 : min(0, index)...max(0, index)
        return Canvas { context, size in
            let center = size.width / 2
            for i in -steps...steps {
                let x = center + CGFloat(i) * spacing
                let major = i % 3 == 0
                let lit = index != 0 && active.contains(i)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 2))
                tick.addLine(to: CGPoint(x: x, y: major ? 14 : 8))
                let color: Color = lit ? Palette.accent : Color.white.opacity(major ? 0.75 : 0.3)
                context.stroke(tick, with: .color(color), lineWidth: 1)
                if major {
                    let stops = i / 3
                    let label = stops == 0 ? "0" : (stops > 0 ? "+\(stops)" : "−\(-stops)")
                    context.draw(
                        Text(label)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.4)),
                        at: CGPoint(x: x, y: 23)
                    )
                }
            }
        }
        .frame(width: width, height: 30)
    }
}
