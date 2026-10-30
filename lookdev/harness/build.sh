#!/bin/sh
# Builds lookdev/harness/build/dump, a Mac command-line tool that runs the app's own RAW decode
# (Printlight/Processing) so look development sees exactly what the phone sees.
set -e
cd "$(dirname "$0")"
ROOT=../..
OUT=build
mkdir -p "$OUT"

# The app only ever decodes DNGs and imports UIKit; on the Mac, let Core Image detect the format.
sed -e 's/^import UIKit$/import Foundation/' \
    -e 's/identifierHint: "com.adobe.raw-image"/identifierHint: nil/' \
    "$ROOT/Printlight/Processing/RawDeveloper.swift" > "$OUT/RawDeveloper.swift"

xcrun -sdk macosx metal -fcikernel "$ROOT/Printlight/Processing/Look.ci.metal" -o "$OUT/default.metallib"
cp "$ROOT"/Printlight/Resources/Films/films.json "$ROOT"/Printlight/Resources/Films/*.cube.bin "$OUT/"

xcrun -sdk macosx swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    UIKitShim.swift "$OUT/RawDeveloper.swift" main.swift \
    "$ROOT/Printlight/Processing/LookParameters.swift" \
    "$ROOT/Printlight/Processing/FilmLook.swift" \
    "$ROOT/Printlight/Processing/FilmLibrary.swift" \
    "$ROOT/Printlight/Processing/WhiteBalance.swift" \
    "$ROOT/Printlight/Processing/CustomLUTLibrary.swift" \
    -o "$OUT/dump"
echo "built $OUT/dump"
