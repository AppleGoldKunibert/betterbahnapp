import BetterBahnKit
import MapKit
import Network
import SwiftUI

/// The live trains on a map (#505): the user's own trains and, if switched on, every other train
/// around. Positions come in every 15 s or so; in between each train runs on along its track once a
/// second, so the markers move smoothly instead of jumping.
@Observable @MainActor
final class LiveTrainsLayer {
    /// A train of the user's that the map draws itself: its last fix and, if known, its track.
    struct OwnTrain: Hashable {
        var name: String
        var position: TrainPosition
        var track: [Coordinate]?
        /// The stops it calls at, where it waits instead of running on.
        var stops: [Coordinate] = []
    }

    /// At most this many other trains are drawn, the ones nearest the middle of the map.
    static let limit = 150

    /// The other trains, where they are this second.
    private(set) var markers: [LiveTrainMarker] = []
    /// The own trains, where they are this second, by name.
    private(set) var ownCoordinates: [String: Coordinate] = [:]

    @ObservationIgnored private var field = LiveTrainField(segments: [], running: [])
    @ObservationIgnored private var segments: [LiveTrainSegment] = []
    @ObservationIgnored private var running: [BahnJetztClient.RunningTrain] = []
    @ObservationIgnored private var coverage: LiveTrainCoverage?
    @ObservationIgnored private var visible: MapArea?
    @ObservationIgnored private var ownTrains: [OwnTrain] = []
    @ObservationIgnored private var motions: [String: LiveTrainMotion] = [:]
    @ObservationIgnored private var smoother = LiveTrainSmoother()
    @ObservationIgnored private var dataChanged = false
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var savingData = false

    /// Runs for as long as the map shows: fetches bahn.jetzt's list at the position interval, loads
    /// the tracks of what's on screen, and moves the markers every second.
    func run(model: AppModel) async {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let saving = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.savingData = saving }
        }
        monitor.start(queue: .global(qos: .utility))
        defer {
            monitor.cancel()
            loading?.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await model.repeatingAtPositionInterval {
                    guard model.settings.showOtherTrains else {
                        if !self.running.isEmpty || !self.segments.isEmpty { self.clearOthers() }
                        return
                    }
                    // A failed fetch keeps the last list; its fixes soon count as too old to move on.
                    if let running = await model.runningTrains() {
                        self.running = running
                        await self.rebuildField()
                    }
                    self.loadSegmentsIfNeeded(model: model)
                }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    self.tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// What the map shows right now; loads the tracks there when needed.
    func setVisible(_ area: MapArea, model: AppModel) {
        visible = area
        loadSegmentsIfNeeded(model: model)
        tick()
    }

    func setVisible(_ region: MKCoordinateRegion, model: AppModel) {
        setVisible(MapArea(center: Coordinate(latitude: region.center.latitude, longitude: region.center.longitude),
                           latitudeSpan: region.span.latitudeDelta, longitudeSpan: region.span.longitudeDelta), model: model)
    }

    /// The user's own trains, drawn by the map itself and left out of `markers`.
    func setOwnTrains(_ trains: [OwnTrain]) {
        guard trains != ownTrains else { return }
        var motions: [String: LiveTrainMotion] = [:]
        for train in trains {
            guard let track = train.track, track.count > 1 else { continue }
            var motion = self.motions[train.name].flatMap { $0.track.points == track ? $0 : nil }
                ?? LiveTrainMotion(track: track, stops: train.stops)
            motion.update(with: train.position)
            motions[train.name] = motion
        }
        self.motions = motions
        ownTrains = trains
        dataChanged = true
        Task { await rebuildField() }
        tick()
    }

    private func clearOthers() {
        running = []
        segments = []
        coverage = nil
        loading?.cancel()
        loading = nil
        field = LiveTrainField(segments: [], running: [])
        tick()
    }

    /// Loads Transitous' trains for the visible area when what's loaded doesn't cover it (or runs out
    /// soon). Never on mobile data unless allowed, never in Low Data Mode, never zoomed far out.
    private func loadSegmentsIfNeeded(model: AppModel) {
        guard model.settings.showOtherTrains, loading == nil, let visible,
              !savingData || model.settings.otherTrainsOnMobileData,
              let area = LiveTrainCoverage.areaToLoad(visible: visible, loaded: coverage) else { return }
        let zoom = LiveTrainCoverage.zoom(for: visible)
        loading = Task {
            defer { loading = nil }
            guard let segments = await model.liveTrainSegments(in: area, zoom: zoom), !Task.isCancelled else { return }
            self.segments = segments
            coverage = LiveTrainCoverage(area: area, until: .now.addingTimeInterval(LiveTrainCoverage.window))
            await rebuildField()
        }
    }

    /// Matches bahn.jetzt's fixes to Transitous' trips off the main thread: the tracks have thousands of points.
    private func rebuildField() async {
        let segments = segments, running = running
        let own = ownTrains.map { (name: $0.name, coordinate: $0.position.coordinate) }
        field = await Task.detached(priority: .userInitiated) {
            LiveTrainField(segments: segments, running: running, ownTrains: own)
        }.value
        dataChanged = true
        tick()
    }

    private func tick() {
        let now = Date.now
        var raw: [String: Coordinate] = [:]
        var others: [LiveTrainMarker] = []
        if let visible {
            others = field.markers(at: now, in: visible.expanded(by: 0.1), limit: Self.limit)
            for marker in others { raw[marker.id] = marker.coordinate }
        }
        for train in ownTrains {
            raw["own:" + train.name] = motions[train.name]?.coordinate(at: now) ?? train.position.coordinate
        }
        let shown = smoother.positions(raw, dataChanged: dataChanged, at: now)
        dataChanged = false
        for index in others.indices {
            if let coordinate = shown[others[index].id] { others[index].coordinate = coordinate }
        }
        var own: [String: Coordinate] = [:]
        for train in ownTrains { own[train.name] = shown["own:" + train.name] }
        // The maps move markers over the second in a straight line to the next spot.
        withAnimation(.linear(duration: 1)) {
            markers = others
            ownCoordinates = own
        }
    }
}

