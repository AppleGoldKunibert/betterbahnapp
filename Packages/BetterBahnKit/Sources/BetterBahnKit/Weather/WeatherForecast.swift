import Foundation

/// The forecast for one hour at one place (#385), from Open-Meteo.
public struct WeatherForecast: Codable, Sendable, Hashable {
    /// The full hour the values are for.
    public var date: Date
    /// Air temperature 2 m above the ground, °C.
    public var temperature: Double
    /// Chance of rain or snow in the hour before, in percent; some weather models have none.
    public var precipitationProbability: Int?
    /// Rain, showers and snow in the hour before, mm.
    public var precipitation: Double?
    /// Wind 10 m above the ground, km/h.
    public var windSpeed: Double?
    /// WMO weather interpretation code (`WeatherCondition`).
    public var weatherCode: Int
    public var isDay: Bool

    public init(date: Date, temperature: Double, precipitationProbability: Int? = nil, precipitation: Double? = nil,
                windSpeed: Double? = nil, weatherCode: Int, isDay: Bool = true) {
        self.date = date
        self.temperature = temperature
        self.precipitationProbability = precipitationProbability
        self.precipitation = precipitation
        self.windSpeed = windSpeed
        self.weatherCode = weatherCode
        self.isDay = isDay
    }

    public var condition: WeatherCondition { WeatherCondition(code: weatherCode) }
    /// "18°", "-3°".
    public var temperatureText: String { "\(Int(temperature.rounded()))°" }
    public var symbolName: String { condition.symbolName(isDay: isDay) }
    /// "Sonnig", "Leichter Regen".
    public var conditionText: String { condition.description(isDay: isDay) }
}

/// What the WMO weather code says, with a German name and an SF Symbol for it.
public enum WeatherCondition: Sendable, Hashable {
    case clear, mainlyClear, partlyCloudy, overcast, fog
    case drizzle, freezingDrizzle, lightRain, rain, heavyRain, freezingRain
    case lightSnow, snow, heavySnow, snowGrains
    case rainShowers, heavyRainShowers, snowShowers
    case thunderstorm, thunderstormWithHail
    case unknown

    /// Open-Meteo's codes (https://open-meteo.com/en/docs, "WMO Weather interpretation codes").
    public init(code: Int) {
        self = switch code {
        case 0: .clear
        case 1: .mainlyClear
        case 2: .partlyCloudy
        case 3: .overcast
        case 45, 48: .fog
        case 51, 53, 55: .drizzle
        case 56, 57: .freezingDrizzle
        case 61: .lightRain
        case 63: .rain
        case 65: .heavyRain
        case 66, 67: .freezingRain
        case 71: .lightSnow
        case 73: .snow
        case 75: .heavySnow
        case 77: .snowGrains
        case 80, 81: .rainShowers
        case 82: .heavyRainShowers
        case 85, 86: .snowShowers
        case 95: .thunderstorm
        case 96, 99: .thunderstormWithHail
        default: .unknown
        }
    }

    public func description(isDay: Bool) -> String {
        switch self {
        case .clear: isDay ? "Sonnig" : "Klar"
        case .mainlyClear: isDay ? "Heiter" : "Überwiegend klar"
        case .partlyCloudy: "Teils bewölkt"
        case .overcast: "Bedeckt"
        case .fog: "Nebel"
        case .drizzle: "Nieselregen"
        case .freezingDrizzle: "Gefrierender Nieselregen"
        case .lightRain: "Leichter Regen"
        case .rain: "Regen"
        case .heavyRain: "Starker Regen"
        case .freezingRain: "Gefrierender Regen"
        case .lightSnow: "Leichter Schneefall"
        case .snow: "Schneefall"
        case .heavySnow: "Starker Schneefall"
        case .snowGrains: "Schneegriesel"
        case .rainShowers: "Regenschauer"
        case .heavyRainShowers: "Heftige Regenschauer"
        case .snowShowers: "Schneeschauer"
        case .thunderstorm: "Gewitter"
        case .thunderstormWithHail: "Gewitter mit Hagel"
        case .unknown: "Wetter"
        }
    }

