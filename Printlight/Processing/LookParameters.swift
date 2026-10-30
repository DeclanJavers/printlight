import Foundation

/// User-adjustable development settings. Tone and colour come from the chosen film's LUT;
/// halation and grain mirror `LookParameters` in lookdev/look.py. Everything up to the film
/// works on scene light, so the film's curve shapes it like exposure on a real negative.
struct LookParameters: Codable, Equatable {
    var film: String = "vision250d"     // FilmLibrary id
    var exposure: Double = 0.0          // stops, applied at develop time
    var blackLift: Double = 0.01        // viewing flare after the print, fraction of white
    var warmth: Double = 0.0            // -1...1, see WhiteBalance
    var tint: Double = 0.0              // -1...1, positive is magenta
    var clarity: Double = 0.25          // halo-limited local contrast in scene light, 0...1
    var halation: Double = 0.12
    var halationThreshold: Double = 1.0 // stops
    var grain: Double = 0.012
    var customLUT: String?              // CustomLUTLibrary name, applied after the film
    var customLUTStrength: Double = 1.0

    static let standard = LookParameters()

    private static let defaultsKey = "printlight.look.v3"

    static func load() -> LookParameters {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let params = try? JSONDecoder().decode(LookParameters.self, from: data) else { return .standard }
        return params
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
