import Foundation

/// One baked film chain (negative + print), from Resources/Films/films.json.
struct Film: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let detail: String
    let file: String
    /// Neutral response of the chain: scene stops relative to mid grey -> display luminance.
    let greyStops: [Double]
    let greyLuminance: [Double]

    /// Scene stops (relative to mid grey) that this film renders at display-linear luminance `y`.
    func sceneStops(forDisplayLuminance y: Double) -> Double {
        guard let first = greyLuminance.first, let last = greyLuminance.last else { return 0 }
        if y <= first { return greyStops.first ?? 0 }
        if y >= last { return greyStops.last ?? 0 }
        let i = greyLuminance.firstIndex(where: { $0 >= y }) ?? 1
        let (y0, y1) = (greyLuminance[i - 1], greyLuminance[i])
        let t = y1 > y0 ? (y - y0) / (y1 - y0) : 0
        return greyStops[i - 1] + t * (greyStops[i] - greyStops[i - 1])
    }
}

/// The 3D LUTs baked by lookdev/bake.py from the spectral film simulation in lookdev/film.py.
/// Film data: spektrafilm profiles by Andrea Volpato, CC BY-SA 4.0 (see LICENSE-FILMS.txt).
final class FilmLibrary {
    static let shared = FilmLibrary()

    let films: [Film]
    let cubeSize: Int
    /// LUT input range in stops around mid grey; the shaper kernel maps it to [0, 1].
    let minStops: Double
    let maxStops: Double
    let credit: String

    private let cubes: [String: Data]

    private struct Manifest: Decodable {
        struct Shaper: Decodable { let minStops: Double; let maxStops: Double }
        let shaper: Shaper
        let size: Int
        let credit: String
        let films: [Film]
    }

    private init() {
        guard let url = Bundle.main.url(forResource: "films", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            fatalError("Resources/Films/films.json missing or invalid: run lookdev/bake.py")
        }
        let expectedBytes = manifest.size * manifest.size * manifest.size * 4 * MemoryLayout<Float32>.size
        var cubes: [String: Data] = [:]
        for film in manifest.films {
            let name = (film.file as NSString).deletingPathExtension
            guard let url = Bundle.main.url(forResource: name, withExtension: (film.file as NSString).pathExtension),
                  let cube = try? Data(contentsOf: url), cube.count == expectedBytes else {
                fatalError("LUT \(film.file) missing or the wrong size")
            }
            cubes[film.id] = cube
        }
        films = manifest.films
        cubeSize = manifest.size
        minStops = manifest.shaper.minStops
        maxStops = manifest.shaper.maxStops
        credit = manifest.credit
        self.cubes = cubes
    }

    var defaultFilm: Film { films[0] }

    func film(id: String) -> Film {
        films.first { $0.id == id } ?? defaultFilm
    }

    func cube(for film: Film) -> Data {
        cubes[film.id]!
    }
}