    public func symbolName(isDay: Bool) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mainlyClear, .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: "cloud.sleet.fill"
        case .lightRain, .rain: "cloud.rain.fill"
        case .heavyRain, .heavyRainShowers: "cloud.heavyrain.fill"
        case .lightSnow, .snow, .heavySnow, .snowShowers: "cloud.snow.fill"
        case .snowGrains: "snowflake"
        case .rainShowers: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .thunderstorm: "cloud.bolt.fill"
        case .thunderstormWithHail: "cloud.bolt.rain.fill"
        case .unknown: "thermometer.medium"
        }
    }
}

/// Where a journey shows the weather (#385): at the destination on arrival, and at transfers with more
/// than 15 minutes until the next train, where one might step outside.
public struct WeatherPoint: Sendable, Hashable {
    public enum Place: Sendable, Hashable {
        case destination
        /// The transfer where the leg with this id arrives.
        case transfer(legID: String)
    }

    public var place: Place
    public var station: Station
    public var date: Date
}

/// The forecasts for a journey's `WeatherPoint`s that are in range.
public struct JourneyWeather: Sendable, Hashable {
    public var destination: WeatherForecast?
    /// Keyed by the id of the leg arriving at the transfer.
    public var transfers: [String: WeatherForecast]

    public init(destination: WeatherForecast? = nil, transfers: [String: WeatherForecast] = [:]) {
        self.destination = destination
        self.transfers = transfers
    }

    /// What a leg's card shows where the leg arrives: the destination's forecast on the journey's last leg,
    /// a long transfer's on the others.
    public func arrival(of leg: Leg, in journey: Journey) -> LegArrivalWeather? {
        if leg.id == journey.legs.last?.id {
            return destination.map { LegArrivalWeather(forecast: $0, atDestination: true) }
        }
        return transfers[leg.id].map { LegArrivalWeather(forecast: $0, atDestination: false) }
    }
}

/// The forecast at a leg's arrival: "bei Ankunft" at the destination, "beim Umstieg" at a transfer.
public struct LegArrivalWeather: Sendable, Hashable {
    public var forecast: WeatherForecast
    public var atDestination: Bool

    public init(forecast: WeatherForecast, atDestination: Bool) {
        self.forecast = forecast
        self.atDestination = atDestination
    }
}

public extension Journey {
    /// A transfer this long shows the weather at the transfer station.
    static let weatherTransferWait: TimeInterval = 15 * 60

    /// The destination on arrival, then every transfer with more than `weatherTransferWait` until the next
    /// train leaves (by live times). Only stations with a known position.
    var weatherPoints: [WeatherPoint] {
        var points: [WeatherPoint] = []
        if let last = legs.last, last.destination.coordinate != nil {
            points.append(WeatherPoint(place: .destination, station: last.destination, date: last.arrival.best))
        }
        for index in legs.indices where !legs[index].isWalking {
            let leg = legs[index]
            guard leg.destination.coordinate != nil, let next = nextTransitLegIndex(after: index),
                  legs[next].departure.best.timeIntervalSince(leg.arrival.best) > Self.weatherTransferWait else { continue }
            points.append(WeatherPoint(place: .transfer(legID: leg.id), station: leg.destination, date: leg.arrival.best))
        }
        return points
    }
}

