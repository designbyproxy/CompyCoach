import Foundation

// MARK: - WeatherService

// Decides whether it's reasonable to suggest a walk, using current conditions from
// Open-Meteo (free, no API key). The home location comes from a ZIP / postal code the
// user enters in the menu; it is resolved to coordinates once and stored in
// UserDefaults on this Mac only — nothing location-specific lives in the source.
//
// Failure policy: if no ZIP is set or the weather can't be fetched, walks are allowed.
// A walk the user can skip is cheap; silently never suggesting one is not.

@MainActor
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    // No walk when it feels colder than this (°F), while it's precipitating, or when
    // rain is this likely (%) in the next hour.
    nonisolated static let minWalkTempF: Double = 45
    nonisolated static let maxRainChancePct: Int = 40

    // Weather is re-fetched at most this often.
    private let cacheLifetime: TimeInterval = 30 * 60

    struct Reading {
        let temperatureF: Double
        let feelsLikeF: Double
        let precipitationMM: Double
        let rainChanceNextHourPct: Int
        let weatherCode: Int
        let fetchedAt: Date

        var isWet: Bool {
            precipitationMM > 0 || WeatherService.wetCodes.contains(weatherCode)
        }

        var isRainLikely: Bool {
            rainChanceNextHourPct >= WeatherService.maxRainChancePct
        }

        var isWalkable: Bool {
            feelsLikeF >= WeatherService.minWalkTempF && !isWet && !isRainLikely
        }

        var summary: String {
            "feels \(Int(feelsLikeF.rounded()))°F, \(WeatherService.describe(weatherCode)), "
                + "\(rainChanceNextHourPct)% rain"
        }
    }

    @Published private(set) var homeZIP: String?
    @Published private(set) var homePlaceName: String?
    @Published private(set) var lastReading: Reading?

    private var latitude: Double?
    private var longitude: Double?

    private enum Keys {
        static let zip = "homeZIP"
        static let place = "homePlaceName"
        static let lat = "homeLatitude"
        static let lon = "homeLongitude"
    }

    private init() {
        let d = UserDefaults.standard
        homeZIP = d.string(forKey: Keys.zip)
        homePlaceName = d.string(forKey: Keys.place)
        if d.object(forKey: Keys.lat) != nil, d.object(forKey: Keys.lon) != nil {
            latitude = d.double(forKey: Keys.lat)
            longitude = d.double(forKey: Keys.lon)
        }
    }

    // MARK: Home location

    enum LocationError: LocalizedError {
        case notFound
        var errorDescription: String? { "Couldn't find that ZIP / postal code." }
    }

    /// Resolves a ZIP / postal code to coordinates and saves it. Pass an empty
    /// string to clear the home location (walks are then always allowed).
    func setHomeZIP(_ raw: String) async throws {
        let zip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = UserDefaults.standard

        guard !zip.isEmpty else {
            for key in [Keys.zip, Keys.place, Keys.lat, Keys.lon] { d.removeObject(forKey: key) }
            homeZIP = nil; homePlaceName = nil; latitude = nil; longitude = nil; lastReading = nil
            return
        }

        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        var items = [
            URLQueryItem(name: "name", value: zip),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        if let region = Locale.current.region?.identifier {
            items.append(URLQueryItem(name: "countryCode", value: region))
        }
        comps.queryItems = items

        struct GeoResponse: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let admin1: String?
            }
            let results: [Result]?
        }

        let data = try await fetch(comps.url!)
        guard let hit = try JSONDecoder().decode(GeoResponse.self, from: data).results?.first else {
            throw LocationError.notFound
        }

        let place = [hit.name, hit.admin1].compactMap { $0 }.joined(separator: ", ")
        d.set(zip, forKey: Keys.zip)
        d.set(place, forKey: Keys.place)
        d.set(hit.latitude, forKey: Keys.lat)
        d.set(hit.longitude, forKey: Keys.lon)
        homeZIP = zip
        homePlaceName = place
        latitude = hit.latitude
        longitude = hit.longitude
        lastReading = nil
        _ = await currentReading()  // warm the cache so the menu shows conditions
    }

    // MARK: Walk decision

    /// True if a walk should be suggested right now.
    func isWalkWeatherOK() async -> Bool {
        guard let reading = await currentReading() else { return true }
        return reading.isWalkable
    }

    /// Cached current conditions at home, or nil if no home is set / fetch failed.
    func currentReading() async -> Reading? {
        guard let lat = latitude, let lon = longitude else { return nil }
        if let r = lastReading, Date().timeIntervalSince(r.fetchedAt) < cacheLifetime {
            return r
        }

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,precipitation,weather_code"),
            // The current hour's slot plus the next one, so "next hour" is covered
            // wherever we are within the current hour.
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "forecast_hours", value: "2"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
        ]

        struct ForecastResponse: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let apparent_temperature: Double
                let precipitation: Double
                let weather_code: Int
            }
            struct Hourly: Decodable {
                let precipitation_probability: [Int?]
            }
            let current: Current
            let hourly: Hourly?
        }

        guard let data = try? await fetch(comps.url!),
              let forecast = try? JSONDecoder().decode(ForecastResponse.self, from: data) else {
            return nil
        }
        let c = forecast.current
        let rainChance = forecast.hourly?.precipitation_probability.compactMap { $0 }.max() ?? 0
        let reading = Reading(temperatureF: c.temperature_2m,
                              feelsLikeF: c.apparent_temperature,
                              precipitationMM: c.precipitation,
                              rainChanceNextHourPct: rainChance,
                              weatherCode: c.weather_code,
                              fetchedAt: Date())
        lastReading = reading
        return reading
    }

    #if DEBUG
    /// Fixed walk-friendly conditions for scripts/make-screenshots.sh, so screenshots never depend
    /// on (or reveal) the real weather at home.
    func useSampleReading() {
        lastReading = Reading(temperatureF: 64, feelsLikeF: 64, precipitationMM: 0,
                              rainChanceNextHourPct: 0, weatherCode: 0, fetchedAt: Date())
    }

    /// A sample home for the menu screenshot. Nothing is saved, so the real home ZIP is untouched.
    func useSampleHome() {
        homeZIP = "90210"
        homePlaceName = "Beverly Hills, California"
        useSampleReading()
    }
    #endif

    // MARK: Helpers

    private func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // WMO weather codes that mean something is falling: drizzle, rain, freezing
    // rain, snow, showers, thunderstorms.
    nonisolated static let wetCodes: Set<Int> = Set(51...67).union(71...77).union(80...86).union(95...99)

    nonisolated static func describe(_ code: Int) -> String {
        switch code {
        case 0:        return "clear"
        case 1, 2:     return "partly cloudy"
        case 3:        return "overcast"
        case 45, 48:   return "fog"
        case 51...57:  return "drizzle"
        case 61...67:  return "rain"
        case 71...77:  return "snow"
        case 80...82:  return "rain showers"
        case 85, 86:   return "snow showers"
        case 95...99:  return "thunderstorm"
        default:       return "code \(code)"
        }
    }
}
