import CoreImage
import SwiftUI

/// Re-develops one shot. The photo re-renders live as settings change; Save updates the same
/// photo in Photos (the RAW original is never touched, and Photos can always revert).
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
    @State private var panelHidden = false
    @State private var saving = false
    @State private var confirmingLeave = false

    init(shot: Shot) {
        self.shot = shot
        _params = State(initialValue: shot.params)
        _saved = State(initialValue: shot.params)
    }

    private var dirty: Bool { params != saved }
    private var ready: Bool { renderer.isLoaded && !saving }

    var body: some View {
        GeometryReader { geo in
            let panelHeight = (geo.size.height * 0.47).rounded()
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    navRow
                    saveProgress
                    photo
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, panelHidden ? 60 : panelHeight + 8 - geo.safeAreaInsets.bottom)
                }
                .frame(maxHeight: .infinity, alignment: .top)

                LookControlsView(
                    params: $params,
                    mode: .editor(isDefault: params == model.params, useAsDefault: { model.params = params }),
                    swatchSource: { renderer.scene.map { ($0, false) } },
                    busy: !ready,
                    onClose: { setPanelHidden(true) }
                )
                .frame(height: panelHeight)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: DS.radiusPanel, topTrailingRadius: DS.radiusPanel, style: .continuous)
                        .fill(DS.Color.surface1)
                        .overlay(alignment: .top) {
                            UnevenRoundedRectangle(topLeadingRadius: DS.radiusPanel, topTrailingRadius: DS.radiusPanel, style: .continuous)
                                .stroke(DS.Color.separator, lineWidth: 0.5)
                                .frame(height: DS.radiusPanel)
                                .mask(Rectangle().frame(height: DS.radiusPanel / 2).frame(maxHeight: .infinity, alignment: .top))
                        }
                        .ignoresSafeArea(edges: .bottom)
                )
                .offset(y: panelHidden ? panelHeight + 40 : 0)
                .ignoresSafeArea(edges: .bottom)

                Button { setPanelHidden(false) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
                        Text("Show controls").ds(.subheadline).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: DS.touch)
                    .overlayMaterial(in: Capsule())
                }
                .buttonStyle(DSPlainButtonStyle())
                .padding(.bottom, 8)
                .opacity(panelHidden ? 1 : 0)
                .offset(y: panelHidden ? 0 : 20)
                .allowsHitTesting(panelHidden)
            }
        }
        .background(DS.Color.black.ignoresSafeArea())
        .foregroundStyle(DS.Color.label)
        .environment(\.colorScheme, .dark)
        .dsToast(text: $model.message, isError: model.messageIsError, top: 52)
        .confirmationDialog("Save your changes to this photo?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Save to Photos") { save(thenLeave: true) }
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Leaving now keeps the photo as it was.")
        }
        .task { await renderer.load(shot.dng, params: params) }
        .onChange(of: params) { _, new in renderer.request(new) }
    }

    // MARK: Pieces

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
        ZStack {
            VStack(spacing: 0) {
                Text(title).ds(.headline)
                Text(subtitle.0)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(subtitle.1 ? DS.Color.accent : DS.Color.label2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 96)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack {
                Button("Done") {
                    guard !saving else { return }
                    if dirty { confirmingLeave = true } else { dismiss() }
                }
                .ds(.headline)
                .padding(.horizontal, 8)
                .frame(minHeight: DS.touch)
                .buttonStyle(DSPlainButtonStyle())
                Spacer()
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

    private var photo: some View {
        ZStack {
            Image(uiImage: renderer.image ?? shot.thumbnail)
                .resizable()
                .scaledToFit()
                .opacity(renderer.isLoaded ? 1 : 0)
                .accessibilityLabel("Photo")
            if !renderer.isLoaded {
                VStack(spacing: 12) {
                    DSSpinner()
                    Text("Preparing RAW…").ds(.subheadline).foregroundStyle(DS.Color.label2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard renderer.isLoaded, !saving else { return }
            setPanelHidden(!panelHidden)
        }
        .accessibilityAction(named: panelHidden ? "Show controls" : "Hide controls") { setPanelHidden(!panelHidden) }
    }

    private func setPanelHidden(_ hidden: Bool) {
        withAnimation(reduceMotion ? DS.Motion.reduced : DS.Motion.sheet) { panelHidden = hidden }
    }

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
