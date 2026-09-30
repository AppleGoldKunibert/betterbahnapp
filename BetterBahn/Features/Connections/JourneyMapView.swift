import BetterBahnKit
import MapKit
import SwiftUI

/// Shows a single journey's route on a map with transfer points and stopovers highlighted as markers.
struct JourneyMapView: View {
    let journey: Journey
    let finalDestination: Station
    @Environment(\.dismiss) var dismiss
    @Environment(AppModel.self) private var model
    @State private var mapVersion = 0
    @State private var selectedTransfer: TransferPoint?
    @State private var alternativeConnections: [Journey] = []
    @State private var isLoadingAlternatives = false
    @State private var trains: [LiveTrainPosition] = []

    var body: some View {
        NavigationStack {
            JourneyMap(journey: journey, version: mapVersion, trains: trains, onMarkerTap: { selectedTransfer = $0 })
                .ignoresSafeArea(edges: .top)
                .navigationTitle("\(journey.legs.first?.origin.displayName ?? "Reise") → \(finalDestination.displayName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Fertig", systemImage: "xmark", role: .cancel) { dismiss() }
                    }
                }
        }
        .task(id: journey) {
            await model.followPositions(of: journey.legs) { trains = $0 }
        }
        .sheet(item: $selectedTransfer) { transfer in
            TransferDetailsSheet(
                transfer: transfer,
                journey: journey,
                finalDestination: finalDestination,
                alternativeConnections: $alternativeConnections,
                isLoadingAlternatives: $isLoadingAlternatives,
                model: model
            )
            .onAppear {
                loadAlternativeConnections(for: transfer)
            }
        }
    }

    private func loadAlternativeConnections(for transfer: TransferPoint) {
        guard transfer.type == .end else { return }

        isLoadingAlternatives = true
        Task {
            do {
                if let arrivalTime = transfer.arrivalTime {
                    let searchStart = arrivalTime.addingTimeInterval(60)
                    let query = JourneyQuery(
                        from: transfer.station,
                        to: finalDestination,
                        date: searchStart
                    )
                    let page = try await model.provider.journeys(query)

                    let longDistance = page.journeys.filter { journey in
                        journey.legs.contains { leg in
                            let name = leg.line?.name ?? ""
                            return name.contains("IC") || name.contains("EC") || name.contains("RJ") ||
                                   name.contains("ICE") || name.contains("TGV")
                        }
                    }

                    withAnimation {
                        alternativeConnections = longDistance.prefix(5).map { $0 }
                        isLoadingAlternatives = false
                    }
                }
            } catch {
                isLoadingAlternatives = false
            }
        }
    }
}

/// Transfer/stopover point with all needed info.
struct TransferPoint: Identifiable {
    enum PointType {
        case start
        case stopover
        case transfer
        case end

        var symbol: String {
            switch self {
            case .start: return "location.fill"
            case .stopover: return "circle.fill"
            case .transfer: return "arrow.triangle.swap"
            case .end: return "flag.fill"
            }
        }
    }

    let id = UUID()
    let station: Station
    let arrivalTime: Date?
    let departureTime: Date?
    let platform: PlatformInfo?
    let departurePlatform: PlatformInfo?
    let type: PointType
    let legIndex: Int

    var transferTimeMinutes: Int? {
        guard type == .transfer, let arrival = arrivalTime, let departure = departureTime else { return nil }
        return Int(departure.timeIntervalSince(arrival) / 60)
    }

    var transferColor: UIColor {
        guard let minutes = transferTimeMinutes else { return UIColor.systemBlue }
        if minutes > 30 {
            return UIColor.systemGreen
        } else if minutes >= 15 {
            return UIColor.systemYellow
        } else {
            return UIColor.systemRed
        }
    }
}

