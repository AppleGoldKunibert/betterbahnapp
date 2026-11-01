import BetterBahnKit
import MapKit
import SwiftUI

/// One train's run as the live map needs it: route, stops and what to look it up by in bahn.jetzt.
struct LiveTrainRoute: Hashable {
    var line: Line?
    /// Planned departure somewhere along the route, to tell today's run from yesterday's.
    var plannedDeparture: Date
    /// Stops in order, including the first and last.
    var stops: [Stopover]
    /// Track geometry if known, else the stops joined by straight lines. Only good enough to tell
    /// whether a position lies on the route; the map draws `track` instead.
    var path: [Coordinate]
    /// The run as a leg, to look up its track geometry when it came without.
    var geometryLeg: Leg?
    /// The train's final destination, to tell it from a foreign train with the same run number.
    var destination: String?
    /// When the train can be running at all: nothing is asked for outside of it.
    var start: Date
    var end: Date

    init(leg: Leg) {
        line = leg.line
        plannedDeparture = leg.departure.planned
        stops = leg.stopovers.isEmpty
            ? [Stopover(station: leg.origin, arrival: nil, departure: leg.departure, arrivalPlatform: nil,
                        departurePlatform: leg.departurePlatform, cancelled: false),
               Stopover(station: leg.destination, arrival: leg.arrival, departure: nil, arrivalPlatform: leg.arrivalPlatform,
                        departurePlatform: nil, cancelled: false)]
            : leg.stopovers
        path = leg.geometry.flatMap { $0.isEmpty ? nil : $0 } ?? stops.compactMap(\.station.coordinate)
        destination = leg.direction
        geometryLeg = leg
        // The train is usually already underway before the leg starts, which is when it's most
        // interesting where it is.
        start = leg.departure.best.addingTimeInterval(-2 * 3600)
        end = leg.arrival.best.addingTimeInterval(10 * 60)
    }

    init(trip: Trip) {
        line = trip.line
        stops = trip.stopovers
        plannedDeparture = trip.stopovers.lazy.compactMap(\.departure).first?.planned ?? .now
        path = trip.geometry.flatMap { $0.isEmpty ? nil : $0 } ?? trip.stopovers.compactMap(\.station.coordinate)
        destination = trip.stopovers.last?.station.name
        if let first = trip.stopovers.first, let last = trip.stopovers.last, trip.stopovers.count > 1,
           let departure = first.departure, let arrival = last.arrival {
            geometryLeg = Leg(origin: first.station, destination: last.station, departure: departure, arrival: arrival,
                              departurePlatform: first.departurePlatform, arrivalPlatform: last.arrivalPlatform,
                              tripId: trip.id, line: trip.line, direction: trip.direction, isWalking: false,
                              cancelled: trip.cancelled, stopovers: trip.stopovers, remarks: [], source: trip.source,
                              geometry: trip.geometry)
        }
        start = (trip.stopovers.lazy.compactMap(\.departure).first?.best ?? .distantPast).addingTimeInterval(-10 * 60)
        end = (trip.stopovers.last?.arrival?.best ?? .distantFuture).addingTimeInterval(10 * 60)
    }

    var isSupported: Bool { BahnJetztClient.supports(line) }

    var hint: BahnJetztClient.RouteHint { .init(destination: destination, path: path) }

    func mayBeRunning(at date: Date = .now) -> Bool { start <= date && date <= end }

    /// The next stop the train hasn't left yet.
    func nextStop(after date: Date = .now) -> Stopover? {
        stops.first { !$0.cancelled && (($0.departure ?? $0.arrival)?.best ?? .distantFuture) > date }
    }
}

/// A train's icon tile that doubles as the way into its live map: once bahn.jetzt has a position
/// for the train, a small location badge sits on the tile and tapping it opens the map. Only asks
/// while the train may be running.
struct LiveTrainIconTile: View {
    let route: LiveTrainRoute
    let systemImage: String
    let color: Color
    var size: CGFloat = 38
    var logo: TransitLogo? = nil

