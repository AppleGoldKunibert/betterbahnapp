import Foundation
import Testing
@testable import BetterBahnKit

/// Weather at the destination and long transfers (#385), against a fake Open-Meteo (`OpenMeteoProtocol`).
@Suite(.serialized) struct WeatherTests {
    /// A full hour, so the fake's hours line up with it.
    static let now = Date(timeIntervalSince1970: 1_792_281_600)
    private let munich = Coordinate(latitude: 48.140_32, longitude: 11.558_02)

    private func client() -> WeatherClient {
        WeatherClient(http: HTTPClient(session: OpenMeteoProtocol.session()))
    }

    @Test func picksTheHourNearestToTheArrival() async throws {
        OpenMeteoProtocol.state = .init(start: Self.now)
        let forecast = try #require(await client().forecast(at: munich, for: Self.now.addingTimeInterval(5 * 3600 + 20 * 60),
                                                            now: Self.now))
        #expect(forecast.date == Self.now.addingTimeInterval(5 * 3600))
        #expect(forecast.temperature == 15.4)
        #expect(forecast.temperatureText == "15°")
        #expect(forecast.precipitationProbability == 10)
        #expect(forecast.precipitation == 0.5)
        #expect(forecast.windSpeed == 12)
        #expect(forecast.condition == .rain)
        #expect(forecast.symbolName == "cloud.rain.fill")
        #expect(forecast.conditionText == "Regen")
        // 40 minutes past: the next hour.
        let later = try #require(await client().forecast(at: munich, for: Self.now.addingTimeInterval(5 * 3600 + 40 * 60),
                                                         now: Self.now))
        #expect(later.date == Self.now.addingTimeInterval(6 * 3600))
    }

    /// Only the station's position goes out, rounded to about a kilometre.
    @Test func sendsOnlyTheRoundedStationPosition() async throws {
        OpenMeteoProtocol.state = .init(start: Self.now)
        _ = await client().forecast(at: munich, for: Self.now.addingTimeInterval(3600), now: Self.now)
        let url = try #require(OpenMeteoProtocol.state.requests.first)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(url.host == "api.open-meteo.com")
        #expect(items["latitude"] == "48.14")
        #expect(items["longitude"] == "11.56")
        #expect(Set(items.keys) == ["latitude", "longitude", "hourly", "timezone", "timeformat", "forecast_days"])
    }

    /// Opening a journey again, or another arrival at the same station, doesn't ask again within the hour.
    @Test func keepsAPlacesForecastForAnHour() async throws {
        OpenMeteoProtocol.state = .init(start: Self.now)
        let client = client()
        _ = await client.forecast(at: munich, for: Self.now.addingTimeInterval(3600), now: Self.now)
        _ = await client.forecast(at: munich, for: Self.now.addingTimeInterval(30 * 3600), now: Self.now.addingTimeInterval(59 * 60))
        // Another platform of the same station rounds to the same place.
        _ = await client.forecast(at: Coordinate(latitude: 48.1412, longitude: 11.5622), for: Self.now.addingTimeInterval(3600),
                                  now: Self.now)
        #expect(OpenMeteoProtocol.state.requests.count == 1)
        _ = await client.forecast(at: munich, for: Self.now.addingTimeInterval(3 * 3600), now: Self.now.addingTimeInterval(3600))
        #expect(OpenMeteoProtocol.state.requests.count == 2)
    }

    /// Arrivals already past or more than 10 days ahead show nothing and ask nothing.
    @Test func showsNothingOutsideTheForecastRange() async throws {
        OpenMeteoProtocol.state = .init(start: Self.now)
        let client = client()
        #expect(await client.forecast(at: munich, for: Self.now.addingTimeInterval(-60), now: Self.now) == nil)
        #expect(await client.forecast(at: munich, for: Self.now.addingTimeInterval(10 * 24 * 3600 + 60), now: Self.now) == nil)
        #expect(OpenMeteoProtocol.state.requests.isEmpty)
        #expect(WeatherClient.covers(Self.now.addingTimeInterval(10 * 24 * 3600), now: Self.now))
    }

    /// No answer, an error or an hour the answer doesn't have: nothing shows, and the next look asks again.
    @Test func showsNothingWithoutAForecast() async throws {
        OpenMeteoProtocol.state = .init(start: Self.now, status: 503)
        let client = client()
        #expect(await client.forecast(at: munich, for: Self.now.addingTimeInterval(3600), now: Self.now) == nil)
        OpenMeteoProtocol.state.status = 200
        #expect(await client.forecast(at: munich, for: Self.now.addingTimeInterval(3600), now: Self.now) != nil)
        #expect(OpenMeteoProtocol.state.requests.count == 2)
        // The fake has 48 hours.
        #expect(await client.forecast(at: munich, for: Self.now.addingTimeInterval(60 * 3600), now: Self.now) == nil)
    }

    /// Hours Open-Meteo has no value for: no temperature skips the hour, no rain chance leaves it out.
    @Test func readsMissingValues() async throws {
        OpenMeteoProtocol.state = .init(start: Self.now)
        let client = client()
        let noChance = try #require(await client.forecast(at: munich, for: Self.now.addingTimeInterval(3 * 3600), now: Self.now))
        #expect(noChance.precipitationProbability == nil)
        // Hour 7 has no temperature, so the nearest one with values is shown only if within 30 minutes.
        #expect(await client.forecast(at: munich, for: Self.now.addingTimeInterval(7 * 3600), now: Self.now) == nil)
        let night = try #require(await client.forecast(at: munich, for: Self.now.addingTimeInterval(20 * 3600), now: Self.now))
        #expect(!night.isDay)
    }

    @Test func namesTheWeather() {
        #expect(WeatherForecast(date: Self.now, temperature: -0.4, weatherCode: 0).temperatureText == "0°")
        #expect(WeatherForecast(date: Self.now, temperature: -2.6, weatherCode: 0).temperatureText == "-3°")
        #expect(WeatherForecast(date: Self.now, temperature: 17.5, weatherCode: 0).temperatureText == "18°")
        #expect(WeatherForecast(date: Self.now, temperature: 18, weatherCode: 0).symbolName == "sun.max.fill")
        #expect(WeatherForecast(date: Self.now, temperature: 8, weatherCode: 0, isDay: false).conditionText == "Klar")
        #expect(WeatherCondition(code: 2) == .partlyCloudy)
        #expect(WeatherCondition(code: 45) == .fog)
        #expect(WeatherCondition(code: 75) == .heavySnow)
        #expect(WeatherCondition(code: 82) == .heavyRainShowers)
        #expect(WeatherCondition(code: 99) == .thunderstormWithHail)
        #expect(WeatherCondition(code: 42) == .unknown)
    }

    // MARK: Journey

    private func leg(_ trip: String, _ from: Station, _ to: Station, _ departure: Double, _ arrival: Double, walking: Bool = false) -> Leg {
        Leg(origin: from, destination: to,
            departure: TimeInfo(planned: Self.now.addingTimeInterval(departure * 60), actual: nil),
            arrival: TimeInfo(planned: Self.now.addingTimeInterval(arrival * 60), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: walking ? nil : trip,
            line: walking ? nil : Line(name: trip, number: nil, product: .regional, operatorName: nil),
            direction: nil, isWalking: walking, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    /// The destination, and transfers with more than 15 minutes until the next train (a walk in between counts).
    @Test func showsTheWeatherAtTheDestinationAndLongTransfers() {
        let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
        let halle = station("8010159", "Halle (Saale) Hbf", 51.477, 11.987)
        let erfurt = station("8010101", "Erfurt Hbf", 50.972, 11.038)
        let erfurtBus = station("erfurt-bus", "Erfurt Hbf (Bus)", 50.973, 11.037)
        let nuremberg = station("8000284", "Nürnberg Hbf", 49.446, 11.082)
        let munichHbf = station("8000261", "München Hbf", 48.140, 11.558)
        let first = leg("RE 1", berlin, halle, 0, 90)
        let second = leg("RE 2", halle, erfurt, 100, 160)  // 10 minutes at Halle
        let walk = leg("walk", erfurt, erfurtBus, 165, 170, walking: true)
        let third = leg("RE 3", erfurtBus, nuremberg, 180, 300)  // 20 minutes at Erfurt
        let fourth = leg("RE 4", nuremberg, munichHbf, 316, 420)  // 16 minutes at Nürnberg
        let journey = Journey(legs: [first, second, walk, third, fourth], source: .transitous)

        #expect(journey.weatherPoints == [
            WeatherPoint(place: .destination, station: munichHbf, date: Self.now.addingTimeInterval(420 * 60)),
            WeatherPoint(place: .transfer(legID: second.id), station: erfurt, date: Self.now.addingTimeInterval(160 * 60)),
            WeatherPoint(place: .transfer(legID: third.id), station: nuremberg, date: Self.now.addingTimeInterval(300 * 60)),
        ])

        // Without a position nothing is asked for.
        var unknown = journey
        unknown.legs[4].destination.coordinate = nil
        unknown.legs[1].destination.coordinate = nil
        #expect(unknown.weatherPoints.map(\.place) == [.transfer(legID: third.id)])
    }

    @Test func loadsTheJourneysWeather() async throws {
        OpenMeteoProtocol.state = .init(start: Self.now)
        let halle = station("8010159", "Halle (Saale) Hbf", 51.477, 11.987)
        let erfurt = station("8010101", "Erfurt Hbf", 50.972, 11.038)
        let first = leg("RE 1", station("8011160", "Berlin Hbf", 52.525, 13.369), halle, 0, 120)
        let second = leg("RE 2", halle, erfurt, 180, 240)
        let journey = Journey(legs: [first, second], source: .transitous)

        let weather = await client().weather(for: journey, now: Self.now)
        #expect(weather.destination?.date == Self.now.addingTimeInterval(4 * 3600))
        #expect(Array(weather.transfers.keys) == [first.id])
        #expect(weather.transfers[first.id]?.date == Self.now.addingTimeInterval(2 * 3600))
        #expect(OpenMeteoProtocol.state.requests.count == 2)

        // Arrived already: nothing left to show.
        let over = await client().weather(for: journey, now: Self.now.addingTimeInterval(5 * 3600))
        #expect(over == JourneyWeather())
    }
}

