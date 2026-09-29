import BetterBahnKit
import MapKit
import SwiftUI

/// All saved train journeys in a time span on a map. Stretches travelled more often get
/// stronger colors. Lines follow the real tracks, OpenRailwayMap is shown as base layer.
struct TravelMapView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TravelMapRange = .month
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
    @State private var customTo = Date.now
    @State private var showRailwayLayer = true
    @State private var runs: [SegmentHeatmap.Run] = []
    /// Bumped with every new set of runs. Comparing a counter beats comparing a few hundred
    /// thousand coordinates on every SwiftUI update.
    @State private var runsVersion = 0
    @State private var stats = Stats()
    @State private var progress: (done: Int, total: Int)?
    @State private var showRangeSheet = false
    @State private var includeSaved = true
    @State private var includeTraewelling = true
    @State private var hasJourneysInRange = true
    @State private var legendExpanded = true

    struct Stats {
        var journeys = 0
        var legs = 0
        var kilometers = 0.0
        var hours = 0.0
    }

    /// What's shown; also the identity of the loaded heatmap, so unrelated view re-creations
    /// (e.g. switching tabs) don't throw the result away.
    private var selection: TravelMapSelection {
        TravelMapSelection(range: range,
                           customFrom: range == .custom ? customFrom : nil,
                           customTo: range == .custom ? customTo : nil,
                           includeSaved: includeSaved,
                           includeTraewelling: includeTraewelling && model.settings.traewellingEnabled)
    }

    var body: some View {
        NavigationStack {
            TravelMap(runs: runs, version: runsVersion, showRailwayLayer: showRailwayLayer,
                      trains: Array(model.trainPositions.values))
                .ignoresSafeArea(edges: [.top, .bottom])
                .overlay(alignment: .top) { header }
                .overlay(alignment: .bottomTrailing) { legend }
                .overlay {
                    if !hasJourneysInRange, !model.isSyncingTraewelling {
                        emptyHint
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .task(id: selection) { await load() }
                .task { await model.syncTraewelling() }
                .task { await model.followTrainPositions() }
                .sheet(isPresented: $showRangeSheet) { rangeSheet }
        }
    }

    // MARK: Overlays

    private var header: some View {
        VStack(spacing: 10) {
            // Fixed-width segments so nothing scrolls out of the capsule.
            HStack(spacing: 2) {
                ForEach(TravelMapRange.allCases) { preset in
                    Button {
                        if preset == .custom { showRangeSheet = true }
                        withAnimation(.snappy) { range = preset }
                    } label: {
                        Group {
                            if preset == .custom {
                                Image(systemName: "calendar")
                            } else {
                                Text(preset.rawValue)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: preset == .custom ? 44 : .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(range == preset ? .white : .primary)
                        .background(range == preset ? Color.brand : Color.clear, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.rawValue)
                }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)

            if range == .custom {
                Button {
                    showRangeSheet = true
                } label: {
                    Label(customLabel, systemImage: "calendar")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .capsule)
            }

            HStack(spacing: 0) {
                stat(value: "\(stats.journeys)", label: "Reisen", icon: "bookmark.fill")
                Divider().frame(height: 28)
                stat(value: stats.kilometers.formatted(.number.precision(.fractionLength(0))), label: "km", icon: "point.topleft.down.to.point.bottomright.curvepath.fill")
                Divider().frame(height: 28)
                stat(value: stats.hours.formatted(.number.precision(.fractionLength(1))), label: "Std.", icon: "clock.fill")
                Divider().frame(height: 28)
                Button {
                    withAnimation { showRailwayLayer.toggle() }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: showRailwayLayer ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
                            .font(.headline)
                        Text("Gleise").font(.caption2)
                    }
                    .foregroundStyle(showRailwayLayer ? Color.brand : .secondary)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("OpenRailwayMap-Ebene")
            }
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))

            HStack(spacing: 8) {
                sourceToggle("Gespeichert", icon: "bookmark.fill", isOn: $includeSaved)
                if model.settings.traewellingEnabled {
                    sourceToggle("Träwelling", icon: "checkmark.seal.fill", isOn: $includeTraewelling)
                }
                Spacer(minLength: 0)
                if !model.settings.traewellingEnabled {
                    EmptyView()
                } else if model.isSyncingTraewelling {
                    ProgressView().controlSize(.small)
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                } else {
                    Button {
                        Task { await model.syncTraewelling(force: true) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .circle)
                    .accessibilityLabel("Träwelling synchronisieren")
                }
            }

            if model.settings.traewellingEnabled, let error = model.traewellingSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.slightDelay)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            if let progress, progress.done < progress.total {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(.brand)
                    Text("Strecken \(progress.done)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "map").font(.title).foregroundStyle(.secondary)
            let hasAny = !model.savedJourneys.isEmpty || !model.traewellingTrips.isEmpty
            Text(hasAny ? "Keine Fahrten in diesem Zeitraum" : "Noch keine Fahrten")
                .font(.headline)
            Text(hasAny ? "Wähle einen längeren Zeitraum." : "Deine gespeicherten Reisen erscheinen hier auf der Karte.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func sourceToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy) { isOn.wrappedValue.toggle() }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isOn.wrappedValue ? Color.brand : .secondary)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .opacity(isOn.wrappedValue ? 1 : 0.7)
    }

    private func stat(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleOnly)
        }
        .frame(maxWidth: .infinity)
    }

    private var legend: some View {
        Group {
            if legendExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wie oft gefahren").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(HeatColor.legend, id: \.label) { item in
                        HStack(spacing: 8) {
                            Capsule().fill(Color(item.color)).frame(width: 22, height: 5)
                            Text(item.label).font(.caption2.monospacedDigit())
                        }
                    }
                    Text("© OpenStreetMap, OpenRailwayMap")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .onTapGesture { withAnimation(.snappy) { legendExpanded = false } }
            } else {
                Button {
                    withAnimation(.snappy) { legendExpanded = true }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("Legende anzeigen")
            }
        }
        .padding(.trailing)
        .padding(.bottom, 16)
    }

    private var customLabel: String {
        let format = Date.FormatStyle().day().month(.abbreviated)
        return "\(customFrom.formatted(format)) – \(customTo.formatted(format))"
    }

    private var rangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Von", selection: $customFrom, displayedComponents: .date)
                DatePicker("Bis", selection: $customTo, displayedComponents: .date)
            }
            .tint(.brand)
            .navigationTitle("Zeitraum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { showRangeSheet = false }
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    // MARK: Data

    private func load() async {
        // The background prewarm builds the same thing; let this one have the CPU and network.
        model.stopTravelMapPrewarm()
        let selection = selection
        hasJourneysInRange = !model.mapJourneys(for: selection).isEmpty
        guard let heatmap = await model.mapHeatmap(
            for: selection,
            onProgress: { done, total in progress = (done, total) },
            onPartial: { partial in
                runs = partial
                runsVersion += 1
            })
        else { return } // cancelled
        withAnimation {
            runs = heatmap.runs
            runsVersion += 1
            stats = Stats(journeys: heatmap.journeysCount, legs: heatmap.legsCount,
                          kilometers: heatmap.kilometers, hours: heatmap.hours)
        }
        progress = nil
    }
}

// MARK: - Colors

enum HeatColor {
    static func color(for count: Int) -> UIColor {
        switch count {
        case ..<2: UIColor(red: 0.98, green: 0.70, blue: 0.20, alpha: 1)
        case 2: UIColor(red: 0.96, green: 0.45, blue: 0.12, alpha: 1)
        case 3...4: UIColor(red: 0.86, green: 0.09, blue: 0.19, alpha: 1)
        case 5...9: UIColor(red: 0.62, green: 0.08, blue: 0.45, alpha: 1)
        default: UIColor(red: 0.33, green: 0.10, blue: 0.55, alpha: 1)
        }
    }

    static func width(for count: Int) -> CGFloat {
        CGFloat(3 + min(count, 8))
    }

    static let legend: [(label: String, color: UIColor)] = [
        ("1×", color(for: 1)), ("2×", color(for: 2)), ("3–4×", color(for: 3)), ("5–9×", color(for: 5)), ("10×+", color(for: 10)),
    ]
}

// MARK: - MapKit bridge

/// A running train. Title is its name; the callout subtitle carries speed and the time of the GPS fix.
final class TrainAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?
    private(set) var isStale = false

    init(_ live: LiveTrainPosition) {
        coordinate = live.position.coordinate.clCoordinate
        super.init()
        update(live)
    }

    func update(_ live: LiveTrainPosition) {
        let position = live.position
        coordinate = position.coordinate.clCoordinate
        title = live.trainName
        var parts: [String] = []
        if let speed = position.speedKmh { parts.append("\(Int(speed.rounded())) km/h") }
        parts.append("Stand \(position.time.formatted(date: .omitted, time: .standard))")
        subtitle = parts.joined(separator: " · ")
        isStale = position.isStale()
    }
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

nonisolated final class HeatPolyline: MKPolyline, @unchecked Sendable {
    var count = 1
}

/// OpenRailwayMap tiles with a plain User-Agent and attribution in the legend.
nonisolated final class RailwayTileOverlay: MKTileOverlay, @unchecked Sendable {
    init() {
        super.init(urlTemplate: "https://tiles.openrailwaymap.org/standard/{z}/{x}/{y}.png")
        canReplaceMapContent = false
        maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        var request = URLRequest(url: url(forTilePath: path))
        request.setValue(HTTPClient.identifyingUserAgent, forHTTPHeaderField: "User-Agent")
        nonisolated(unsafe) let completion = result
        URLSession.shared.dataTask(with: request) { data, _, error in completion(data, error) }.resume()
    }
}

struct TravelMap: UIViewRepresentable {
    let runs: [SegmentHeatmap.Run]
    let version: Int
    let showRailwayLayer: Bool
    /// Running ICEs of saved journeys, shown as train markers with speed and fix time in the callout.
    var trains: [LiveTrainPosition] = []

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
                                         span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 9)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        // Railway layer
        if showRailwayLayer, coordinator.railwayOverlay == nil {
            let overlay = RailwayTileOverlay()
            map.addOverlay(overlay, level: .aboveRoads)
            coordinator.railwayOverlay = overlay
        } else if !showRailwayLayer, let overlay = coordinator.railwayOverlay {
            map.removeOverlay(overlay)
            coordinator.railwayOverlay = nil
        }

        coordinator.syncTrains(trains, on: map)

        // Route lines: only rebuild when data changed. Draw rare stretches first so frequent ones are on top.
        guard coordinator.renderedVersion != version else { return }
        coordinator.renderedVersion = version
        map.removeOverlays(map.overlays.filter { $0 is HeatPolyline })
        var bounds = MKMapRect.null
        for run in runs.sorted(by: { $0.count < $1.count }) {
            let points = run.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let line = HeatPolyline(coordinates: points, count: points.count)
            line.count = run.count
            map.addOverlay(line, level: .aboveLabels)
            bounds = bounds.union(line.boundingMapRect)
        }
        if !bounds.isNull, !coordinator.didFit {
            coordinator.didFit = true
            map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 200, left: 40, bottom: 160, right: 40), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var railwayOverlay: RailwayTileOverlay?
        var renderedVersion = -1
        var didFit = false
        private var trainAnnotations: [String: TrainAnnotation] = [:]

        /// Adds, moves and removes train markers in place so an open callout survives the periodic refresh.
        func syncTrains(_ trains: [LiveTrainPosition], on map: MKMapView) {
            let current = Dictionary(trains.map { ($0.trainName, $0) }, uniquingKeysWith: { $1 })
            for (name, annotation) in trainAnnotations where current[name] == nil {
                map.removeAnnotation(annotation)
                trainAnnotations[name] = nil
            }
            for (name, live) in current {
                if let annotation = trainAnnotations[name] {
                    annotation.update(live)
                } else {
                    let annotation = TrainAnnotation(live)
                    trainAnnotations[name] = annotation
                    map.addAnnotation(annotation)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let train = annotation as? TrainAnnotation else { return nil }
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

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = 0.45
                return renderer
            }
            if let line = overlay as? HeatPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = HeatColor.color(for: line.count)
                renderer.lineWidth = HeatColor.width(for: line.count)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
