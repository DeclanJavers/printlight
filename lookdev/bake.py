"""Bake film chains from film.py into 3D LUTs for the app.

Each film becomes Printlight/Resources/Films/<id>.cube.bin plus an entry in films.json.

LUT input: per channel, scene stops relative to mid grey, log2(x / 0.18), mapped linearly from
[SHAPER_MIN, SHAPER_MAX] to [0, 1] (the app's printlightShaper kernel does this).
LUT output: display-linear RGB, linear sRGB primaries. Stored as float32 RGBA, red varying
fastest, then green, then blue: the layout CIColorCube expects.

The baked LUTs encode data from the spektrafilm profiles and are therefore CC BY-SA 4.0.

Usage: python bake.py [size]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

from film import MID_GREY, FilmChain

SHAPER_MIN, SHAPER_MAX = -10.0, 8.0
OUT = Path(__file__).parent.parent / "Printlight" / "Resources" / "Films"

FILMS = [
    {"id": "vision250d", "name": "Vision3 250D", "detail": "Cinema negative · 2383 print",
     "negative": "kodak_vision3_250d", "print": "kodak_2383"},
    {"id": "vision500t", "name": "Vision3 500T", "detail": "Fast cinema negative · 2383 print",
     "negative": "kodak_vision3_500t", "print": "kodak_2383"},
    {"id": "vision50d", "name": "Vision3 50D", "detail": "Fine-grain daylight cinema · 2383 print",
     "negative": "kodak_vision3_50d", "print": "kodak_2383"},
    {"id": "portra400", "name": "Portra 400", "detail": "Stills negative · Endura paper",
     "negative": "kodak_portra_400", "print": "kodak_portra_endura"},
    {"id": "ektar100", "name": "Ektar 100", "detail": "Vivid stills negative · Endura paper",
     "negative": "kodak_ektar_100", "print": "kodak_portra_endura"},
    {"id": "gold200", "name": "Gold 200", "detail": "Consumer negative · Supra Endura paper",
     "negative": "kodak_gold_200", "print": "kodak_supra_endura"},
    {"id": "pro400h", "name": "Fuji Pro 400H", "detail": "Stills negative · Crystal Archive paper",
     "negative": "fujifilm_pro_400h", "print": "fujifilm_crystal_archive_typeii"},
    {"id": "mono2383", "name": "Mono", "detail": "Panchromatic black and white · 2383 tone",
     "negative": "kodak_vision3_250d", "print": "kodak_2383", "mono": True},
]


def lattice(size: int) -> np.ndarray:
    """Scene-linear RGB at every lattice point, red fastest."""
    stops = np.linspace(SHAPER_MIN, SHAPER_MAX, size)
    b, g, r = np.meshgrid(stops, stops, stops, indexing="ij")
    return MID_GREY * np.exp2(np.stack([r, g, b], axis=-1).reshape(-1, 3))


def apply_lut(lut: np.ndarray, size: int, rgb: np.ndarray) -> np.ndarray:
    """Trilinear lookup, same maths as CIColorCube, for checking bake accuracy."""
    t = (np.log2(np.maximum(rgb, 1e-12) / MID_GREY) - SHAPER_MIN) / (SHAPER_MAX - SHAPER_MIN)
    p = np.clip(t, 0, 1) * (size - 1)
    i0 = np.minimum(np.floor(p).astype(int), size - 2)
    f = p - i0
    cube = lut.reshape(size, size, size, 3)  # [b, g, r]
    out = 0
    for db in (0, 1):
        for dg in (0, 1):
            for dr in (0, 1):
                w = (f[..., 0] if dr else 1 - f[..., 0]) * (f[..., 1] if dg else 1 - f[..., 1]) * (f[..., 2] if db else 1 - f[..., 2])
                out = out + w[..., None] * cube[i0[..., 2] + db, i0[..., 1] + dg, i0[..., 0] + dr]
    return out


def main(size: int) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {
        "shaper": {"minStops": SHAPER_MIN, "maxStops": SHAPER_MAX},
        "size": size,
        "credit": "Film data from spektrafilm profiles by Andrea Volpato, CC BY-SA 4.0. "
                  "These LUTs are derived from that data and are licensed CC BY-SA 4.0.",
        "films": [],
    }
    grey_stops = np.linspace(-8, 8, 65)
    for film in FILMS:
        chain = FilmChain(film["negative"], film["print"])
        render = chain.render_mono if film.get("mono") else chain.render
        lut = render(lattice(size))
        rgba = np.concatenate([lut, np.ones((len(lut), 1))], axis=1).astype(np.float32)
        (OUT / f"{film['id']}.cube.bin").write_bytes(rgba.tobytes())
        grey = render(np.repeat((MID_GREY * np.exp2(grey_stops))[:, None], 3, axis=1))
        luminance = grey @ np.array([0.2126, 0.7152, 0.0722])
        manifest["films"].append({
            **{k: film[k] for k in ("id", "name", "detail")},
            "file": f"{film['id']}.cube.bin",
            # Display luminance of a neutral at each scene stop: lets the app invert the film's tone curve.
            "greyStops": grey_stops.tolist(),
            "greyLuminance": np.maximum.accumulate(luminance).tolist(),
        })
        print(f"{film['name']}: {rgba.nbytes / 1e6:.2f} MB, lut range [{lut.min():.3f}, {lut.max():.3f}]")
    (OUT / "films.json").write_text(json.dumps(manifest, indent=1))
    (OUT / "LICENSE-FILMS.txt").write_text(
        manifest["credit"] + "\nhttps://github.com/andreavolpato/spektrafilm\n"
        "https://creativecommons.org/licenses/by-sa/4.0/\n")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 33)