/// Extract transfer points (start, transfers, and end only - no intermediate stopovers).
private func extractTransferPoints(from journey: Journey) -> [TransferPoint] {
    var transfers: [TransferPoint] = []
    
    // Start point
    if let firstLeg = journey.transitLegs.first {
        transfers.append(TransferPoint(
            station: firstLeg.origin,
            arrivalTime: nil,
            departureTime: firstLeg.departure.best,
            platform: firstLeg.departurePlatform,
            departurePlatform: nil,
            type: .start,
            legIndex: 0
        ))
    }

    // Transfer points (between legs only)
    for (index, leg) in journey.transitLegs.dropLast().enumerated() {
        let station = leg.destination
        let nextLeg = journey.transitLegs[index + 1]
        transfers.append(TransferPoint(
            station: station,
            arrivalTime: leg.arrival.best,
            departureTime: nextLeg.departure.best,
            platform: leg.arrivalPlatform,
            departurePlatform: nextLeg.departurePlatform,
            type: .transfer,
            legIndex: index
        ))
    }

    // End point
    if let lastLeg = journey.transitLegs.last {
        transfers.append(TransferPoint(
            station: lastLeg.destination,
            arrivalTime: lastLeg.arrival.best,
            departureTime: nil,
            platform: lastLeg.arrivalPlatform,
            departurePlatform: nil,
            type: .end,
            legIndex: journey.transitLegs.count - 1
        ))
    }
    
    return transfers
}

/// MapKit-based visualization of a journey's route.
struct JourneyMap: UIViewRepresentable {
    let journey: Journey
    let version: Int
    /// Running trains of the journey (from bahn.jetzt), shown as train markers.
    var trains: [LiveTrainPosition] = []
    let onMarkerTap: (TransferPoint) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)

        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
            span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 9)
        ), animated: false)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onMarkerTap = onMarkerTap
        coordinator.syncTrains(trains, on: map)

        // Route and markers only when the journey changed, so the periodic train refresh doesn't
        // redraw everything and zoom back out.
        guard coordinator.renderedJourney != journey || coordinator.renderedVersion != version else { return }
        coordinator.renderedJourney = journey
        coordinator.renderedVersion = version

        map.removeOverlays(map.overlays.filter { $0 is MKPolyline })
        map.removeAnnotations(map.annotations.filter { $0 is JourneyMarkerAnnotation })

        var bounds = MKMapRect.null

        for leg in journey.legs where !leg.isWalking {
            let coordinates: [CLLocationCoordinate2D]

            if let geometry = leg.geometry, !geometry.isEmpty {
                coordinates = geometry.map { coord in
                    CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
                }
            } else if let originCoord = leg.origin.coordinate, let destCoord = leg.destination.coordinate {
                coordinates = [
                    CLLocationCoordinate2D(latitude: originCoord.latitude, longitude: originCoord.longitude),
                    CLLocationCoordinate2D(latitude: destCoord.latitude, longitude: destCoord.longitude)
                ]
            } else {
                continue
            }

            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            map.addOverlay(polyline, level: .aboveLabels)
            bounds = bounds.union(polyline.boundingMapRect)
        }

        let transfers = extractTransferPoints(from: journey)
        for transfer in transfers {
            let annotation = JourneyMarkerAnnotation(transfer: transfer)
            map.addAnnotation(annotation)

            let mapPoint = MKMapPoint(annotation.coordinate)
            let rect = MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0)
            bounds = bounds.union(rect)
        }

        if !bounds.isNull {
            map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onMarkerTap: ((TransferPoint) -> Void)?
        var renderedJourney: Journey?
        var renderedVersion = -1
        private var trainAnnotations: [String: TrainAnnotation] = [:]

        /// Adds, moves and removes train markers in place so an open callout survives the refresh.
        func syncTrains(_ trains: [LiveTrainPosition], on map: MKMapView) {
            let current = Dictionary(trains.map { ($0.trainName, $0) }, uniquingKeysWith: { $1 })
            for (name, annotation) in trainAnnotations where current[name] == nil {
                map.removeAnnotation(annotation)
                trainAnnotations[name] = nil
            }
            for (name, live) in current {
                if let annotation = trainAnnotations[name] {
                    annotation.update(live)
                    (map.view(for: annotation) as? MKMarkerAnnotationView)?.markerTintColor = annotation.isStale ? .systemGray : UIColor(Color.brand)
                } else {
                    let annotation = TrainAnnotation(live)
                    trainAnnotations[name] = annotation
                    map.addAnnotation(annotation)
                }
            }
        }

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
            if let train = annotation as? TrainAnnotation {
                let id = "train"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: train, reuseIdentifier: id)
                view.annotation = train
                view.glyphImage = UIImage(systemName: "tram.fill")
                view.markerTintColor = train.isStale ? .systemGray : UIColor(Color.brand)
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            guard let annotation = annotation as? JourneyMarkerAnnotation else { return nil }
            
            let identifier = "TransferMarker"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
            }
            
            view?.annotation = annotation
            
            // Different colors for each type
            switch annotation.transfer.type {
            case .start:
                view?.markerTintColor = UIColor.systemBlue
            case .stopover:
                view?.markerTintColor = UIColor.systemRed
            case .transfer:
                view?.markerTintColor = annotation.transfer.transferColor
                view?.glyphText = annotation.transfer.transferTimeMinutes.map { "\($0)m" } ?? "∞"
            case .end:
                view?.markerTintColor = UIColor.systemGreen
            }
            
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? JourneyMarkerAnnotation else { return }
            onMarkerTap?(annotation.transfer)
            mapView.deselectAnnotation(annotation, animated: true)
        }

        private func annotationColor(for type: TransferPoint.PointType) -> UIColor {
            switch type {
            case .start, .stopover, .transfer: return UIColor(Color.brand)
            case .end: return UIColor(Color.punctual)
            }
        }
    }
}

