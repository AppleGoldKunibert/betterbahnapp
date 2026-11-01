import BetterBahnKit
import MapKit
import SwiftUI

/// All saved train journeys in a time span on a map. Stretches travelled more often get
/// stronger colors. Lines follow the real tracks, OpenRailwayMap is shown as base layer.
struct TravelMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appDesign) private var design
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
    @State private var legendExpanded = true

    struct Stats {
        /// Train rides (legs), not journeys: a check-in is one ride, so a saved journey counts
        /// once per train too and both sources are counted alike.
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
                .toolbar(.hidden, for: .navigationBar)
                .task(id: selection) { await load() }
                .task { await model.syncTraewelling() }
                .task { await model.followTrainPositions() }
                .sheet(isPresented: $showRangeSheet) { rangeSheet }
        }
    }

    // MARK: Overlays

    /// Fahrkarte lays the range and the numbers out as a ticket; Minimal as one card.
    private var isTicket: Bool { design == .fahrkarte }

    private var header: some View {
        VStack(spacing: 8) {
            summaryPanel
            controls

            if model.settings.traewellingEnabled, let error = model.traewellingSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.slightDelay)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .mapPanel(in: .capsule)
            }

            if let progress, progress.done < progress.total {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(.brandLegible)
                    Text("Strecken \(progress.done)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .mapPanel(in: .capsule)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// The range on top, the numbers of the rides in it below.
    @ViewBuilder private var summaryPanel: some View {
        if isTicket {
            summaryContent
                .fontDesign(.rounded)
                .ticketBackground(outline: Color.primary.opacity(0.12))
                .environment(\.cardSurface, Color.ticket)
        } else {
            summaryContent
                .mapPanel(in: .rect(cornerRadius: 22, style: .continuous))
        }
    }

    private var summaryContent: some View {
        VStack(spacing: 0) {
            rangePicker
                .padding(4)
            if range == .custom {
                customRangeButton
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
            if isTicket {
                TicketPerforation()
                    .padding(.vertical, 4)
            } else {
                Divider()
                    .padding(.horizontal, 16)
            }
            HStack(spacing: 0) {
                stat(value: "\(stats.legs)", label: "Fahrten")
                stat(value: stats.kilometers.formatted(.number.precision(.fractionLength(0))), label: "km")
                stat(value: stats.hours.formatted(.number.precision(.fractionLength(1))), label: "Std.")
            }
            .padding(.vertical, 12)
        }
    }

    /// Fixed-width segments so nothing scrolls out of the panel.
    private var rangePicker: some View {
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
                            Text(preset.title)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: preset == .custom ? 44 : .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(range == preset ? Color.onBrandLegible : Color.primary)
                    .background(range == preset ? Color.brandLegible : Color.clear, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityAddTraits(range == preset ? .isSelected : [])
            }
        }
    }

    private var customRangeButton: some View {
        Button {
            showRangeSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(customLabel)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brandLegible)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zeitraum")
        .accessibilityValue(customLabel)
    }

    /// Minimal: the value over a small label. Fahrkarte: a ticket's upper-case label over a large value.
    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: isTicket ? 2 : 0) {
            if isTicket {
                MapTicketLabel(label)
                Text(value).font(.title3.weight(.bold)).monospacedDigit()
            } else {
                Text(value).font(.headline.monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// What's drawn (saved journeys, check-ins) on the left, the map's buttons on the right.
    private var controls: some View {
        HStack(spacing: 8) {
            sourceToggle("Gespeichert", icon: "bookmark.fill", isOn: $includeSaved)
            if model.settings.traewellingEnabled {
                sourceToggle("Träwelling", icon: "checkmark.seal.fill", isOn: $includeTraewelling)
            }
            Spacer(minLength: 0)
            circleButton(showRailwayLayer ? "square.3.layers.3d.top.filled" : "square.3.layers.3d",
                         active: showRailwayLayer) {
                withAnimation { showRailwayLayer.toggle() }
            }
            .accessibilityLabel("OpenRailwayMap-Ebene")
            .accessibilityValue(showRailwayLayer ? String(localized: "An") : String(localized: "Aus"))
            circleButton("magnifyingglass") {
                model.showsTrainSearch = true
            }
            .accessibilityLabel("Zug suchen")
            if !model.settings.traewellingEnabled {
                EmptyView()
            } else if model.isSyncingTraewelling {
                ProgressView().controlSize(.small)
                    .frame(width: 38, height: 38)
                    .mapPanel(in: .circle)
            } else {
                circleButton("arrow.triangle.2.circlepath") {
                    Task { await model.syncTraewelling(force: true) }
                }
                .accessibilityLabel("Träwelling synchronisieren")
            }
        }
    }

    private func circleButton(_ systemImage: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? Color.brandLegible : Color.primary)
                .frame(width: 38, height: 38)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .mapPanel(in: .circle)
    }

    private func sourceToggle(_ title: LocalizedStringKey, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy) { isOn.wrappedValue.toggle() }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .foregroundStyle(isOn.wrappedValue ? Color.brandLegible : Color.secondary)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .mapPanel(in: .capsule)
        .opacity(isOn.wrappedValue ? 1 : 0.75)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private var legend: some View {
        Group {
            if legendExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if isTicket {
                        MapTicketLabel("Wie oft gefahren")
                    } else {
                        Text("Wie oft gefahren").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(HeatColor.legend, id: \.label) { item in
                        HStack(spacing: 8) {
                            Capsule().fill(Color(item.color)).frame(width: 24, height: 6)
                            Text(item.label).font(.caption2.monospacedDigit())
                        }
                    }
                    HStack(spacing: 4) {
                        Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        Link("OpenRailwayMap", destination: URL(string: "https://www.openrailwaymap.org")!)
                    }
                    .font(.system(size: 8))
                    .tint(.secondary)
                    .padding(.top, 2)
                }
                .fontDesign(isTicket ? .rounded : nil)
                .padding(12)
                .mapPanel(in: .rect(cornerRadius: 16, style: .continuous))
                .onTapGesture { withAnimation(.snappy) { legendExpanded = false } }
            } else {
                circleButton("list.bullet") {
                    withAnimation(.snappy) { legendExpanded = true }
                }
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
            .tint(.brandLegible)
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
            stats = Stats(legs: heatmap.legsCount, kilometers: heatmap.kilometers, hours: heatmap.hours)
        }
        progress = nil
    }
}

// MARK: - Map overlays

/// A ticket's small upper-case field label ("FAHRTEN", "NÄCHSTER HALT") over a large value, as the
/// Fahrkarte design (#504) draws it on the map pages.
struct MapTicketLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// The surface of a panel or button floating on a map: Liquid Glass in the Fahrkarte design, the card
    /// surface with a hairline and a light shadow in Minimal (#504).
    func mapPanel(in shape: some Shape) -> some View {
        modifier(MapPanelModifier(shape: shape))
    }
}

private struct MapPanelModifier<PanelShape: Shape>: ViewModifier {
    let shape: PanelShape
    @Environment(\.appDesign) private var design

    func body(content: Content) -> some View {
        if design == .fahrkarte {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(Color.card, in: shape)
                .overlay { shape.stroke(Color.hairline, lineWidth: 1) }
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        }
    }
}

// MARK: - Legible accent

/// The accent color made legible for the map, year review and collection pages (#504): a dark accent
/// (Graphit) is lightened in dark mode, a pale one darkened in light mode, and text on an accent fill turns
/// dark where white wouldn't read (Kit `RGBColor.legible(on:)`).
extension UIColor {
    /// The light page and the dark card the accent has to stand out from.
    private static let legibleLightSurface = RGBColor(red: 0.96, green: 0.955, blue: 0.945)
    private static let legibleDarkSurface = RGBColor(red: 0.12, green: 0.12, blue: 0.13)

    /// The accent for lines, markers, symbols, text and small fills.
    static var brandLegible: UIColor {
        let accent = Theme.shared.accent.color
        return dynamicUIColor(light: accent.legible(on: legibleLightSurface),
                              dark: accent.legible(on: legibleDarkSurface))
    }

    /// Text and symbols on a `brandLegible` fill.
    static var onBrandLegible: UIColor {
        let accent = Theme.shared.accent.color
        return dynamicUIColor(light: accent.legible(on: legibleLightSurface).legibleForeground,
                              dark: accent.legible(on: legibleDarkSurface).legibleForeground)
    }
}

extension Color {
    /// The accent, adjusted so it stays visible on light and dark surfaces.
    static var brandLegible: Color { Color(uiColor: .brandLegible) }
    /// Text and symbols on a `brandLegible` fill: white, or dark on a pale accent.
    static var onBrandLegible: Color { Color(uiColor: .onBrandLegible) }
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
        parts.append(String(localized: "Stand \(position.time.formatted(date: .omitted, time: .standard))"))
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

struct TravelMap: UIViewRepresentable {
    let runs: [SegmentHeatmap.Run]
    let version: Int
    let showRailwayLayer: Bool
    /// Running trains of saved journeys, shown as train markers with speed and fix time in the callout.
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
            // Adjusted accent so the marker stands out on the light and the dark map, glyph in a color that reads on it.
            view.markerTintColor = train.isStale ? .systemGray : .brandLegible
            view.glyphTintColor = train.isStale ? .white : .onBrandLegible
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
