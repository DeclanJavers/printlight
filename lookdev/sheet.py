"""Contact sheets: every RAW in a folder, rendered by Apple and by each film.

Decodes each RAW with the app's own pipeline (lookdev/harness), then renders it through the
spectral film chains in film.py. One sheet per photo goes to lookdev/sheets/.

Usage:
    python sheet.py                      # all films in bake.FILMS, all RAWs in lookdev/samples
    python sheet.py path/to/raws         # another folder
    python sheet.py samples vision250d portra400   # only these films

Requires the harness: sh lookdev/harness/build.sh
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

from bake import FILMS
from film import FilmChain, black_lift, encode_srgb, load_linear_dump

HERE = Path(__file__).parent
DUMP = HERE / "harness" / "build" / "dump"
RAW_SUFFIXES = {".dng", ".nef", ".arw", ".cr2", ".cr3", ".raf", ".orf", ".rw2", ".pef"}
HEIGHT = 700
LABEL = 34


def decode(raw: Path, cache: Path) -> np.ndarray | None:
    f32 = cache / (raw.stem + ".f32")
    if not f32.exists() or f32.stat().st_mtime < raw.stat().st_mtime:
        result = subprocess.run([str(DUMP), str(raw), str(f32), str(HEIGHT)], capture_output=True, text=True)
        if result.returncode != 0 or not f32.exists() or f32.stat().st_size < 100:
            print(f"  skipped {raw.name}: {result.stdout.strip() or result.stderr.strip()}")
            return None
    return load_linear_dump(str(f32))


def apple_render(raw: Path, cache: Path, size: tuple[int, int]) -> Image.Image:
    jpg = cache / (raw.stem + ".apple.jpg")
    if not jpg.exists():
        subprocess.run(["sips", "-s", "format", "jpeg", "-Z", str(HEIGHT), str(raw), "--out", str(jpg)],
                       capture_output=True)
    if not jpg.exists():
        return Image.new("RGB", size, "black")
    return ImageOps.exif_transpose(Image.open(jpg)).convert("RGB").resize(size)


def labelled(image: Image.Image, text: str) -> Image.Image:
    out = Image.new("RGB", (image.width, image.height + LABEL), "black")
    out.paste(image, (0, LABEL))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", 18)
    except OSError:
        font = ImageFont.load_default()
    ImageDraw.Draw(out).text((8, 7), text.upper(), fill=(242, 169, 59), font=font)
    return out


def main(argv: list[str]) -> None:
    if not DUMP.exists():
        sys.exit("Build the harness first: sh lookdev/harness/build.sh")
    folder = Path(argv[1]) if len(argv) > 1 else HERE / "samples"
    wanted = set(argv[2:])
    films = [f for f in FILMS if not wanted or f["id"] in wanted]
    chains = [(f["name"], FilmChain(f["negative"], f["print"]), bool(f.get("mono"))) for f in films]

    cache = folder / ".cache"
    cache.mkdir(exist_ok=True)
    sheets = HERE / "sheets"
    sheets.mkdir(exist_ok=True)

    for raw in sorted(p for p in folder.iterdir() if p.suffix.lower() in RAW_SUFFIXES):
        print(raw.name)
        x = decode(raw, cache)
        if x is None:
            continue
        tiles = [labelled(apple_render(raw, cache, (x.shape[1], x.shape[0])), "Apple")]
        for name, chain, mono in chains:
            y = encode_srgb(black_lift(chain.render_mono(x) if mono else chain.render(x)))
            tiles.append(labelled(Image.fromarray((y * 255 + 0.5).astype(np.uint8)), name))
        per_row = 4
        rows = [tiles[i:i + per_row] for i in range(0, len(tiles), per_row)]
        w, h = tiles[0].size
        sheet = Image.new("RGB", (per_row * w + (per_row - 1) * 8, len(rows) * h + (len(rows) - 1) * 8), "black")
        for r, row in enumerate(rows):
            for c, tile in enumerate(row):
                sheet.paste(tile, (c * (w + 8), r * (h + 8)))
        out = sheets / f"{raw.stem}.jpg"
        sheet.save(out, quality=90)
        print(f"  -> {out}")


if __name__ == "__main__":
    main(sys.argv)
