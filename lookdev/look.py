"""Reference implementation of the Printlight look.

This is the source of truth for the math in Printlight/Processing/Look.ci.metal.
If you change a formula here, change it there too (and vice versa).

Input is scene-linear Rec.709/sRGB-primaries RGB, as produced by CIRAWFilter
with boost, local tone mapping and sharpening disabled (mid grey ~= 0.18).
Output is display-linear RGB in the same primaries, ready to be encoded to
sRGB / Display P3 by the caller.

Usage:
    python look.py chart out.png            # render a synthetic test chart
    python look.py dng in.dng out.png       # develop a DNG (needs rawpy, Python <= 3.13)
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

import numpy as np

# Linear sRGB <-> linear Display P3 (both D65).
SRGB_TO_P3 = np.array([
    [0.8224621, 0.1775380, 0.0000000],
    [0.0331941, 0.9668058, 0.0000000],
    [0.0170827, 0.0723974, 0.9105199],
])
P3_TO_SRGB = np.linalg.inv(SRGB_TO_P3)

LUMA = np.array([0.2627, 0.6780, 0.0593])  # Rec.2020-ish weights, close enough for P3
MID_GREY = 0.18
LOG_FLOOR = -14.0  # stops below mid grey treated as black


@dataclass
class LookParameters:
    exposure: float = 0.0        # stops
    contrast: float = 1.22       # log-log slope of the curve at mid grey (roughly)
    mid_out: float = 0.16        # display-linear value mid grey lands on
    peak: float = 1.04           # curve asymptote; >1 so white is reachable
    saturation: float = 1.20     # subtractive (dye-density) saturation, 1 = neutral
    hue_fidelity: float = 0.25   # 0 = per-channel curve (film-like hue skews), 1 = ratio-preserving
    halation: float = 0.12       # amount of red halo added around bright sources
    halation_threshold: float = 1.0  # stops above which light starts to halate (relative to clip ~ +2.5)
    grain: float = 0.012         # grain amplitude in sqrt-encoded display space


def curve_pivot(p: LookParameters) -> float:
    """Log2 exposure (relative to mid grey) where the sigmoid hits peak/2."""
    return np.log2(p.peak / p.mid_out - 1.0) / p.contrast


def tone_curve(e: np.ndarray, p: LookParameters) -> np.ndarray:
    """Log-logistic sigmoid. e is stops relative to mid grey; returns display-linear."""
    e0 = curve_pivot(p)
    return p.peak / (1.0 + np.exp2(-p.contrast * (e - e0)))


def inverse_tone_curve(y: np.ndarray, p: LookParameters) -> np.ndarray:
    """Stops relative to mid grey for a display-linear value (used by the live preview)."""
    e0 = curve_pivot(p)
    y = np.clip(y, 1e-5, p.peak - 1e-4)
    return e0 - np.log2(p.peak / y - 1.0) / p.contrast


def halation_source(x: np.ndarray, p: LookParameters) -> np.ndarray:
    """Energy above the threshold, scene-linear, sRGB primaries. Caller blurs it."""
    thr = MID_GREY * np.exp2(2.0 + p.halation_threshold)
    lum = x @ np.array([0.2126, 0.7152, 0.0722])
    over = np.maximum(lum - thr, 0.0)[..., None]
    return over * np.array([1.0, 0.22, 0.04])


def film_look(x: np.ndarray, p: LookParameters, halo: np.ndarray | None = None) -> np.ndarray:
    """Per-pixel transform. x: (..., 3) scene-linear sRGB primaries. halo: blurred halation_source."""
    x = x * np.exp2(p.exposure)
    if halo is not None:
        x = x + halo * p.halation

    # Work in P3 primaries so saturated output can use the wider gamut.
    x = x @ SRGB_TO_P3.T

    # Stops relative to mid grey, per channel.
    e = np.log2(np.maximum(x, MID_GREY * np.exp2(LOG_FLOOR)) / MID_GREY)

    # Subtractive saturation: push the non-dominant channels down (more dye),
    # never the dominant one up. Neutrals are untouched; saturated colours get
    # denser, which is what makes film colour feel rich instead of neon.
    emax = np.max(e, axis=-1, keepdims=True)
    e = e + (p.saturation - 1.0) * (e - emax)

    # Per-channel curve: highlights desaturate towards white like film does.
    per_channel = tone_curve(e, p)

    # Ratio-preserving curve on the max channel: keeps hue stable.
    xs = MID_GREY * np.exp2(e)
    xmax = np.max(xs, axis=-1, keepdims=True)
    ratio = tone_curve(np.log2(xmax / MID_GREY), p) / xmax
    preserved = xs * ratio

    y = per_channel + (preserved - per_channel) * p.hue_fidelity
    y = np.clip(y, 0.0, 1.0)

    return y @ P3_TO_SRGB.T  # back to working primaries; may be <0 / >1 for P3 colours


def apply_grain(y: np.ndarray, noise: np.ndarray, p: LookParameters) -> np.ndarray:
    """y: display-linear. noise: (..., 3) zero-mean, unit-ish std grain field."""
    # Sign-preserving sqrt so negative (out-of-sRGB, inside-P3) components survive.
    v = np.sign(y) * np.sqrt(np.abs(y))
    lum_v = np.clip(v @ np.array([0.2126, 0.7152, 0.0722]), 0.0, 1.0)
    # Grain is strongest in the mids, fades in deep shadows and clipped whites.
    env = 0.35 + 2.6 * lum_v * (1.0 - lum_v)
    mono = noise[..., :1]
    g = mono * 0.8 + noise * 0.2
    v = v + g * p.grain * env[..., None]
    return np.sign(v) * v * v


def grain_field(h: int, w: int, rng: np.random.Generator) -> np.ndarray:
    from scipy.ndimage import gaussian_filter, zoom

    scale = max(w / 2000.0, 1.0)  # grain size is a fraction of frame width, not of pixels
    sh, sw = int(np.ceil(h / scale)) + 1, int(np.ceil(w / scale)) + 1
    n = rng.uniform(0.0, 1.0, (sh, sw, 3)) - 0.5
    n = np.stack([gaussian_filter(n[..., c], 0.6) for c in range(3)], axis=-1)
    if scale > 1.0:
        n = zoom(n, (scale, scale, 1), order=1)
    n = n[:h, :w]
    return n / (n.std() + 1e-9)


def develop(x: np.ndarray, p: LookParameters, seed: int = 0) -> np.ndarray:
    from scipy.ndimage import gaussian_filter

    h, w = x.shape[:2]
    src = halation_source(x * np.exp2(p.exposure), p)
    radius = 0.006 * w
    halo = np.stack([gaussian_filter(src[..., c], radius) for c in range(3)], axis=-1)
    y = film_look(x, p, halo)
    if p.grain > 0:
        y = apply_grain(y, grain_field(h, w, np.random.default_rng(seed)), p)
    return y


def encode_srgb(y: np.ndarray) -> np.ndarray:
    y = np.clip(y, 0.0, 1.0)
    return np.where(y <= 0.0031308, 12.92 * y, 1.055 * np.power(y, 1 / 2.4) - 0.055)


def test_chart(w: int = 1600, h: int = 900) -> np.ndarray:
    """Exposure ramp, hue sweep at three saturations, and a few bright sources."""
    img = np.zeros((h, w, 3))
    # Top band: grey ramp from -8 to +6 stops around mid grey.
    stops = np.linspace(-8, 6, w)
    img[: h // 5] = (MID_GREY * np.exp2(stops))[None, :, None]
    # Hue sweeps, each row a different exposure, three saturation levels.
    hue = np.linspace(0, 1, w)
    k = np.stack([np.abs(hue * 6 - 3) - 1, 2 - np.abs(hue * 6 - 2), 2 - np.abs(hue * 6 - 4)], -1)
    k = np.clip(k, 0, 1)
    rows = [(-2, 0.4), (0, 0.4), (2, 0.4), (0, 0.85), (2, 0.85), (0, 1.0)]
    band = (h - h // 5) // len(rows)
    for i, (ev, sat) in enumerate(rows):
        c = (1 - sat) + sat * k
        c = c / (c @ np.array([0.2126, 0.7152, 0.0722]))[:, None]
        y0 = h // 5 + i * band
        img[y0 : y0 + band] = (MID_GREY * np.exp2(ev) * c)[None]
    # Point lights for halation.
    for cx in (200, 800, 1400):
        yy, xx = np.ogrid[:h, :w]
        img[(yy - h // 2) ** 2 + (xx - cx) ** 2 < 12**2] = MID_GREY * 2**7
    return img


def save_png(y: np.ndarray, path: str) -> None:
    from PIL import Image

    Image.fromarray((encode_srgb(y) * 255 + 0.5).astype(np.uint8)).save(path)


def main(argv: list[str]) -> None:
    p = LookParameters()
    if len(argv) >= 3 and argv[1] == "chart":
        save_png(develop(test_chart(), p), argv[2])
    elif len(argv) >= 4 and argv[1] == "dng":
        import rawpy

        with rawpy.imread(argv[2]) as raw:
            lin = raw.postprocess(gamma=(1, 1), no_auto_bright=True, output_bps=16,
                                  use_camera_wb=True, output_color=rawpy.ColorSpace.sRGB)
        x = lin.astype(np.float64) / 65535.0
        # Normalise so the median sits at mid grey, like auto-exposure would.
        x *= MID_GREY / max(np.median(x @ np.array([0.2126, 0.7152, 0.0722])), 1e-6)
        save_png(develop(x, p), argv[3])
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv)
