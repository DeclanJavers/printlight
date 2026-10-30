import CoreImage

// Decodes a RAW file exactly the way the app does (neutral CIRAWFilter decode plus exposure
// matching) and writes scene-linear float RGB for lookdev/film.py.
//
// Usage: dump <raw> <out.f32> [height]
// Output: int32 width, int32 height, then float32 RGB rows top to bottom.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: dump <raw> <out.f32> [height]")
    exit(2)
}
let raw = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let targetHeight = args.count > 3 ? Double(args[3])! : 1000

guard let scene = RawDeveloper.sceneLinear(from: raw) else {
    print("could not decode \(args[1])")
    exit(1)
}
print("exposure match \(String(format: "%+.2f", RawDeveloper.exposureMatch(for: raw))) stops")

let scale = targetHeight / scene.extent.height
let image = scene.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let width = Int(image.extent.width.rounded(.down)), height = Int(image.extent.height.rounded(.down))
var pixels = [Float](repeating: 0, count: width * height * 4)
RawDeveloper.context.render(
    image, toBitmap: &pixels, rowBytes: width * 16,
    bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: CGFloat(width), height: CGFloat(height)),
    format: .RGBAf, colorSpace: nil
)

var out = Data()
var dims = [Int32(width), Int32(height)]
out.append(Data(bytes: &dims, count: 8))
var rgb = [Float]()
rgb.reserveCapacity(width * height * 3)
// render(toBitmap:) already writes rows top-down.
for i in 0..<(width * height) {
    rgb.append(pixels[i * 4]); rgb.append(pixels[i * 4 + 1]); rgb.append(pixels[i * 4 + 2])
}
out.append(Data(bytes: rgb, count: rgb.count * 4))
try out.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(width)x\(height)")
