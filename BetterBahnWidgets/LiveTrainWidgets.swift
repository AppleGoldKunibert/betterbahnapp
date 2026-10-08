import AppIntents
import BetterBahnKit
import MapKit
import SwiftUI
import UIKit
import WidgetKit

/// The refresh button on the live widgets: running it makes WidgetKit reload the widget, which
/// fetches the train's position again without opening the app.
struct RefreshLiveWidgetIntent: AppIntent {
    static var title: LocalizedStringResource { "Aktualisieren" }

    func perform() async throws -> some IntentResult { .result() }
}

struct LiveTrainEntry: TimelineEntry {
    let date: Date
    let state: JourneyWidgetState?
    let journeyID: String?
    /// The ridden train's position, fetched when the timeline was made (or the app's last one).
    let position: TrainPosition?
    /// Map snapshot around `position`, only for the position widget.
    let map: UIImage?

    var mapLink: URL? {
        guard let journeyID, let state else { return nil }
        return TrainMapLink.url(journeyID: journeyID, legIndex: state.legIndex)
    }
}

/// Fetches the ridden train's position from bahn.jetzt itself (the app can't refresh it in the
/// background), so the live widgets update on their own and on the refresh button.
struct LiveTrainProvider: TimelineProvider {
    let withMap: Bool

    /// The app's own position counts this long when bahn.jetzt can't be reached from the widget.
    private static let storedPositionLifetime: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> LiveTrainEntry {
        LiveTrainEntry(date: .now, state: .preview, journeyID: nil,
                       position: TrainPosition(coordinate: Coordinate(latitude: 50.94, longitude: 6.96), time: .now,
                                               speedKmh: 243, source: nil),
                       map: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LiveTrainEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let size = context.displaySize
        Task {
            completion(await currentEntry(mapSize: size))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveTrainEntry>) -> Void) {
        let size = context.displaySize
        Task {
            let first = await currentEntry(mapSize: size)
            var entries = [first]
            // Later entries keep the fetched position (shown with its time) but move the next stop on.
            if let journey = WidgetStore.load()?.journey {
                for date in JourneyWidgetState.changeDates(of: journey, after: first.date).prefix(30) {
                    entries.append(LiveTrainEntry(date: date, state: JourneyWidgetState.from(journey, now: date),
                                                  journeyID: first.journeyID, position: first.position, map: first.map))
                }
            }
            // While riding, ask WidgetKit for a fresh position soon; iOS decides how often it really reloads.
            let reload = Date.now.addingTimeInterval(first.position != nil ? 10 * 60 : 30 * 60)
            completion(Timeline(entries: entries, policy: .after(reload)))
        }
    }

    private func currentEntry(mapSize: CGSize) async -> LiveTrainEntry {
        let now = Date.now
        let snapshot = WidgetStore.load()
        guard let journey = snapshot?.journey, let state = JourneyWidgetState.from(journey, now: now) else {
            return LiveTrainEntry(date: now, state: nil, journeyID: nil, position: nil, map: nil)
        }
        var position: TrainPosition?
        if let leg = state.ridingLeg(of: journey), BahnJetztClient.supports(leg.line) {
            position = try? await BahnJetztClient().position(for: leg)
            if position == nil, let name = leg.line?.name, let stored = snapshot?.trainPositions[name],
               !stored.isStale(after: Self.storedPositionLifetime, now: now) {
                position = stored
            }
        }
        var map: UIImage?
        if withMap, let position, let leg = state.ridingLeg(of: journey) {
            map = await Self.mapImage(at: position.coordinate, leg: leg, color: state.product.color, size: mapSize)
        }
        return LiveTrainEntry(date: now, state: state, journeyID: journey.id, position: position, map: map)
    }

    /// A map around the train with its route and a dot where it is. Widgets can't show a live `Map`.
    private static func mapImage(at coordinate: Coordinate, leg: Leg, color: Color, size: CGSize) async -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: 15_000,
                                            longitudinalMeters: 15_000 * size.width / size.height)
        options.pointOfInterestFilter = .excludingAll
        let route = leg.geometry ?? leg.stopovers.compactMap(\.station.coordinate)
        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start(with: .main) { snapshot, _ in
                continuation.resume(returning: snapshot.map { draw($0, center: center, route: route, color: color, size: size) })
            }
        }
    }

    private nonisolated static func draw(_ snapshot: MKMapSnapshotter.Snapshot, center: CLLocationCoordinate2D,
                                         route: [Coordinate], color: Color, size: CGSize) -> UIImage {
        let path = route.map { snapshot.point(for: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        let tint = UIColor(color)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            snapshot.image.draw(at: .zero)
            if let first = path.first {
                let line = UIBezierPath()
                line.move(to: first)
                for point in path.dropFirst() { line.addLine(to: point) }
                line.lineWidth = 3
                line.lineCapStyle = .round
                line.lineJoinStyle = .round
                tint.withAlphaComponent(0.6).setStroke()
                line.stroke()
            }
            let point = snapshot.point(for: center)
            let dot = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3)).fill()
            tint.setFill()
            UIBezierPath(ovalIn: dot).fill()
        }
    }
}

