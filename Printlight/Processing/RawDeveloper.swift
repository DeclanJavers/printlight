import CoreImage
import ImageIO
import os
import UIKit

/// Turns a DNG into a finished image: neutral RAW decode, then the film look.
enum RawDeveloper {
    enum DevelopError: LocalizedError {
        case unreadable, renderFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read the RAW file."
            case .renderFailed: "Couldn't render the image."
            }
        }
    }

    /// Shared context: linear, half-float working space, no caching of 48MP intermediates.
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    static let outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// Decode with every bit of Apple's rendering turned off: linear response,
    /// no local tone mapping, no sharpening, no gamut compression.
    /// The result is normalised by the exposure match so mid-tones sit where the look expects them.
    /// `scale` < 1 gives a fast, smaller decode for thumbnails and interactive editing.
    static func sceneLinear(from dng: Data, scale: Float = 1) -> CIImage? {
        let image: CIImage?
        let stops: Double
        if scale <= 0.2 {
            // Small decode: decode it once into memory while Apple's reference decode runs on
            // another core. The pixels then serve the exposure match and every later render, so
            // the RAW is never decoded twice. (Core Image RAW images are lazy and caching is off,
            // so rendering one twice decodes it twice.)
            var neutral: CIImage?
            var appleMedian: Double?
            let cached = cachedExposure(for: dng)
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                if i == 0 {
                    neutral = decode(dng, appleRendering: false, scale: scale).flatMap(materialize)
                } else if cached == nil {
                    appleMedian = decode(dng, appleRendering: true, scale: 0.08).flatMap(medianLuminance)
                }
            }
            image = neutral
            stops = cached ?? exposureMatch(for: dng, sceneMedian: neutral.flatMap(medianLuminance), appleMedian: appleMedian)
        } else {
            image = decode(dng, appleRendering: false, scale: scale)
            stops = exposureMatch(for: dng)
        }
        guard let image else { return nil }
        let gain = CGFloat(exp2(stops))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
        ])
    }

    /// Stops to add to the neutral decode so its median brightness matches Apple's
    /// own rendering of the same frame. ProRAW is deliberately exposed dark and Apple
    /// brightens it with its boost curve and local tone map; without this, Printlight
    /// renders everything about a stop dark. Only one number per shot is borrowed:
    /// none of Apple's local contrast ends up in the image.
    static func exposureMatch(for dng: Data) -> Double {
        if let cached = cachedExposure(for: dng) { return cached }
        var sceneMedian: Double?
        var appleMedian: Double?
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let image = decode(dng, appleRendering: i == 1, scale: 0.08)
            if i == 0 { sceneMedian = image.flatMap(medianLuminance) } else { appleMedian = image.flatMap(medianLuminance) }
        }
        return exposureMatch(for: dng, sceneMedian: sceneMedian, appleMedian: appleMedian)
    }

    private static func exposureMatch(for dng: Data, sceneMedian: Double?, appleMedian: Double?) -> Double {
        guard let sceneMedian, sceneMedian > 1e-5, let appleMedian else { return 0 }
        // All baked films print mid grey to the same value, so the default film's grey curve serves
        // for each. The curve is before black lift, so take the default lift back out of the target.
        let lift = LookParameters.standard.blackLift
        let target = FilmLibrary.shared.defaultFilm.sceneStops(forDisplayLuminance: appleMedian * (1 + lift) - lift)
        let current = log2(sceneMedian / 0.18)
        let stops = min(max(target - current, -1), 3)

        exposureCache.withLock { cache in
            if cache.count > 16 { cache.removeAll() }
            cache[cacheKey(for: dng)] = stops
        }
        return stops
    }

    private static func cachedExposure(for dng: Data) -> Double? {
        exposureCache.withLock { $0[cacheKey(for: dng)] }
    }

    /// Identifies a shot by its size and the end of its image data. Headers of different DNGs from
    /// the same camera are nearly identical, so hashing only the start would mix shots up.
    private static func cacheKey(for dng: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(dng.count)
        hasher.combine(dng.suffix(64 * 1024))
        return hasher.finalize()
    }

    private static let exposureCache = OSAllocatedUnfairLock(initialState: [Int: Double]())

    /// Renders a (small) image into memory once, so later uses don't re-run its filter graph.
    private static func materialize(_ image: CIImage) -> CIImage? {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 8
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: image.extent, format: .RGBAh, colorSpace: nil)
        }
        // No colour space: the values stay in the linear working space, exactly as decoded.
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: image.extent.size, format: .RGBAh, colorSpace: nil)
    }

    private static func decode(_ dng: Data, appleRendering: Bool, scale: Float) -> CIImage? {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else { return nil }
        if !appleRendering {
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.extendedDynamicRangeAmount = 0
            raw.isGamutMappingEnabled = false
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        }
        if scale < 1 {
            raw.scaleFactor = scale
            raw.isDraftModeEnabled = true
        }
        return raw.outputImage
    }

    /// Median Rec.709 luminance of a (small) linear image.
    private static func medianLuminance(of image: CIImage) -> Double? {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil)
        var luminance = (0..<(width * height)).map { i in
            0.2126 * pixels[i * 4] + 0.7152 * pixels[i * 4 + 1] + 0.0722 * pixels[i * 4 + 2]
        }
        luminance.sort()
        return Double(luminance[luminance.count / 2])
    }

    static func develop(_ dng: Data, params: LookParameters, scale: Float = 1, seed: UInt64 = 0) -> CIImage? {
        guard let scene = sceneLinear(from: dng, scale: scale) else { return nil }
        return FilmLook.shared.render(sceneLinear: scene, params: params, grainSeed: seed)
    }

    /// Full-resolution HEIC in Display P3, carrying over the DNG's EXIF/GPS.
    static func heic(from dng: Data, params: LookParameters) throws -> Data {
        guard let image = develop(dng, params: params, seed: UInt64.random(in: 0..<4096)) else { throw DevelopError.unreadable }

        // Carry over only descriptive metadata. Top-level DNG properties (pixel size,
        // bit depth, colour model) describe the raw file, not this image.
        var properties: [String: Any] = [:]
        if let source = CGImageSourceCreateWithData(dng as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            // MakerApple is left out: it holds asset identifiers Photos uses for grouping.
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                        kCGImagePropertyGPSDictionary] {
                if let value = props[key as String] { properties[key as String] = value }
            }
            if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                properties[kCGImagePropertyTIFFDictionary as String] = tiff
            }
        }
        // CIRAWFilter already applied the orientation, so the pixels are upright.
        properties[kCGImagePropertyOrientation as String] = 1

        guard let data = context.heifRepresentation(
            of: image.settingProperties(properties),
            format: .RGBA8,
            colorSpace: outputColorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        ) else { throw DevelopError.renderFailed }
        return data
    }

    static func uiImage(from image: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: outputColorSpace) else { return nil }
        return UIImage(cgImage: cg)
    }
}
