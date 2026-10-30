import CoreImage
import simd

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
    private let finish: CIColorKernel
    private let logLuma: CIColorKernel
    /// Optional so a kernel-loading problem only costs the zebras, not the camera.
    private let zebra: CIKernel?

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
        finish = kernel("printlightFinish")
        logLuma = kernel("printlightLogLuma")
        zebra = try? CIKernel(functionName: "printlightZebra", fromMetalLibraryData: data)
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

        // Clarity reference: log luminance blurred over ~0.1% of the frame width, a scale that
        // restores lens-level micro-contrast without touching broader tonality.
        let blurredLogLuma = params.clarity > 0
            ? (logLuma.apply(extent: extent, arguments: [image]) ?? image)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: max(Double(width) * 0.001, 0.6))
                .cropped(to: extent)
            : CIImage.black.cropped(to: extent)

        let wb = WhiteBalance.matrix(warmth: params.warmth, tint: params.tint)
        func row(_ i: Int) -> CIVector { CIVector(x: wb[0, i], y: wb[1, i], z: wb[2, i]) }

        let library = FilmLibrary.shared
        let film = library.film(id: params.film)
        let shaping = CIVector(x: params.exposure, y: params.halation, z: library.minStops, w: library.maxStops)
        guard let shaped = shaper.apply(
            extent: extent,
            arguments: [image, halo, blurredLogLuma, shaping, row(0), row(1), row(2), Float(params.clarity)]
        ) else { return image }
        var printed = shaped.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": library.cubeSize,
            "inputCubeData": library.cube(for: film),
            "inputExtrapolate": false,
        ])

        if let name = params.customLUT, let cube = CustomLUTLibrary.shared.cube(named: name) {
            printed = applyCustomLUT(cube, to: printed, strength: params.customLUTStrength)
        }

        let noise = params.grain > 0
            ? grainNoise(for: extent, seed: grainSeed)
            : CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        return finish.apply(
            extent: extent,
            arguments: [printed, noise, Float(params.grain), Float(params.blackLift)]
        ) ?? printed
    }

    /// A creative `.cube` grade on the film's output, in the sRGB encoding such LUTs expect.
    private func applyCustomLUT(_ cube: CustomLUTLibrary.Cube, to image: CIImage, strength: Double) -> CIImage {
        let graded = image
            .applyingFilter("CIColorClamp")
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": cube.size,
                "inputCubeData": cube.data,
                "inputExtrapolate": false,
            ])
            .applyingFilter("CISRGBToneCurveToLinear")
        guard strength < 1 else { return graded }
        return graded.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image,
            kCIInputTimeKey: 1 - max(strength, 0),
        ])
    }

    /// Stripes over areas where `source` (the camera's preview frame) is clipping.
    func zebras(on shown: CIImage, source: CIImage, phase: Float) -> CIImage {
        guard let zebra else { return shown }
        return zebra.apply(
            extent: shown.extent,
            roiCallback: { _, rect in rect },
            arguments: [shown, source, phase]
        ) ?? shown
    }

    /// Live preview: video frames are already rendered by Apple, so approximately undo that
    /// rendering first, then run the real look. iOS offers no scene-referred preview alongside
    /// RAW stills (Apple Log disables photo capture; HLG formats offer no RAW), so this stays approximate.
    func renderPreview(displayReferred image: CIImage, params: LookParameters, frame: UInt64) -> CIImage {
        guard let scene = unrender.apply(extent: image.extent, arguments: [image]) else { return image }
        return render(sceneLinear: scene, params: params, grainSeed: frame)
    }

    /// Blurred uniform noise in [0, 1]. Grain size is a fraction of the frame, not a pixel size,
    /// so 12MP and 48MP look alike.
    private func grainNoise(for extent: CGRect, seed: UInt64) -> CIImage {
        let scale = max(extent.width / 2000, 1)
        let offset = CGFloat(seed % 4096)
        let random = CIFilter(name: "CIRandomGenerator")?.outputImage
            ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        return random
            .transformed(by: CGAffineTransform(translationX: -offset * 7, y: -offset * 13))
            .applyingGaussianBlur(sigma: 0.6)
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