// MARK: Live speed

struct LiveSpeedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.liveSpeedWidgetKind, provider: LiveTrainProvider(withMap: false)) { entry in
            LiveSpeedView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.mapLink)
        }
        .configurationDisplayName("Live-Geschwindigkeit")
        .description("Wie schnell dein Zug gerade fährt. Ohne Live-Daten: nächster Halt mit Timer und Verspätung.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LiveSpeedView: View {
    let entry: LiveTrainEntry
    @Environment(\.widgetFamily) private var family

    private var speed: Int? { entry.position?.speedKmh.map { Int($0.rounded()) } }

    var body: some View {
        if let state = entry.state, state.phase != .arrived {
            switch family {
            case .accessoryCircular: circular(state)
            case .accessoryRectangular: rectangular(state)
            case .accessoryInline: inline(state)
            default: small(state)
            }
        } else {
            switch family {
            case .accessoryCircular, .accessoryInline:
                Image(systemName: "tram.fill")
            default:
                VStack(spacing: 4) {
                    Image(systemName: "tram.fill").foregroundStyle(.secondary)
                    Text(entry.state == nil ? "Keine Reise geplant" : "Angekommen").font(.caption.weight(.semibold))
                }
            }
        }
    }

    private func small(_ state: JourneyWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TrainBadge(name: state.trainName, product: state.product, nightTrain: state.isNightTrain)
                Spacer(minLength: 0)
                RefreshButton()
            }
            Spacer(minLength: 0)
            if let speed {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(speed)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("km/h").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                NextStopLine(state: state)
                PositionTime(position: entry.position)
            } else {
                NextStopFallback(state: state, date: entry.date)
            }
        }
    }

    @ViewBuilder
    private func circular(_ state: JourneyWidgetState) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            if let speed {
                VStack(spacing: -2) {
                    Text("\(speed)").font(.title3.weight(.bold)).monospacedDigit().minimumScaleFactor(0.6)
                    Text("km/h").font(.caption2)
                }
            } else {
                VStack(spacing: -2) {
                    Text("+\(max(0, state.nextStopDelayMinutes ?? 0))").font(.title3.weight(.bold)).monospacedDigit()
                    Text(timerInterval: entry.date...max(entry.date, state.nextStopTime), countsDown: true)
                        .font(.caption2).monospacedDigit().multilineTextAlignment(.center).minimumScaleFactor(0.5)
                }
            }
        }
    }

    private func rectangular(_ state: JourneyWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(state.trainName).font(.headline)
                if let speed { Text("· \(speed) km/h").font(.headline).monospacedDigit() }
            }
            .lineLimit(1)
            Text(state.nextStopName).font(.caption).lineLimit(1)
            HStack(spacing: 4) {
                Text(timerInterval: entry.date...max(entry.date, state.nextStopTime), countsDown: true).monospacedDigit()
                if let delay = state.nextStopDelayMinutes { Text("+\(max(0, delay))").monospacedDigit() }
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ state: JourneyWidgetState) -> some View {
        if let speed {
            Text("\(state.trainName) · \(speed) km/h")
        } else {
            Text("\(state.trainName) · \(state.nextStopName) +\(max(0, state.nextStopDelayMinutes ?? 0))")
        }
    }
}

