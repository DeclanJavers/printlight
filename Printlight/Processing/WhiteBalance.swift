import Foundation
import simd

/// White balance as a chromatic adaptation of scene-linear light, applied before the film.
///
/// The camera's own white balance stays the starting point (D65 in the decoded image). Warmth
/// moves the target white along the Planckian locus in mireds, tint moves it off the locus
/// towards magenta (positive) or green (negative), and a Bradford transform adapts to it.
enum WhiteBalance {
    /// Mireds of shift at full warmth: about 3900K to 18000K around D65.
    static let miredRange = 100.0

    /// Row-major 3x3 for linear sRGB, normalised so white keeps its luminance.
    static func matrix(warmth: Double, tint: Double) -> simd_double3x3 {
        guard warmth != 0 || tint != 0 else { return matrix_identity_double3x3 }

        let d65 = SIMD2(0.3127, 0.3290)
        let baseMired = 1e6 / 6504
        let kelvin = 1e6 / max(baseMired + warmth * miredRange, 30)
        // Move along the locus by the same amount the locus moves, so D65 itself is the origin.
        var target = d65 + planckianXY(kelvin) - planckianXY(6504)
        target.y -= 0.02 * tint

        let srgbToXYZ = simd_double3x3(rows: [
            SIMD3(0.4124564, 0.3575761, 0.1804375),
            SIMD3(0.2126729, 0.7151522, 0.0721750),
            SIMD3(0.0193339, 0.1191920, 0.9503041),
        ])
        let adapted = srgbToXYZ.inverse * bradford(from: xyz(d65), to: xyz(target)) * srgbToXYZ
        let whiteLuminance = simd_dot(SIMD3(0.2126729, 0.7151522, 0.0721750), adapted * SIMD3(repeating: 1))
        return adapted * (1 / whiteLuminance)
    }

    private static func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }

    private static func bradford(from source: SIMD3<Double>, to destination: SIMD3<Double>) -> simd_double3x3 {
        let m = simd_double3x3(rows: [
            SIMD3(0.8951, 0.2664, -0.1614),
            SIMD3(-0.7502, 1.7135, 0.0367),
            SIMD3(0.0389, -0.0685, 1.0296),
        ])
        let gains = (m * destination) / (m * source)
        return m.inverse * simd_double3x3(diagonal: gains) * m
    }

    /// CIE xy of a black body, Kim et al. (2002) cubic fit, valid 1667K to 25000K.
    private static func planckianXY(_ kelvin: Double) -> SIMD2<Double> {
        let t = min(max(kelvin, 1667), 25000)
        let x = t <= 4000
            ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return SIMD2(x, y)
    }
}
