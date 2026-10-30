# Printlight

An iPhone still camera that shoots RAW, throws away Apple's rendering, and develops
the image with its own film-print look.

## Pipeline

1. **Capture** (`Camera/CameraController.swift`). It captures Apple ProRAW when the lens supports it
   (multi-frame merged, up to 48MP) and falls back to single-frame Bayer RAW otherwise. It is RAW only:
   no Apple-processed companion image.
2. **Neutral decode** (`Processing/RawDeveloper.swift`). `CIRAWFilter` runs with boost, local tone
   mapping, sharpening and gamut mapping all off, which gives scene-linear RGB.
3. **Look** (`Processing/FilmLook.swift`, kernels in `Look.ci.metal`). The steps run in this order:
   - Clarity: local contrast against a small blur of log luminance, soft-limited to about half a
     stop so edges don't grow halos. Replaces Apple's sharpening, which the decode turns off.
   - White balance: Warmth (mireds along the black-body locus) and Tint, as a Bradford
     adaptation of scene light (`WhiteBalance.swift`), so the film responds to the corrected light.
   - Halation: energy above a threshold is blurred, tinted red and added back in scene light.
   - Film: a 48³ LUT per film stock (`Resources/Films`), applied in log space by `printlightShaper`
     plus `CIColorCube`. Each LUT is baked from a spectral simulation of a camera negative printed
     onto print film (see Look development). Output is Display P3. Stocks: Vision3 250D, 500T and 50D
     on 2383 print; Portra 400 and Ektar 100 on Endura; Gold 200 on Supra Endura; Fuji Pro 400H on
     Crystal Archive; Mono (panchromatic black and white through the 2383 neutral curve).
   - Custom LUT (optional): an imported `.cube` applied to the film's output in sRGB encoding,
     blended by a strength. Meant for Rec.709 display looks; LUTs built for a camera log input
     (LogC, S-Log, Apple Log) expect a different encoding and will look wrong.
   - Black lift (viewing flare): prints are made for a dark theatre, so a small adjustable lift keeps
     their blacks from reading as crushed on a phone.
   - Grain is sized relative to the frame, so 12MP and 48MP shots look alike.
4. **Save** (`Processing/PhotoLibrarySaver.swift`). Each shot is one Photos asset: the DNG is the
   original, and the developed HEIC is attached as a non-destructive edit whose adjustment data holds
   the look settings (JSON, format `com.declanjavers.printlight.look`). Photos shows the developed
   image and can revert to the RAW. Shots also go in a "Printlight" album. If Photos refuses the
   edited save, it falls back to two separate photos.
5. **Library** (`Library/ShotLibrary.swift`, `UI/LibraryView.swift`). It shows Printlight's own shots
   plus Photos' RAW album, so ProRAW from the Camera app and older RAWs open too. The app stores only
   the list of its own assets' identifiers. The library reads RAWs and settings back from Photos (downloading from
   iCloud if needed). Saving from the editor replaces that photo's edit instead of making a copy.
   Read/write Photos access is requested; Limited is enough, because an app's own photos stay visible to it.

The live viewfinder runs the same kernels on the video feed. Those frames are already rendered by
Apple, so `printlightUnrender` approximately undoes that first. **The viewfinder is a close guide,
not an exact match.** Tap the thumbnail to see the true develop and to re-develop it with different
settings.

Zebra stripes in the viewfinder mark areas where the preview frame is at or near clipping. The
frames are Apple-processed SDR video, so they're a guide to blown highlights, not a raw reading.

An exact viewfinder needs scene-referred preview frames, and iOS doesn't offer them alongside RAW
stills. Setting the camera to Apple Log or Apple Log 2 disables photo capture (documented in
`AVCaptureDevice.h` and `AVCapturePhotoOutput.h`). On an iPhone 17 Pro, all 17 HLG video formats
were tested and none offers ProRAW or Bayer RAW stills.

## Building

```bash
brew install xcodegen   # if needed
xcodegen generate
open Printlight.xcodeproj
```

Set your team under Signing & Capabilities and run on a real iPhone (the simulator has no camera).
iOS 17+.

## Look development

`lookdev/film.py` simulates the photochemical chain, using measured film data:

1. The scene's light is turned into a smooth spectrum and exposes the negative's three layers through
   their measured spectral sensitivities.
2. Each layer develops along its characteristic curve. DIR couplers add a little colour separation.
3. An additive printer sends separate red, green and blue beams through the negative's dyes
   (including the orange-mask correction) onto the print stock. Printer lights are timed so that
   mid grey prints neutral.
4. The print develops, and projector light through the print dyes is turned into what the eye sees
   (CIE 1931), adapted to D65, with a little viewing flare added.

`lookdev/bake.py` bakes each chain into a LUT for the app. `lookdev/look.py` holds the halation and
grain reference, plus the original formula look.

```bash
pip install numpy scipy pillow
python lookdev/film.py chart chart.png kodak_vision3_250d kodak_2383
python lookdev/bake.py 48          # writes Printlight/Resources/Films
```

`lookdev/samples/` holds CC0 test RAWs from raw.pixls.us (git-ignored, see `SOURCES.md` there).
Add your own DNGs there to build up a test set, then render every photo through every film:

```bash
sh lookdev/harness/build.sh         # Mac tool that decodes RAWs exactly like the app
python lookdev/sheet.py             # one contact sheet per photo in lookdev/sheets/
python lookdev/sheet.py lookdev/samples vision250d portra400   # only some films
```

### Film data credit

The film profiles in `lookdev/data/spektrafilm/` come from
[spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato and are licensed
CC BY-SA 4.0. The LUTs in `Printlight/Resources/Films` are derived from them and carry the same
license (`LICENSE-FILMS.txt`). Printlight's own code is not covered by that license, but the app
should credit the film data wherever it lists acknowledgements.

## Exposure matching

ProRAW is exposed about a stop dark (more in high-contrast scenes), and Apple brightens it back
when rendering. `RawDeveloper.exposureMatch` decodes a small copy of each DNG both ways and picks
the exposure that gives Printlight's render the same median brightness as Apple's. Only that one
number is borrowed; none of Apple's local tone mapping reaches the image. The user's `exposure`
setting is applied on top.

## Things to tune on a real device

- The `printlightUnrender` curve, so the viewfinder matches the develop more closely. Pairs of
  preview frames and developed shots of the same scene would let it be fitted from data.
- Each capture prints `PRINTLIGHT TIMING` to the console (thumbnail, develop + encode, save).
