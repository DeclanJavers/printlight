"""Spectral negative -> print film simulation for Printlight.

Simulates the photochemical chain a cinema image goes through:

    scene light -> camera negative (e.g. Kodak Vision3 250D) -> print film (Kodak 2383) -> projector -> eye

using measured film data: per-layer spectral sensitivities, characteristic (density) curves and
dye spectral densities. The film data comes from the spektrafilm project's profiles by Andrea
Volpato, licensed CC BY-SA 4.0 (see data/spektrafilm/SPEKTRAFILM_LICENSE.txt). This code is an
independent implementation; LUTs baked from it encode that data and inherit CC BY-SA 4.0.

Input: scene-linear RGB (linear sRGB/Rec.709 primaries, D65 white, mid grey = 0.18).
Output: display-linear RGB in the same primaries (may be <0 or >1 for colours outside sRGB).

Usage:
    python film.py chart out.png [negative] [print]
    python film.py linear in.f32 out.png [negative] [print]   # raw float32 dump from the Mac harness
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from functools import cached_property
from pathlib import Path

import numpy as np

DATA = Path(__file__).parent / "data" / "spektrafilm"
WAVELENGTHS = np.arange(380.0, 781.0, 5.0)  # matches the profiles
MID_GREY = 0.18

# Linear sRGB -> XYZ (D65), white Y = 1.
SRGB_TO_XYZ = np.array([
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041],
])
XYZ_TO_SRGB = np.linalg.inv(SRGB_TO_XYZ)
D65_WHITE = SRGB_TO_XYZ @ np.ones(3)

# Bradford chromatic adaptation.
BRADFORD = np.array([
    [0.8951, 0.2664, -0.1614],
    [-0.7502, 1.7135, 0.0367],
    [0.0389, -0.0685, 1.0296],
])


def cie1931_cmfs(wl: np.ndarray) -> np.ndarray:
    """CIE 1931 2-degree observer via the Wyman, Sloan & Shirley (2013) multi-lobe fit."""
    def g(x, mu, s1, s2):
        s = np.where(x < mu, s1, s2)
        return np.exp(-0.5 * ((x - mu) / s) ** 2)

    x = 1.056 * g(wl, 599.8, 37.9, 31.0) + 0.362 * g(wl, 442.0, 16.0, 26.7) - 0.065 * g(wl, 501.1, 20.4, 26.2)
    y = 0.821 * g(wl, 568.8, 46.9, 40.5) + 0.286 * g(wl, 530.9, 16.3, 31.1)
    z = 1.217 * g(wl, 437.0, 11.8, 36.0) + 0.681 * g(wl, 459.0, 26.0, 13.8)
    return np.stack([x, y, z], axis=-1)


def blackbody(wl_nm: np.ndarray, kelvin: float) -> np.ndarray:
    wl = wl_nm * 1e-9
    h, c, k = 6.62607015e-34, 2.99792458e8, 1.380649e-23
    spd = 1.0 / (wl**5 * (np.exp(h * c / (wl * k * kelvin)) - 1.0))
    return spd / spd.max()


def adaptation_matrix(src_xyz: np.ndarray, dst_xyz: np.ndarray) -> np.ndarray:
    s = BRADFORD @ src_xyz
    d = BRADFORD @ dst_xyz
    return np.linalg.inv(BRADFORD) @ np.diag(d / s) @ BRADFORD


def smooth_rgb_basis(cmfs: np.ndarray) -> np.ndarray:
    """Three smooth spectra whose mix reproduces linear sRGB exactly under the CIE observer.

    Solves min ||second difference||^2 subject to XYZ(basis_k) = XYZ(sRGB primary k).
    Linear in RGB, so camera -> film-layer exposure collapses to a 3x3 matrix.
    """
    n = len(WAVELENGTHS)
    d2 = np.diff(np.eye(n), 2, axis=0)
    q = d2.T @ d2 + 1e-6 * np.eye(n)
    a = cmfs.T  # 3 x n
    qi_at = np.linalg.solve(q, a.T)
    return qi_at @ np.linalg.solve(a @ qi_at, SRGB_TO_XYZ)  # n x 3


def fill_edges(a: np.ndarray) -> np.ndarray:
    """Replace NaNs in each column with the nearest valid value along the wavelength axis."""
    out = a.copy()
    idx = np.arange(len(a))
    for j in range(a.shape[1]):
        ok = ~np.isnan(a[:, j])
        out[:, j] = np.interp(idx, idx[ok], a[ok, j])
    return out


@dataclass
class Stock:
    name: str
    log_exposure: np.ndarray       # (256,)
    density_curves: np.ndarray     # (256, 3) density above base, layers [R(cyan), G(magenta), B(yellow)]
    sensitivity: np.ndarray        # (81, 3) linear spectral sensitivity per layer
    dye_density: np.ndarray        # (81, 3) spectral density per unit layer density
    base_density: np.ndarray       # (81,)

    @classmethod
    def load(cls, stock: str) -> "Stock":
        d = json.loads((DATA / f"{stock}.json").read_text())
        data = d["data"]
        assert np.allclose(data["wavelengths"], WAVELENGTHS)
        nan = lambda v: np.array([[np.nan if x is None else x for x in row] if isinstance(row, list) else (np.nan if row is None else row) for row in v], dtype=float)
        base = np.nan_to_num(nan(data["base_density"]), nan=0.0)
        return cls(
            name=d["info"]["name"],
            log_exposure=np.array(data["log_exposure"], dtype=float),
            density_curves=np.nan_to_num(nan(data["density_curves"]), nan=0.0),
            sensitivity=np.nan_to_num(10.0 ** nan(data["log_sensitivity"]), nan=0.0),
            # Not clipped: small negative values are the coloured-coupler (orange mask) correction.
            # Unmeasured wavelengths at the ends are held at the nearest measured value; treating
            # them as zero lets near-UV light leak through dense yellow dye.
            dye_density=fill_edges(nan(data["channel_density"])),
            base_density=base,
        )

    def density(self, log_h: np.ndarray) -> np.ndarray:
        """Per-layer density for per-layer log10 exposure (..., 3)."""
        out = np.empty(log_h.shape)
        for i in range(3):
            out[..., i] = np.interp(log_h[..., i], self.log_exposure, self.density_curves[:, i])
        return out

    def log_exposure_for_density(self, layer: int, target: float) -> float:
        curve = self.density_curves[:, layer]
        return float(np.interp(target, np.maximum.accumulate(curve), self.log_exposure))


@dataclass
class FilmChain:
    negative: str = "kodak_vision3_250d"
    print_stock: str = "kodak_2383"
    printer_kelvin: float = 3200.0     # tungsten printer lamp
    projector_kelvin: float = 5400.0   # xenon projector; adapted to D65 display white
    mid_grey_out: float = 0.15         # display-linear luminance the scene's mid grey prints to
    exposure: float = 0.0              # stops, applied to the scene before the negative
    coupler_strength: float = 0.25     # interlayer (DIR coupler) inhibition: raises colour saturation
    printer_offsets: np.ndarray = field(default_factory=lambda: np.zeros(3))  # printer-light trims (log10)

    @cached_property
    def neg(self) -> Stock:
        return Stock.load(self.negative)

    @cached_property
    def prt(self) -> Stock:
        return Stock.load(self.print_stock)

    @cached_property
    def cmfs(self) -> np.ndarray:
        return cie1931_cmfs(WAVELENGTHS)

    @cached_property
    def rgb_to_neg_exposure(self) -> np.ndarray:
        """3x3: linear sRGB -> negative layer exposure, normalised so mid grey = log10 H of 0."""
        m = self.neg.sensitivity.T @ smooth_rgb_basis(self.cmfs)
        grey = m @ np.full(3, MID_GREY)
        return m / grey[:, None]

    @cached_property
    def printer_light(self) -> np.ndarray:
        """(81, 3) light reaching each print layer: an additive printer splits the lamp into
        red, green and blue beams with dichroic filters, so each layer only sees its own band."""
        lamp = blackbody(WAVELENGTHS, self.printer_kelvin)
        edge = lambda x, at: 1.0 / (1.0 + np.exp(-(x - at) / 6.0))
        red = edge(WAVELENGTHS, 600.0)
        blue = 1.0 - edge(WAVELENGTHS, 500.0)
        green = edge(WAVELENGTHS, 500.0) * (1.0 - edge(WAVELENGTHS, 590.0))
        return lamp[:, None] * np.stack([red, green, blue], axis=-1)

    @cached_property
    def projector_light(self) -> np.ndarray:
        return blackbody(WAVELENGTHS, self.projector_kelvin)

    @cached_property
    def white_adaptation(self) -> np.ndarray:
        """Clear print base under the projector maps to D65 display white at Y = 1."""
        xyz = self._view_xyz(self.prt.base_density[None, :])[0]
        return adaptation_matrix(xyz, D65_WHITE)

    def _view_xyz(self, spectral_density: np.ndarray) -> np.ndarray:
        radiance = self.projector_light * 10.0 ** (-spectral_density)
        xyz = radiance @ self.cmfs
        white = (self.projector_light * 10.0 ** (-self.prt.base_density)) @ self.cmfs
        return xyz / white[1]

    def negative_density(self, rgb: np.ndarray) -> np.ndarray:
        h = rgb.reshape(-1, 3) @ self.rgb_to_neg_exposure.T * 2.0 ** self.exposure
        log_h = np.log10(np.maximum(h, 1e-6))
        d = self.neg.density(log_h)
        if self.coupler_strength:
            # DIR couplers: development in one layer inhibits the others, which increases
            # colour separation. Modelled as a log-exposure correction from the other layers.
            mean = d.mean(axis=-1, keepdims=True)
            d = self.neg.density(log_h + self.coupler_strength * (d - mean) / 0.6)
        return d

    def _print_log_exposure(self, neg_density: np.ndarray) -> np.ndarray:
        spectral = neg_density @ self.neg.dye_density.T + self.neg.base_density
        transmitted = 10.0 ** (-spectral)  # (n, 81)
        exposure = transmitted @ (self.printer_light * self.prt.sensitivity)  # per-layer beam x layer sensitivity
        return np.log10(np.maximum(exposure, 1e-12))

    def _display(self, print_layer_density: np.ndarray) -> np.ndarray:
        spectral = print_layer_density @ self.prt.dye_density.T + self.prt.base_density
        xyz = self._view_xyz(spectral) @ self.white_adaptation.T
        return xyz @ XYZ_TO_SRGB.T

    @cached_property
    def printer_lights(self) -> np.ndarray:
        """Per-layer log10 offsets that print scene mid grey as a neutral at `mid_grey_out`.

        This is what a film lab's printer-light timing does.
        """
        grey_neg = self.negative_density(np.full((1, 3), MID_GREY * 2.0 ** -self.exposure))
        base = self._print_log_exposure(grey_neg)[0]
        # Start from the layer densities that give the target, then Newton-solve for neutrality.
        offsets = np.array([self.prt.log_exposure_for_density(i, 1.0) for i in range(3)]) - base
        for _ in range(30):
            d = self.prt.density(base + offsets)
            rgb = self._display(d[None])[0]
            target = np.full(3, self.mid_grey_out)
            err = np.log10(np.maximum(rgb, 1e-6)) - np.log10(target)
            if np.abs(err).max() < 1e-4:
                break
            jac = np.empty((3, 3))
            for j in range(3):
                step = np.zeros(3); step[j] = 1e-3
                rgb2 = self._display(self.prt.density(base + offsets + step)[None])[0]
                jac[:, j] = (np.log10(np.maximum(rgb2, 1e-6)) - np.log10(np.maximum(rgb, 1e-6))) / 1e-3
            offsets -= np.linalg.lstsq(jac, err, rcond=None)[0]
        return offsets

    def render_mono(self, rgb: np.ndarray, weights=(0.30, 0.60, 0.10)) -> np.ndarray:
        """Black and white: panchromatic luminance printed through this chain's neutral tone curve.

        No black-and-white stock data is available, so tonality comes from the colour chain's
        grey response; the weights approximate a panchromatic emulsion's spectral response.
        """
        y = np.maximum(rgb.reshape(-1, 3) @ np.asarray(weights), 0.0)
        grey = self.render(np.repeat(y[:, None], 3, axis=1))
        lum = grey @ np.array([0.2126, 0.7152, 0.0722])
        return np.repeat(lum[:, None], 3, axis=1).reshape(rgb.shape)

    def render(self, rgb: np.ndarray) -> np.ndarray:
        shape = rgb.shape
        neg = self.negative_density(rgb)
        log_p = self._print_log_exposure(neg) + self.printer_lights + self.printer_offsets
        out = self._display(self.prt.density(log_p))
        return out.reshape(shape)


# ---------------------------------------------------------------- helpers

DEFAULT_BLACK_LIFT = 0.01


def black_lift(y: np.ndarray, amount: float = DEFAULT_BLACK_LIFT) -> np.ndarray:
    """Viewing flare as a fraction of white, applied after the film (the app does the same).

    Prints are made for a dark theatre; on a phone in normal light their deepest blacks read as
    crushed. Mirrors printlightFinish in Look.ci.metal.
    """
    return (y + amount) / (1.0 + amount)


def encode_srgb(y: np.ndarray) -> np.ndarray:
    y = np.clip(y, 0.0, 1.0)
    return np.where(y <= 0.0031308, 12.92 * y, 1.055 * np.power(y, 1 / 2.4) - 0.055)


def save_png(y: np.ndarray, path: str) -> None:
    from PIL import Image

    Image.fromarray((encode_srgb(y) * 255 + 0.5).astype(np.uint8)).save(path)


def load_linear_dump(path: str) -> np.ndarray:
    """Raw dump from the Mac harness: int32 width, int32 height, then float32 RGB rows (top to bottom)."""
    raw = Path(path).read_bytes()
    w, h = np.frombuffer(raw[:8], dtype=np.int32)
    return np.frombuffer(raw[8:], dtype=np.float32).reshape(h, w, 3).astype(np.float64)


def main(argv: list[str]) -> None:
    if len(argv) >= 3 and argv[1] == "chart":
        from look import test_chart

        chain = FilmChain(*argv[3:5]) if len(argv) > 3 else FilmChain()
        save_png(black_lift(chain.render(test_chart())), argv[2])
    elif len(argv) >= 4 and argv[1] == "linear":
        chain = FilmChain(*argv[4:6]) if len(argv) > 4 else FilmChain()
        save_png(black_lift(chain.render(load_linear_dump(argv[2]))), argv[3])
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv)
