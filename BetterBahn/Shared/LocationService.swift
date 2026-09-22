import BetterBahnKit
import CoreLocation
import Observation

/// The user's rough location, used to put nearer train stations first in station search. Asks for
/// "while using the app" access the first time station search is used; without it `coordinate`
/// just stays `nil` and search keeps its usual order.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private(set) var coordinate: Coordinate?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastRequest: Date?

    override private init() {
        super.init()
        manager.delegate = self
        // Only used to sort into distance bands of 50 km and more, so a coarse fix is plenty.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// Asks for permission if the user hasn't decided yet, otherwise fetches a fresh fix – at most
    /// every 10 minutes, since a trip planner's user rarely moves 50 km in that time.
    func refresh() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if let lastRequest, Date.now.timeIntervalSince(lastRequest) < 600 { return }
            lastRequest = .now
            manager.requestLocation()
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            // Also called right after creation; only fetch once access was actually granted.
            if status == .authorizedWhenInUse || status == .authorizedAlways { refresh() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        MainActor.assumeIsolated { self.coordinate = coordinate }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Keep whatever fix we had; allow another try on the next search.
        MainActor.assumeIsolated { lastRequest = nil }
    }
}
