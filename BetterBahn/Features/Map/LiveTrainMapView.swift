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
    /// Track geometry if known, else the stops joined by straight lines.
    var path: [Coordinate]
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
        // The train is usually already underway before the leg starts, which is when it's most
        // interesting where it is.
        start = leg.departure.best.addingTimeInterval(-2 * 3600)
        end = leg.arrival.best.addingTimeInterval(10 * 60)
    }

    init(trip: Trip) {
        line = trip.line
        stops = trip.stopovers
        plannedDeparture = trip.stopovers.lazy.compactMap(\.departure).first?.planned ?? .now
        path = trip.stopovers.compactMap(\.station.coordinate)
        start = (trip.stopovers.lazy.compactMap(\.departure).first?.best ?? .distantPast).addingTimeInterval(-10 * 60)
        end = (trip.stopovers.last?.arrival?.best ?? .distantFuture).addingTimeInterval(10 * 60)
    }

    var isSupported: Bool { BahnJetztClient.supports(line) }

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
                                .foregroundStyle(.white)
                                .frame(width: size * 0.46, height: size * 0.46)
                                .background(Color.brand, in: .circle)
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
                    available = (try? await model.livePosition(of: route.line, plannedDeparture: route.plannedDeparture)) != nil
                    if available { return }
                } else if Date.now > route.end {
                    return
                }
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private var tile: some View {
        IconTile(systemImage: systemImage, color: color, size: size)
    }
}

/// A single train on the map: its route and stops, and where it is right now (from bahn.jetzt,
/// refreshed while the map is open).
struct LiveTrainMapView: View {
    let route: LiveTrainRoute

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var position: TrainPosition?
    @State private var camera: MapCameraPosition = .automatic
    @State private var following = true

    private var color: Color { route.line?.product.color ?? .brand }

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                if route.path.count > 1 {
                    MapPolyline(coordinates: route.path.map(\.clCoordinate))
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
                    Annotation(route.line?.name ?? "Zug", coordinate: position.coordinate.clCoordinate, anchor: .center) {
                        Image(systemName: route.line?.product.symbolName ?? "tram.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
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
            .navigationTitle(route.line.map { "\($0.name) live" } ?? "Live-Karte")
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
            await model.followPosition(of: route.line, plannedDeparture: route.plannedDeparture) { new in
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

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if let position {
                    HStack(spacing: 12) {
                        if let speed = position.speedKmh {
                            Label("\(Int(speed.rounded())) km/h", systemImage: "gauge.with.dots.needle.67percent")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        Spacer()
                        Text("Stand \(position.time.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if position.isStale() {
                        Label("Position nicht mehr aktuell", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.slightDelay)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Suche Zugposition …").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let next = route.nextStop(), let time = next.arrival ?? next.departure {
                    HStack(spacing: 4) {
                        Text("Nächster Halt:").foregroundStyle(.secondary)
                        Text(next.station.displayName).lineLimit(1)
                        Spacer()
                        Text(time.best.timeString)
                            .monospacedDigit()
                            .foregroundStyle(delayColor(time.delayMinutes))
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
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
