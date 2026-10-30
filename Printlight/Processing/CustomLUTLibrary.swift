import Foundation
import os

/// User-imported `.cube` 3D LUTs, applied after the film as a creative grade.
///
/// Most downloadable `.cube` files are "Rec.709 in, Rec.709 out" display looks, so Printlight
/// feeds them the film's output encoded as sRGB and blends the result back by a strength. LUTs
/// built for a camera log input (LogC, S-Log, Apple Log) will look wrong here; they expect a
/// different input encoding.
final class CustomLUTLibrary {
    static let shared = CustomLUTLibrary()

    struct Cube {
        let size: Int
        let data: Data  // float32 RGBA, red fastest: CIColorCube's layout
    }

    enum ImportError: LocalizedError {
        case unreadable, notThreeD, badSize(Int), wrongCount(Int, Int), unsupportedDomain
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read that file."
            case .notThreeD: "Only 3D LUTs are supported (this one is 1D)."
            case .badSize(let n): "LUT size \(n) isn't supported (2–64)."
            case .wrongCount(let got, let want): "The LUT has \(got) entries; its size says \(want)."
            case .unsupportedDomain: "Only LUTs with a 0–1 input domain are supported."
            }
        }
    }

    private let folder: URL
    private let cache = OSAllocatedUnfairLock(initialState: [String: Cube]())

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Validates and copies a `.cube` file into the app. Returns the name to store in LookParameters.
    func importLUT(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ImportError.unreadable }
        let cube = try Self.parse(text)
        let name = url.deletingPathExtension().lastPathComponent
        try text.write(to: folder.appendingPathComponent(name + ".cube"), atomically: true, encoding: .utf8)
        cache.withLock { $0[name] = cube }
        return name
    }

    func cube(named name: String) -> Cube? {
        if let cached = cache.withLock({ $0[name] }) { return cached }
        guard let text = try? String(contentsOf: folder.appendingPathComponent(name + ".cube"), encoding: .utf8),
              let cube = try? Self.parse(text) else { return nil }
        cache.withLock { $0[name] = cube }
        return cube
    }

    static func parse(_ text: String) throws -> Cube {
        var size = 0
        var values: [Float] = []
        values.reserveCapacity(64 * 64 * 64 * 4)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts.first {
            case "LUT_1D_SIZE":
                throw ImportError.notThreeD
            case "LUT_3D_SIZE":
                size = Int(parts.last ?? "") ?? 0
            case "DOMAIN_MIN":
                if parts.dropFirst().compactMap({ Float($0) }) != [0, 0, 0] { throw ImportError.unsupportedDomain }
            case "DOMAIN_MAX":
                if parts.dropFirst().compactMap({ Float($0) }) != [1, 1, 1] { throw ImportError.unsupportedDomain }
            default:
                let rgb = parts.compactMap { Float($0) }
                if rgb.count == 3 { values += rgb + [1] }
            }
        }
        guard (2...64).contains(size) else { throw ImportError.badSize(size) }
        let expected = size * size * size
        guard values.count == expected * 4 else { throw ImportError.wrongCount(values.count / 4, expected) }
        return Cube(size: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