    @Environment(AppModel.self) private var model
    @State private var available = false
    @State private var showMap = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if available {
                Button {
                    showMap = true
                } label: {
                    tile
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "location.fill")
                                .font(.system(size: size * 0.24, weight: .bold))
                                .foregroundStyle(Color.onBrandText)
                                .frame(width: size * 0.46, height: size * 0.46)
                                .background(Color.brandText, in: .circle)
                                .overlay { Circle().stroke(Color.card, lineWidth: 2) }
                                .offset(x: size * 0.16, y: size * 0.16)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Live-Karte")
            } else {
                tile
            }
        }
        .sheet(isPresented: $showMap) {
            LiveTrainMapView(route: route)
        }
        .task(id: route) {
            available = false
            guard route.isSupported else { return }
            // Checked again now and then: a train only shows up in bahn.jetzt's list once it runs.
            while !Task.isCancelled {
                if route.mayBeRunning() {
                    available = (try? await model.livePosition(of: route)) != nil
                    if available { return }
                } else if Date.now > route.end {
                    return
                }
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private var tile: some View {
        IconTile(systemImage: systemImage, color: color, size: size, logo: logo)
    }
}

/// A single train on the map: its route and stops, and where it is right now (from bahn.jetzt,
/// refreshed while the map is open).
struct LiveTrainMapView: View {
    let route: LiveTrainRoute

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @Environment(AppModel.self) private var model
    @State private var position: TrainPosition?
    @State private var camera: MapCameraPosition = .automatic
    @State private var following = true
    /// The route along the tracks; nil until known, and then the map shows only the stops rather
    /// than straight lines across country.
    @State private var track: [Coordinate]?

    /// The line's color, else the accent adjusted to stand out on the light and the dark map.
    private var color: Color { route.line?.color ?? .brandText }
    /// The train symbol on `color`: white on line colors, dark on a pale accent.
    private var glyphColor: Color { route.line?.color == nil ? .onBrandText : .white }

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                if let track {
                    MapPolyline(coordinates: track.map(\.clCoordinate))
                        .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                ForEach(route.stops) { stop in
                    if let coordinate = stop.station.coordinate {
                        Annotation(stop.station.displayName, coordinate: coordinate.clCoordinate, anchor: .center) {
                            Circle()
                                .fill(.white)
                                .stroke(color, lineWidth: 2)
                                .frame(width: 9, height: 9)
                                .opacity(stop.cancelled ? 0.4 : 1)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                if let position {
                    Annotation(route.line?.name ?? String(localized: "Zug"), coordinate: position.coordinate.clCoordinate, anchor: .center) {
                        Image(systemName: route.line?.symbolName ?? "tram.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(position.isStale() ? Color.white : glyphColor)
                            .frame(width: 32, height: 32)
                            .background(position.isStale() ? Color.gray : color, in: .circle)
                            .overlay { Circle().stroke(.white, lineWidth: 2) }
                            .shadow(radius: 3)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .onMapCameraChange { context in
                // Panning away stops following the train until the button brings it back.
                if let position, following,
                   context.region.center.distance(to: position.coordinate.clCoordinate) > 2_000 {
                    following = false
                }
            }
            .safeAreaInset(edge: .bottom) { statusCard }
            .navigationTitle(route.line.map { String(localized: "\($0.name) live") } ?? String(localized: "Live-Karte"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(following ? "Zug folgen" : "Zum Zug", systemImage: following ? "location.fill" : "location") {
                        following = true
                        center()
                    }
                    .disabled(position == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
        }
        .task(id: route) {
            if RouteGeometryService.followsTracks(route.path) {
                track = route.path
            } else if let leg = route.geometryLeg {
                track = await model.geometry(for: leg)
            }
        }
        .task(id: route) {
            await model.followPosition(of: route) { new in
                position = new
                if following { center() }
            }
        }
    }

    private func center() {
        guard let position else { return }
        withAnimation {
            camera = .region(MKCoordinateRegion(center: position.coordinate.clCoordinate,
                                                latitudinalMeters: 25_000, longitudinalMeters: 25_000))
        }
    }

    // MARK: Status

    /// Minimal: a card with the speed and the next stop. Fahrkarte: a ticket with the same as labelled fields.
    private var statusCard: some View {
        Group {
            if design == .fahrkarte {
                ticketStatus
            } else {
                Card { minimalStatus }
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var speedText: String? {
        position?.speedKmh.map { "\(Int($0.rounded())) km/h" }
    }

    private func fixTime(_ position: TrainPosition) -> String {
        position.time.formatted(date: .omitted, time: .standard)
    }

    private var minimalStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let position {
                HStack(spacing: 12) {
                    IconTile(systemImage: "gauge.with.dots.needle.67percent", color: .brand, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        if let speedText {
                            Text(speedText).font(.headline).monospacedDigit()
                        }
                        Text("Stand \(fixTime(position))")
                            .font(speedText == nil ? .headline : .caption)
                            .foregroundStyle(speedText == nil ? Color.primary : Color.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                if position.isStale() { staleWarning }
            } else {
                searching
            }
            if let next = route.nextStop(), let time = next.arrival ?? next.departure {
                Divider()
                HStack(spacing: 12) {
                    IconTile(systemImage: "mappin.and.ellipse", color: .secondary, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nächster Halt").font(.caption).foregroundStyle(.secondary)
                        Text(next.station.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(time.best.timeString)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(delayColor(time.delayMinutes))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ticketStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let position {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            MapTicketLabel("Geschwindigkeit")
                            Text(speedText ?? "–").font(.title2.weight(.bold)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            MapTicketLabel("Stand")
                            Text(fixTime(position)).font(.title2.weight(.bold)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    if position.isStale() { staleWarning }
                } else {
                    searching
                }
            }
            .padding(16)
            if let next = route.nextStop(), let time = next.arrival ?? next.departure {
                TicketPerforation()
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        MapTicketLabel("Nächster Halt")
                        Text(next.station.displayName)
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 8)
                    Text(time.best.timeString)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(delayColor(time.delayMinutes))
                }
                .padding(16)
                .accessibilityElement(children: .combine)
            }
        }
        .fontDesign(.rounded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ticketBackground(outline: Color.primary.opacity(0.12))
        .environment(\.cardSurface, Color.ticket)
    }

    private var staleWarning: some View {
        Label("Position nicht mehr aktuell", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.slightDelay)
    }

    private var searching: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Suche Zugposition …").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

private extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
