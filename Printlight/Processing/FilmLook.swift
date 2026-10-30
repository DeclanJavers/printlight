import CoreImage

/// Builds the Core Image graph for the look. Used identically by the live preview
/// and the full-resolution develop, so what you dial in is what you get.
///
/// Colour and tone come from a 3D LUT per film, baked from the spectral negative -> print
/// simulation in lookdev/film.py. Halation and grain are spatial, so they run here around it.
final class FilmLook {
    static let shared = FilmLook()

    private let shaper: CIColorKernel
    private let halationSource: CIColorKernel
    private let unrender: CIColorKernel
    private let grain: CIColorKernel

    private init() {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("default.metallib missing: check MTL_COMPILER_FLAGS and MTLLINKER_FLAGS are both -fcikernel")
        }
        func kernel(_ name: String) -> CIColorKernel {
            do {
                return try CIColorKernel(functionName: name, fromMetalLibraryData: data)
            } catch {
                fatalError("Could not load kernel \(name): \(error)")
            }
        }
        shaper = kernel("printlightShaper")
        halationSource = kernel("printlightHalationSource")
        unrender = kernel("printlightUnrender")
        grain = kernel("printlightGrain")
    }

    /// Scene-linear in, display-linear out (Core Image working space).
    func render(sceneLinear image: CIImage, params: LookParameters, grainSeed: UInt64 = 0) -> CIImage {
        let extent = image.extent
        let width = extent.width

        // Halation: threshold, blur by a fraction of the frame width, feed back in before the curve.
        let source = halationSource.apply(
            extent: extent,
            arguments: [image, Float(params.exposure), Float(params.halationThreshold)]
        ) ?? CIImage.black.cropped(to: extent)
        let halo = source
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(width) * 0.006)
            .cropped(to: extent)

        let library = FilmLibrary.shared
        let film = library.film(id: params.film)
        let shaping = CIVector(x: params.exposure, y: params.halation, z: library.minStops, w: library.maxStops)
        guard let shaped = shaper.apply(extent: extent, arguments: [image, halo, shaping]) else { return image }
        var output = shaped.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": library.cubeSize,
            "inputCubeData": library.cube(for: film),
            "inputExtrapolate": false,
        ])

        if params.grain > 0 {
            output = applyGrain(to: output, amount: params.grain, seed: grainSeed)
        }
        return output
    }

    /// Live preview: video frames are already rendered by Apple, so approximately
    /// undo that rendering first, then run the real look.
    func renderPreview(displayReferred image: CIImage, params: LookParameters, frame: UInt64) -> CIImage {
        guard let scene = unrender.apply(extent: image.extent, arguments: [image]) else { return image }
        return render(sceneLinear: scene, params: params, grainSeed: frame)
    }

    private func applyGrain(to image: CIImage, amount: Double, seed: UInt64) -> CIImage {
        let extent = image.extent
        // Grain size is a fraction of the frame, not a pixel size, so 12MP and 48MP look alike.
        let scale = max(extent.width / 2000, 1)
        let offset = CGFloat(seed % 4096)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let noise = random
            .transformed(by: CGAffineTransform(translationX: -offset * 7, y: -offset * 13))
            .applyingGaussianBlur(sigma: 0.6)
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        return grain.apply(extent: extent, arguments: [image, noise, Float(amount)]) ?? image
    }
}
