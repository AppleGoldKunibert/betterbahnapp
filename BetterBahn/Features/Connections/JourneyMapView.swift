import BetterBahnKit
import MapKit
import SwiftUI

/// Shows a single journey's route on a map with transfer points highlighted as markers.
struct JourneyMapView: View {
    let journey: Journey
    let finalDestination: Station
    @Environment(\.dismiss) var dismiss
    @State private var mapVersion = 0

    var body: some View {
        NavigationStack {
            JourneyMap(journey: journey, version: mapVersion)
                .ignoresSafeArea(edges: .top)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen") { dismiss() }
                    }
                }
                .navigationTitle("\(journey.legs.first?.origin.displayName ?? "Reise") → \(finalDestination.displayName)")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Transfer point with all needed info.
struct TransferPoint: Identifiable {
    let id = UUID()
    let station: Station
    let arrivalTime: Date?
    let platform: PlatformInfo?
    let legIndex: Int // For reference
}

/// Extract all transfer points (where one leg ends and another begins).
private func extractTransferPoints(from journey: Journey) -> [TransferPoint] {
    var transfers: [TransferPoint] = []

    for (index, leg) in journey.transitLegs.dropLast().enumerated() {
        let station = leg.destination
        transfers.append(TransferPoint(
            station: station,
            arrivalTime: leg.arrival.best,
            platform: leg.arrivalPlatform,
            legIndex: index
        ))
    }

    return transfers
}

/// MapKit-based visualization of a journey's route.
struct JourneyMap: UIViewRepresentable {
    let journey: Journey
    let version: Int

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)

        // Initial region: Germany
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
            span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 9)
        ), animated: false)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Remove old overlays
        map.removeOverlays(map.overlays.filter { $0 is MKPolyline || $0 is JourneyMarkerAnnotation })
        map.removeAnnotations(map.annotations.filter { $0 is JourneyMarkerAnnotation })

        var bounds = MKMapRect.null

        // Draw polylines for each leg
        for leg in journey.legs where !leg.isWalking {
            let coordinates: [CLLocationCoordinate2D]

            // Use geometry if available, otherwise fallback to origin -> destination
            if let geometry = leg.geometry, !geometry.coordinates.isEmpty {
                coordinates = geometry.coordinates.map { coord in
                    CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
                }
            } else {
                coordinates = [
                    CLLocationCoordinate2D(latitude: leg.origin.latitude, longitude: leg.origin.longitude),
                    CLLocationCoordinate2D(latitude: leg.destination.latitude, longitude: leg.destination.longitude)
                ]
            }

            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            map.addOverlay(polyline, level: .aboveLabels)
            bounds = bounds.union(polyline.boundingMapRect)
        }

        // Add markers for transfer points
        let transfers = extractTransferPoints(from: journey)
        for transfer in transfers {
            let annotation = JourneyMarkerAnnotation(
                station: transfer.station,
                arrivalTime: transfer.arrivalTime,
                platform: transfer.platform
            )
            map.addAnnotation(annotation)

            let rect = MKMapRect(
                x: MKMapPointForCoordinate(annotation.coordinate).x,
                y: MKMapPointForCoordinate(annotation.coordinate).y,
                width: 0, height: 0
            )
            bounds = bounds.union(rect)
        }

        // Fit map to all overlays
        if !bounds.isNull {
            map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(Color.brand)
                renderer.lineWidth = 3
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? JourneyMarkerAnnotation else { return nil }

            let identifier = "JourneyMarker"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView

            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
            } else {
                view?.annotation = annotation
            }

            view?.markerTintColor = UIColor(Color.brand)
            view?.glyphImage = UIImage(systemName: "arrow.triangle.swap")

            return view
        }
    }
}

/// Custom annotation for journey transfer points.
final class JourneyMarkerAnnotation: NSObject, MKAnnotation {
    @objc dynamic let coordinate: CLLocationCoordinate2D
    let station: Station
    let arrivalTime: Date?
    let platform: PlatformInfo?

    init(station: Station, arrivalTime: Date?, platform: PlatformInfo?) {
        self.station = station
        self.coordinate = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        self.arrivalTime = arrivalTime
        self.platform = platform
        super.init()
    }

    @objc dynamic var title: String? {
        station.displayName
    }

    @objc dynamic var subtitle: String? {
        var parts: [String] = []
        if let arrival = arrivalTime {
            parts.append(arrival.formatted(date: .omitted, time: .shortened))
        }
        if let platform = platform?.best {
            parts.append("Gleis \(platform)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview {
    // Preview with a sample journey
    JourneyMapView(
        journey: Journey.preview,
        finalDestination: Station.preview
    )
}