/// Asks Open-Meteo (free, no key, CC BY 4.0) for the hourly forecast at a station (#385). Only the station's
/// position goes out, rounded to about a kilometre, never the user's. A place's forecast is kept for an hour,
/// so opening a journey again, or another one passing there, doesn't ask again.
public actor WeatherClient {
    public static let shared = WeatherClient()
    /// How far ahead a forecast is shown; beyond that it says little.
    public static let range: TimeInterval = 10 * 24 * 3600
    /// How long a place's forecast is used; Open-Meteo updates its models about every hour.
    static let maxAge: TimeInterval = 3600
    static let baseURL = URL(string: "https://api.open-meteo.com/v1/forecast")!

    private struct Fetched {
        let at: Date
        let hours: [WeatherForecast]
    }

    let http: HTTPClient
    private var cache: [String: Fetched] = [:]
    private var running: [String: Task<[WeatherForecast], Error>] = [:]

    public init(http: HTTPClient = HTTPClient(timeout: 15)) {
        self.http = http
    }

    /// Whether a forecast is shown for `date`: still ahead and within the next 10 days.
    public static func covers(_ date: Date, now: Date = .now) -> Bool {
        date > now && date.timeIntervalSince(now) <= range
    }

    /// The forecast for the hour nearest to `date` at `coordinate`; nil outside `covers` or when Open-Meteo
    /// can't be reached.
    public func forecast(at coordinate: Coordinate, for date: Date, now: Date = .now) async -> WeatherForecast? {
        guard Self.covers(date, now: now), let hours = try? await hours(at: coordinate, now: now) else { return nil }
        guard let nearest = hours.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(nearest.date.timeIntervalSince(date)) <= 30 * 60 else { return nil }
        return nearest
    }

    /// The forecasts for `journey`'s weather points, asked for in parallel.
    public func weather(for journey: Journey, now: Date = .now) async -> JourneyWeather {
        let points = journey.weatherPoints.filter { Self.covers($0.date, now: now) }
        let found = await withTaskGroup(of: (WeatherPoint.Place, WeatherForecast?).self) { group in
            for point in points {
                guard let coordinate = point.station.coordinate else { continue }
                group.addTask { (point.place, await self.forecast(at: coordinate, for: point.date, now: now)) }
            }
            var found: [(WeatherPoint.Place, WeatherForecast)] = []
            for await (place, forecast) in group {
                if let forecast { found.append((place, forecast)) }
            }
            return found
        }
        var weather = JourneyWeather()
        for (place, forecast) in found {
            switch place {
            case .destination: weather.destination = forecast
            case .transfer(let legID): weather.transfers[legID] = forecast
            }
        }
        return weather
    }

    /// The place's hourly forecast for the next days, from the cache while it is younger than `maxAge`.
    private func hours(at coordinate: Coordinate, now: Date) async throws -> [WeatherForecast] {
        let latitude = String(format: "%.2f", coordinate.latitude)
        let longitude = String(format: "%.2f", coordinate.longitude)
        let key = "\(latitude),\(longitude)"
        if let cached = cache[key], now.timeIntervalSince(cached.at) < Self.maxAge { return cached.hours }
        if let task = running[key] { return try await task.value }
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: latitude),
            URLQueryItem(name: "longitude", value: longitude),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            // Counted from today's midnight, so day 11 still covers 10 days from now.
            URLQueryItem(name: "forecast_days", value: "11"),
        ]
        let http = http, url = components.url!
        let task = Task<[WeatherForecast], Error> {
            try await http.get(url, as: OpenMeteoForecast.self).hourly.forecasts
        }
        running[key] = task
        defer { running[key] = nil }
        let hours = try await task.value
        cache[key] = Fetched(at: now, hours: hours)
        return hours
    }
}

/// Open-Meteo's `/v1/forecast` answer with `timeformat=unixtime`. Values can be `null` (a model without
/// that variable, or past its range), so every one is optional.
struct OpenMeteoForecast: Decodable {
    struct Hourly: Decodable {
        let time: [TimeInterval]
        let temperature: [Double?]
        let precipitationProbability: [Double?]?
        let precipitation: [Double?]?
        let weatherCode: [Double?]
        let windSpeed: [Double?]?
        let isDay: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time, precipitation
            case temperature = "temperature_2m"
            case precipitationProbability = "precipitation_probability"
            case weatherCode = "weather_code"
            case windSpeed = "wind_speed_10m"
            case isDay = "is_day"
        }

        /// Every hour with a temperature and a weather code.
        var forecasts: [WeatherForecast] {
            time.indices.compactMap { index in
                guard let temperature = temperature[safe: index] ?? nil, let code = weatherCode[safe: index] ?? nil
                else { return nil }
                return WeatherForecast(date: Date(timeIntervalSince1970: time[index]), temperature: temperature,
                                       precipitationProbability: (precipitationProbability?[safe: index] ?? nil).map { Int($0.rounded()) },
                                       precipitation: precipitation?[safe: index] ?? nil,
                                       windSpeed: windSpeed?[safe: index] ?? nil,
                                       weatherCode: Int(code),
                                       isDay: (isDay?[safe: index] ?? nil).map { $0 != 0 } ?? true)
            }
        }
    }

    let hourly: Hourly
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