/// Answers like Open-Meteo's `/v1/forecast` with 48 hours from `start`: hour i is 10.4 + i °C, rain from
/// hour 4 on (code 63), day until hour 18. Hour 3 has no rain chance, hour 7 no temperature.
final class OpenMeteoProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var start: Date
        var status = 200
        var requests: [URL] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _state = State(start: .now)
    static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenMeteoProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let state = Self.lock.withLock {
            Self._state.requests.append(request.url!)
            return Self._state
        }
        let hours = 0..<48
        func list(_ value: (Int) -> String) -> String { "[" + hours.map(value).joined(separator: ",") + "]" }
        let body = """
        {"latitude":48.14,"longitude":11.56,"utc_offset_seconds":0,"timezone":"GMT","hourly":{
        "time":\(list { String(Int(state.start.timeIntervalSince1970) + $0 * 3600) }),
        "temperature_2m":\(list { $0 == 7 ? "null" : String(10.4 + Double($0)) }),
        "precipitation_probability":\(list { $0 == 3 ? "null" : String($0 * 2) }),
        "precipitation":\(list { $0 >= 4 ? "0.5" : "0.0" }),
        "weather_code":\(list { $0 >= 4 ? "63" : "1" }),
        "wind_speed_10m":\(list { _ in "12.0" }),
        "is_day":\(list { $0 < 18 ? "1" : "0" })}}
        """
        let response = state.status == 200 ? body : #"{"error":true,"reason":"unavailable"}"#
        let http = HTTPURLResponse(url: request.url!, statusCode: state.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
