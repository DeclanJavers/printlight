"""Printlight app icon (film_frame) and the concepts it was chosen over, drawn at 4x and
downsampled to 1024 for clean edges.

Usage: python make_icon.py   # writes the three concepts next to this script
The app uses film_frame(): copy A_film_frame.png to
Printlight/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
import math
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))
S = 4096  # supersampled canvas
AMBER = np.array([255, 179, 64]) / 255.0


def background(top=0.075, bottom=0.035):
    """Near-black, true neutral, with a faint top-to-bottom falloff and vignette."""
    y, x = np.mgrid[0:S, 0:S] / S
    base = top + (bottom - top) * y
    vignette = 1 - 0.35 * ((x - 0.5) ** 2 + (y - 0.45) ** 2)
    v = base * vignette
    return np.dstack([v, v, v])


def glow(mask, radius, color, strength):
    """Halation-style glow: blurred copy of a mask, tinted."""
    m = Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius))
    g = np.asarray(m).astype(float) / 255.0
    return g[..., None] * np.asarray(color)[None, None, :] * strength


def to_image(rgb):
    rgb = np.clip(rgb, 0, 1)
    img = Image.fromarray((rgb ** (1 / 1.0) * 255 + 0.5).astype(np.uint8))
    return img.resize((1024, 1024), Image.LANCZOS)


def mask_from(draw_fn):
    m = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    return np.asarray(m).astype(float) / 255.0


def lit_gradient(cx, cy, r_in, warm=True):
    """Amber light with a hotter centre, like a backlit negative or a safelight."""
    y, x = np.mgrid[0:S, 0:S].astype(float)
    d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / r_in
    hot = np.array([1.0, 0.80, 0.42])
    edge = np.array([0.90, 0.42, 0.08])
    t = np.clip(d, 0, 1)[..., None] ** 1.4
    return hot * (1 - t) + edge * t


# ---------------------------------------------------------------- A: film frame

def film_frame():
    rgb = background()
    band_top, band_bot = int(S * 0.21), int(S * 0.79)
    strip = mask_from(lambda d: d.rectangle([0, band_top, S, band_bot], fill=255))
    film = np.array([0.105, 0.105, 0.105])
    rgb = rgb * (1 - strip[..., None]) + film * strip[..., None]

    # Sprocket holes along both edges of the strip.
    # Holes live in their own margins above and below the image area, as on real stock.
    hole_w, hole_h, pitch = int(S * 0.046), int(S * 0.058), int(S * 0.094)
    inset = int(S * 0.022)
    holes = Image.new("L", (S, S), 0)
    hd = ImageDraw.Draw(holes)
    for row_y in (band_top + inset, band_bot - inset - hole_h):
        x = -pitch // 2
        while x < S:
            hd.rounded_rectangle([x, row_y, x + hole_w, row_y + hole_h], radius=int(hole_w * 0.28), fill=255)
            x += pitch
    hm = np.asarray(holes).astype(float) / 255.0
    rgb = rgb * (1 - hm[..., None]) + np.array([0.02, 0.02, 0.02]) * hm[..., None]

    # The lit frame: 3:2-ish, rounded, glowing amber; neighbouring frames dark.
    fw, fh = int(S * 0.60), int(S * 0.36)
    cx, cy = S // 2, S // 2
    frame = mask_from(lambda d: d.rounded_rectangle([cx - fw // 2, cy - fh // 2, cx + fw // 2, cy + fh // 2],
                                                   radius=int(S * 0.03), fill=255))
    gap = int(S * 0.05)
    for side in (-1, 1):
        ox = side * (fw + gap)
        dark = mask_from(lambda d, ox=ox: d.rounded_rectangle([cx - fw // 2 + ox, cy - fh // 2, cx + fw // 2 + ox, cy + fh // 2],
                                                              radius=int(S * 0.03), fill=255))
        rgb = rgb * (1 - dark[..., None]) + np.array([0.055, 0.05, 0.045]) * dark[..., None]
    light = lit_gradient(cx, cy, fw * 0.62)
    rgb = rgb * (1 - frame[..., None]) + light * frame[..., None]
    # Halation: red-orange bloom bleeding out of the bright frame.
    rgb += glow(frame, S * 0.035, [1.0, 0.35, 0.08], 0.55) * (1 - frame[..., None])
    rgb += glow(frame, S * 0.12, [1.0, 0.45, 0.1], 0.18) * (1 - frame[..., None])
    return to_image(rgb)


# ---------------------------------------------------------------- B: safelight

def safelight():
    rgb = background(0.06, 0.03)
    cx = cy = S / 2
    y, x = np.mgrid[0:S, 0:S].astype(float)
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / S

    # Precise lens ring: a graphite bezel with two fine highlights.
    ring = ((r > 0.255) & (r < 0.335)).astype(float)
    ring_shade = 0.12 + 0.05 * (1 - (y / S))  # lit from above
    rgb = rgb * (1 - ring[..., None]) + ring_shade[..., None] * ring[..., None]
    for rr, a in ((0.333, 0.30), (0.258, 0.18)):
        line = np.exp(-((r - rr) / 0.0015) ** 2)
        rgb += line[..., None] * a
    inner = (r < 0.255).astype(float)
    rgb = rgb * (1 - inner[..., None]) + 0.02 * inner[..., None]

    # Amber disc with a crisp edge, inside the dark well.
    disc = mask_from(lambda d: d.ellipse([cx - S * 0.185, cy - S * 0.185, cx + S * 0.185, cy + S * 0.185], fill=255))
    light = lit_gradient(cx - S * 0.03, cy - S * 0.04, S * 0.24)
    rgb = rgb * (1 - disc[..., None]) + light * disc[..., None]
    rgb += glow(disc, S * 0.02, [1.0, 0.4, 0.1], 0.5) * (inner * (1 - disc))[..., None]
    return to_image(rgb)


# ---------------------------------------------------------------- C: aperture

def aperture():
    rgb = background(0.065, 0.03)
    cx = cy = S / 2
    R = S * 0.36
    # Light behind the iris.
    disc = mask_from(lambda d: d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=255))
    light = lit_gradient(cx, cy, R * 1.05)
    rgb = rgb * (1 - disc[..., None]) + light * disc[..., None]
    # Six blades leaving a hexagonal opening, each a slightly different grey for depth.
    open_r = R * 0.42
    blades = []
    for i in range(6):
        a0 = math.radians(i * 60 + 15)
        a1 = a0 + math.radians(60)
        p_inner0 = (cx + open_r * math.cos(a0), cy + open_r * math.sin(a0))
        p_inner1 = (cx + open_r * math.cos(a1), cy + open_r * math.sin(a1))
        far = R * 1.6
        p_out1 = (cx + far * math.cos(a1 + 0.9), cy + far * math.sin(a1 + 0.9))
        p_out0 = (cx + far * math.cos(a0 + 0.9), cy + far * math.sin(a0 + 0.9))
        blades.append([p_inner0, p_inner1, p_out1, p_out0])
    for i, poly in enumerate(blades):
        m = mask_from(lambda d, poly=poly: d.polygon(poly, fill=255)) * disc
        shade = 0.10 + 0.035 * ((i * 2) % 6) / 5
        rgb = rgb * (1 - m[..., None]) + shade * m[..., None]
        # fine edge highlight on each blade's leading edge
        edge = mask_from(lambda d, poly=poly: d.line([poly[0], poly[3]], fill=255, width=int(S * 0.004))) * disc
        rgb += edge[..., None] * 0.12
    # Bezel.
    y, x = np.mgrid[0:S, 0:S].astype(float)
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    bezel = ((r > R) & (r < R * 1.12)).astype(float)
    rgb = rgb * (1 - bezel[..., None]) + 0.13 * bezel[..., None]
    rgb += np.exp(-((r - R * 1.12) / (S * 0.0015)) ** 2)[..., None] * 0.25
    return to_image(rgb)


if __name__ == "__main__":
    for name, fn in (("A_film_frame", film_frame), ("B_safelight", safelight), ("C_aperture", aperture)):
        fn().save(f"{OUT}/{name}.png")
        print("wrote", name)
