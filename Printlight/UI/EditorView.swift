import CoreImage
import SwiftUI

/// Re-develop the last negative with different settings.
struct EditorView: View {
    let shot: Shot
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var params: LookParameters
    @StateObject private var renderer = EditorRenderer()
    @State private var showingControls = true
    @State private var madeDefault = 0

    init(shot: Shot) {
        self.shot = shot
        _params = State(initialValue: shot.params)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar

                image
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showingControls {
                    LookControlsView(params: $params)
                        .frame(height: min(geo.size.height * 0.44, 400))
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                                .fill(Palette.panel)
                                .overlay(
                                    UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                                        .strokeBorder(Palette.hairline, lineWidth: 0.5)
                                )
                                .ignoresSafeArea(edges: .bottom)
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let message = model.message {
                toast(message)
                    .padding(.top, 56)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.message)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(.success, trigger: madeDefault)
        .task { await renderer.load(shot.dng, params: params) }
        .onChange(of: params) { _, new in renderer.request(new) }
    }

    // MARK: - Pieces

    private var topBar: some View {
        let isDefault = params == model.params
        let saving = model.developingCount > 0
        return HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text("DONE")
                    .readout(12, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")

            Spacer()

            Button {
                model.params = params
                madeDefault += 1
            } label: {
                HStack(spacing: 5) {
                    if isDefault {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(isDefault ? "DEFAULT" : "USE AS DEFAULT")
                        .readout(11, weight: .semibold)
                }
                .foregroundStyle(Color.white.opacity(isDefault ? 0.4 : 0.85))
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDefault)
            .accessibilityLabel(isDefault ? "Current look is the default" : "Use as default")

            Button {
                let params = params
                Task { await model.saveEdit(of: shot, params: params) }
            } label: {
                ZStack {
                    Text("SAVE")
                        .readout(11, weight: .bold)
                        .opacity(saving ? 0 : 1)
                    if saving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    }
                }
                .foregroundStyle(.black)
                .frame(width: 66, height: 30)
                .background(Capsule().fill(Palette.accent.opacity(saving ? 0.55 : 1)))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityLabel(saving ? "Saving" : "Save")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .animation(.easeOut(duration: 0.2), value: isDefault)
    }

    private var image: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: renderer.image ?? shot.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !renderer.isLoaded {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                    Text("LOADING NEGATIVE")
                        .readout(9, weight: .semibold)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: renderer.isLoaded)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { showingControls.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Developed photo")
        .accessibilityHint(showingControls ? "Double-tap to hide the controls" : "Double-tap to show the controls")
        .accessibilityAddTraits(.isButton)
    }

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.78)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .padding(.horizontal, 24)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(2.5))
                if model.message == message { model.message = nil }
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

    private var scene: CIImage?
    private var pending: LookParameters?
    private var rendering = false

    func load(_ dng: Data, params: LookParameters) async {
        // 0.2 of a 48MP frame is about 1600px on the long side: screen size, and small enough
        // for the decode to double as the exposure-match reference.
        scene = await Task.detached(priority: .userInitiated) {
            RawDeveloper.sceneLinear(from: dng, scale: 0.2)
        }.value
        isLoaded = scene != nil
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
            let clock = ContinuousClock()
            let start = clock.now
            let image = RawDeveloper.uiImage(from: FilmLook.shared.render(sceneLinear: scene, params: params))
            let took = clock.now - start
            await MainActor.run {
                print("PRINTLIGHT EDITOR render \(took.formatted(.units(allowed: [.milliseconds])))")
                if let image { self.image = image }
                self.rendering = false
                self.pump()
            }
        }
    }
}