/// Custom annotation for journey transfer points and stopovers.
final class JourneyMarkerAnnotation: NSObject, MKAnnotation {
    @objc dynamic let coordinate: CLLocationCoordinate2D
    let transfer: TransferPoint

    init(transfer: TransferPoint) {
        self.transfer = transfer
        let coord = transfer.station.coordinate ?? Coordinate(latitude: 0, longitude: 0)
        self.coordinate = CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
        super.init()
    }

    @objc dynamic var title: String? {
        transfer.station.displayName
    }

    @objc dynamic var subtitle: String? {
        var parts: [String] = []
        if let arrival = transfer.arrivalTime {
            parts.append("An: \(arrival.formatted(date: .omitted, time: .shortened))")
        }
        if let departure = transfer.departureTime {
            parts.append("Ab: \(departure.formatted(date: .omitted, time: .shortened))")
        }
        if let platform = transfer.platform?.best {
            parts.append("Gleis \(platform)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Bottom sheet showing transfer/stopover details and alternative connections.
struct TransferDetailsSheet: View {
    let transfer: TransferPoint
    let journey: Journey
    let finalDestination: Station
    @Binding var alternativeConnections: [Journey]
    @Binding var isLoadingAlternatives: Bool
    let model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: transfer.type.symbol)
                                .font(.headline)
                                .foregroundStyle(transfer.type == .end ? Color.punctual : Color.brand)
                            Text(transfer.station.displayName)
                                .font(.headline)
                        }
                        if transfer.type == .stopover {
                            Text("Zwischenhalt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // Details
                    VStack(alignment: .leading, spacing: 12) {
                        if let arrival = transfer.arrivalTime {
                            HStack {
                                Label("Ankunft", systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(arrival.formatted(date: .omitted, time: .shortened))
                                    .font(.headline)
                            }
                        }

                        if let departure = transfer.departureTime {
                            HStack {
                                Label("Abfahrt", systemImage: "arrow.up")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(departure.formatted(date: .omitted, time: .shortened))
                                    .font(.headline)
                            }
                        }

                        if transfer.type == .transfer, transfer.platform?.best != nil || transfer.departurePlatform?.best != nil {
                            HStack {
                                Label("Gleiswechsel", systemImage: "train.side.front.car")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 6) {
                                    Text(transfer.platform?.best ?? "?")
                                    Image(systemName: "arrow.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(transfer.departurePlatform?.best ?? "?")
                                }
                                .font(.headline)
                            }
                        } else if let platform = transfer.platform?.best {
                            HStack {
                                Label("Gleis", systemImage: "train.side.front.car")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(platform)
                                    .font(.headline)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Alternative connections (only for end point)
                    if transfer.type == .end {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Label("Alternativen (nächste Stunde)", systemImage: "arrow.triangle.branch")
                                .font(.subheadline.weight(.semibold))

                            if isLoadingAlternatives {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else if alternativeConnections.isEmpty {
                                Text("Keine Verbindungen gefunden")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(alternativeConnections, id: \.id) { altJourney in
                                        NavigationLink {
                                            JourneyDetailView(
                                                journey: altJourney,
                                                finalDestination: finalDestination
                                            )
                                        } label: {
                                            JourneyCard(journey: altJourney)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.vertical)
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
