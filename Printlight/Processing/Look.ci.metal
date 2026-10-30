// Core Image kernels for the Printlight look.
// Colour and tone come from the film LUTs (lookdev/film.py, baked by lookdev/bake.py);
// halation and grain mirror lookdev/look.py. Keep these in sync with those references.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

#define MID_GREY 0.18f
#define LOG_FLOOR -14.0f

namespace printlight {

inline float curvePivot(float contrast, float midOut, float peak) {
    return log2(peak / midOut - 1.0f) / contrast;
}

}

extern "C" { namespace coreimage {

/// Log2 luminance of scene light, blurred by the caller to give the clarity reference.
float4 printlightLogLuma(sample_t scene) {
    float lum = dot(scene.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float l = log2(max(lum, MID_GREY * exp2(LOG_FLOOR)));
    return float4(l, l, l, 1.0f);
}

/// Scene-linear -> LUT input: per-channel stops around mid grey, mapped from [minStops, maxStops]
/// to [0, 1]. Everything here works on scene light, before the film LUT:
///   - clarity: local contrast against a small blur of log luminance. The detail signal is
///     soft-limited to about half a stop, which is what keeps edges from growing halos;
///   - white balance: a chromatic adaptation matrix (rows wb0..wb2, see WhiteBalance.swift);
///   - exposure and halation.
/// Mirrors the shaper in lookdev/bake.py.
/// shaping = (exposure, halation, minStops, maxStops)
float4 printlightShaper(sample_t scene, sample_t halo, sample_t blurredLogLuma, float4 shaping,
                        float3 wb0, float3 wb1, float3 wb2, float clarity) {
    float lum = dot(scene.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float detail = log2(max(lum, MID_GREY * exp2(LOG_FLOOR))) - blurredLogLuma.r;
    detail = detail / (1.0f + abs(detail) * 2.0f);
    float3 x = scene.rgb * exp2(clarity * detail);
    x = float3(dot(wb0, x), dot(wb1, x), dot(wb2, x));
    x = x * exp2(shaping.x) + halo.rgb * shaping.y;
    float3 stops = log2(max(x, float3(MID_GREY * exp2(LOG_FLOOR))) / MID_GREY);
    return float4(clamp((stops - shaping.z) / (shaping.w - shaping.z), 0.0f, 1.0f), scene.a);
}

/// Energy above the halation threshold, to be blurred and fed back in by printlightShaper.
/// It saturates (rolling off towards 4x the threshold level) as real halation does: light
/// scattered back from the film base can't exceed what the emulsion passes, so the sun glows
/// like a bright lamp instead of fogging half the frame. Mirrors halation_source in look.py.
float4 printlightHalationSource(sample_t scene, float exposure, float thresholdStops) {
    float3 x = scene.rgb * exp2(exposure);
    float lum = dot(x, float3(0.2126f, 0.7152f, 0.0722f));
    float threshold = MID_GREY * exp2(2.0f + thresholdStops);
    float over = max(lum - threshold, 0.0f);
    float ceiling = 4.0f * threshold;
    over = over / (1.0f + over / ceiling);
    return float4(over * float3(1.0f, 0.22f, 0.04f), 1.0f);
}

/// Live preview only: undo an approximate display rendering so already-processed
/// video frames can go through the same look. Uses the default curve, not the user's.
float4 printlightUnrender(sample_t display) {
    const float contrast = 1.22f, midOut = 0.16f, peak = 1.04f;
    float pivot = printlight::curvePivot(contrast, midOut, peak);
    float3 y = clamp(display.rgb, 1e-5f, peak - 1e-4f);
    float3 e = pivot - log2(peak / y - 1.0f) / contrast;
    return float4(MID_GREY * exp2(e), display.a);
}

/// Display-linear finishing after the film LUT: black lift (viewing flare, mirrors black_lift in
/// lookdev/film.py), then grain in sqrt-encoded space. noise is blurred uniform noise in [0,1].
float4 printlightFinish(sample_t image, sample_t noise, float amount, float lift) {
    float3 y = (image.rgb + lift) / (1.0f + lift);
    float3 v = sign(y) * sqrt(abs(y));
    float lv = clamp(dot(v, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f, 1.0f);
    float env = 0.35f + 2.6f * lv * (1.0f - lv);
    // Blurred uniform noise has std ~0.14; rescale to roughly unit std, mostly monochrome.
    float3 n = (noise.rgb - 0.5f) * 7.0f;
    float3 g = n.r * 0.8f + n * 0.2f;
    v += g * amount * env;
    return float4(sign(v) * v * v, image.a);
}

/// Viewfinder zebras: diagonal stripes where the camera's own preview frame is at or near
/// clipping in any channel. The frame is Apple-processed SDR video, so this is a guide to blown
/// highlights rather than a reading of the raw sensor.
float4 printlightZebra(sampler shown, sampler source, float phase, destination dest) {
    float4 c = shown.sample(shown.coord());
    float4 s = source.sample(source.coord());
    if (max(s.r, max(s.g, s.b)) < 0.98f) {
        return c;
    }
    float2 p = dest.coord();
    float stripe = fmod(p.x + p.y + phase, 12.0f) < 6.0f ? 1.0f : 0.0f;
    return float4(mix(c.rgb, float3(stripe), 0.55f), c.a);
}

}}
