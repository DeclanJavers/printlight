import CoreImage
import SwiftUI

/// Renders the Look panel's film cards: the current frame through every film, 96 × 72 pt.
/// Keeps at most one render pass in flight; newer requests replace pending ones.
@MainActor
final class FilmSwatches: ObservableObject {
    /// Film id -> swatch. Missing until rendered (cards show a surface.2 placeholder).
    @Published private(set) var images: [String: UIImage] = [:]

    private struct Request {
        let source: CIImage
        let displayReferred: Bool
        let params: LookParameters
    }

    private var pending: Request?
    private var rendering = false
    private nonisolated static let size = CGSize(width: 96 * 3, height: 72 * 3)
    private nonisolated static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    /// - Parameters:
    ///   - source: the camera's latest preview frame (`displayReferred: true`, from
    ///     `PreviewRenderer.currentFrame()`), or the editor's scene-linear negative.
    ///   - params: the panel's settings; each card swaps in its own film.
    func update(source: CIImage, displayReferred: Bool, params: LookParameters) {
        pending = Request(source: source, displayReferred: displayReferred, params: params)
        pump()
    }

    private func pump() {
        guard !rendering, let request = pending else { return }
        pending = nil
        rendering = true
        Task.detached(priority: .utility) {
            let rendered = Self.render(request)
            await MainActor.run {
                self.images = rendered
                self.rendering = false
                self.pump()
            }
        }
    }

    private nonisolated static func render(_ request: Request) -> [String: UIImage] {
        // Aspect-fill the frame into the 4:3 swatch, from the centre.
        let extent = request.source.extent
        guard extent.width > 0, extent.height > 0 else { return [:] }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = request.source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: (scaled.extent.width - size.width) / 2, y: (scaled.extent.height - size.height) / 2,
            width: size.width, height: size.height
        )
        let small = scaled.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let colorSpace = RawDeveloper.outputColorSpace

        var result: [String: UIImage] = [:]
        for film in FilmLibrary.shared.films {
            var params = request.params
            params.film = film.id
            params.grain = 0
            let image = request.displayReferred
                ? FilmLook.shared.renderPreview(displayReferred: small, params: params, frame: 0)
                : FilmLook.shared.render(sceneLinear: small, params: params)
            if let cg = context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: colorSpace) {
                result[film.id] = UIImage(cgImage: cg, scale: 3, orientation: .up)
            }
        }
        return result
    }
}