// MARK: Live position

struct LivePositionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.livePositionWidgetKind, provider: LiveTrainProvider(withMap: true)) { entry in
            LivePositionView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.mapLink)
        }
        .configurationDisplayName("Live-Position")
        .description("Kleine Karte mit der Position deines Zugs und seiner Geschwindigkeit.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct LivePositionView: View {
    let entry: LiveTrainEntry

    var body: some View {
        if let state = entry.state, state.phase != .arrived {
            if let map = entry.map {
                ZStack {
                    Image(uiImage: map).resizable().scaledToFill()
                    VStack(alignment: .leading) {
                        HStack(alignment: .top) {
                            TrainBadge(name: state.trainName, product: state.product, nightTrain: state.isNightTrain)
                            Spacer(minLength: 0)
                            if let speed = entry.position?.speedKmh {
                                Text("\(Int(speed.rounded())) km/h")
                                    .font(.caption.weight(.bold)).monospacedDigit()
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.regularMaterial, in: .capsule)
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 1) {
                                NextStopLine(state: state)
                                PositionTime(position: entry.position)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.regularMaterial, in: .rect(cornerRadius: 8))
                            Spacer(minLength: 0)
                            RefreshButton()
                                .padding(5)
                                .background(.regularMaterial, in: .circle)
                        }
                    }
                    .padding(10)
                }
            } else {
                // No position (or no map): the same as the speed widget without live data.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        TrainBadge(name: state.trainName, product: state.product, nightTrain: state.isNightTrain)
                        Spacer(minLength: 0)
                        RefreshButton()
                    }
                    Spacer(minLength: 0)
                    NextStopFallback(state: state, date: entry.date)
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "map").foregroundStyle(.secondary)
                Text(entry.state == nil ? "Keine Reise geplant" : "Angekommen").font(.caption.weight(.semibold))
            }
        }
    }
}

// MARK: Pieces

private struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshLiveWidgetIntent()) {
            Image(systemName: "arrow.clockwise").font(.caption2.weight(.bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Aktualisieren")
    }
}

/// "Köln Hbf 12:31 +3": the train's next stop.
private struct NextStopLine: View {
    let state: JourneyWidgetState

    var body: some View {
        HStack(spacing: 4) {
            Text(state.nextStopName).font(.caption.weight(.semibold)).lineLimit(1)
            Text(state.nextStopTime, style: .time).font(.caption2).monospacedDigit()
            DelayBadge(minutes: state.nextStopDelayMinutes, cancelled: state.cancelled)
        }
    }
}

/// When the position was fetched.
private struct PositionTime: View {
    let position: TrainPosition?

    var body: some View {
        if let position {
            Text("Stand \(position.time.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Without live data: the next stop with a timer and its delay.
private struct NextStopFallback: View {
    let state: JourneyWidgetState
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.isWaitingToBoard ? "Abfahrt" : "Nächster Halt").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(state.nextStopName).font(.subheadline.weight(.bold)).lineLimit(2).minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text(timerInterval: date...max(date, state.nextStopTime), countsDown: true).monospacedDigit()
                Spacer(minLength: 0)
                DelayBadge(minutes: state.nextStopDelayMinutes, cancelled: state.cancelled)
            }
            .font(.caption.weight(.bold))
        }
    }
}

#Preview(as: .systemSmall) {
    LiveSpeedWidget()
} timeline: {
    LiveTrainEntry(date: .now, state: .preview, journeyID: nil,
                   position: TrainPosition(coordinate: Coordinate(latitude: 50.94, longitude: 6.96), time: .now,
                                           speedKmh: 243, source: nil),
                   map: nil)
    LiveTrainEntry(date: .now, state: .preview, journeyID: nil, position: nil, map: nil)
}