extension LiveTrainsLayer.OwnTrain {
    /// A running train of a leg, on the leg's track with its stops.
    init(_ live: LiveTrainPosition, leg: Leg?) {
        name = live.trainName
        position = live.position
        track = leg?.geometry.flatMap { RouteGeometryService.followsTracks($0) ? $0 : nil }
        stops = leg.map { leg in ([leg.origin] + leg.stopovers.map(\.station) + [leg.destination]).compactMap(\.coordinate) } ?? []
    }
}

// MARK: - MapKit (UIKit) maps

/// Another train on a UIKit map; its coordinate moves every second.
final class OtherTrainAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?
    private(set) var isLongDistance: Bool

    init(_ marker: LiveTrainMarker) {
        id = marker.id
        coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
        isLongDistance = marker.isLongDistance
        super.init()
        update(marker)
    }

    func update(_ marker: LiveTrainMarker) {
        title = marker.name
        subtitle = marker.subtitle
        isLongDistance = marker.isLongDistance
    }
}

extension LiveTrainMarker {
    /// "→ Kassel-Wilhelmshöhe · 180 km/h"
    var subtitle: String? {
        let parts = [nextStop.map { "→ \($0)" },
                     speedKmh.map { "\(Int($0.rounded())) km/h" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Keeps a UIKit map's other trains in step with `LiveTrainsLayer.markers`, moving them smoothly.
@MainActor
final class OtherTrainsAnnotator {
    static let reuseIdentifier = "otherTrain"
    private var annotations: [String: OtherTrainAnnotation] = [:]

    func sync(_ markers: [LiveTrainMarker], on map: MKMapView) {
        let current = Dictionary(markers.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let gone = annotations.filter { current[$0.key] == nil }
        if !gone.isEmpty {
            map.removeAnnotations(Array(gone.values))
            for id in gone.keys { annotations[id] = nil }
        }
        let moved = current.compactMap { id, marker in annotations[id].map { ($0, marker) } }
        let added = current.filter { annotations[$0.key] == nil }.map { OtherTrainAnnotation($0.value) }
        for annotation in added { annotations[annotation.id] = annotation }
        UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
            for (annotation, marker) in moved {
                annotation.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude,
                                                               longitude: marker.coordinate.longitude)
                annotation.update(marker)
            }
        }
        if !added.isEmpty { map.addAnnotations(added) }
    }

    func view(for annotation: OtherTrainAnnotation, on map: MKMapView) -> MKAnnotationView {
        let view = map.dequeueReusableAnnotationView(withIdentifier: Self.reuseIdentifier)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: Self.reuseIdentifier)
        view.annotation = annotation
        view.image = Self.image(longDistance: annotation.isLongDistance)
        view.canShowCallout = true
        // Crowded stations: MapKit hides the trains that would overlap, the own train always stays.
        view.displayPriority = annotation.isLongDistance ? .defaultHigh : .defaultLow
        view.collisionMode = .circle
        return view
    }

    private static let images: [Bool: UIImage] = [true: makeImage(longDistance: true), false: makeImage(longDistance: false)]

    static func image(longDistance: Bool) -> UIImage { images[longDistance]! }

    private static func makeImage(longDistance: Bool) -> UIImage {
        let size: CGFloat = longDistance ? 24 : 20
        let symbol = UIImage(systemName: "tram.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.5, weight: .bold))
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let rect = CGRect(x: 1, y: 1, width: size - 2, height: size - 2)
            UIColor.systemGray.withAlphaComponent(longDistance ? 0.95 : 0.8).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: rect)
            ring.lineWidth = 1.5
            ring.stroke()
            if let symbol = symbol?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                symbol.draw(in: CGRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
        }
    }
}

// MARK: - SwiftUI maps

/// Another train on a SwiftUI map: a small grey dot, its name next to it once zoomed in.
struct OtherTrainMarkerView: View {
    let marker: LiveTrainMarker
    var showsName: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tram.fill")
                .font(.system(size: marker.isLongDistance ? 11 : 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: marker.isLongDistance ? 22 : 18, height: marker.isLongDistance ? 22 : 18)
                .background(Color.gray.opacity(marker.isLongDistance ? 0.95 : 0.8), in: .circle)
                .overlay { Circle().stroke(.white, lineWidth: 1.5) }
            if showsName {
                Text(marker.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: .capsule)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([marker.name, marker.subtitle].compactMap { $0 }.joined(separator: ", ")))
    }
}
