import Foundation

/// User-adjustable development settings. Tone and colour come from the chosen film's LUT;
/// halation and grain mirror `LookParameters` in lookdev/look.py.
struct LookParameters: Codable, Equatable {
    var film: String = "vision250d"     // FilmLibrary id
    var exposure: Double = 0.0          // stops, applied at develop time
    var blackLift: Double = 0.01        // viewing flare after the print, fraction of white
    var halation: Double = 0.12
    var halationThreshold: Double = 1.0 // stops
    var grain: Double = 0.012

    static let standard = LookParameters()

    private static let defaultsKey = "printlight.look.v2"

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
