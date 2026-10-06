import AppIntents
import BetterBahnKit
import SwiftUI
import WidgetKit

/// What the journey widget's timer counts down to, picked in the widget's settings.
enum WidgetCountdown: String, AppEnum {
    case nextConnection
    case destination

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Timer" }
    static var caseDisplayRepresentations: [WidgetCountdown: DisplayRepresentation] {
        [.nextConnection: "Bis zum nächsten Zug", .destination: "Bis zum Ziel"]
    }

    var target: JourneyWidgetState.CountdownTarget {
        switch self {
        case .nextConnection: .nextConnection
        case .destination: .destination
        }
    }
}

struct JourneyWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Reiseübersicht" }
    static var description: IntentDescription { "Zeigt deine aktuelle oder nächste gespeicherte Reise." }

    @Parameter(title: "Timer", default: .nextConnection)
    var countdown: WidgetCountdown

    init() {}
}

struct JourneyWidgetEntry: TimelineEntry {
    let date: Date
    let state: JourneyWidgetState?
    let journeyID: String?
    /// When the app last stored the journey (its live data is as of then).
    let updatedAt: Date?
    let countdown: JourneyWidgetState.CountdownTarget
}

struct JourneyWidgetProvider: AppIntentTimelineProvider {
    /// More entries than this aren't needed: the app reloads the widget whenever the journey changes.
    private static let maxEntries = 60

    func placeholder(in context: Context) -> JourneyWidgetEntry {
        JourneyWidgetEntry(date: .now, state: .preview, journeyID: nil, updatedAt: .now, countdown: .nextConnection)
    }

    func snapshot(for configuration: JourneyWidgetIntent, in context: Context) async -> JourneyWidgetEntry {
        let entries = Self.entries(countdown: configuration.countdown.target, now: .now)
        if context.isPreview, entries.first?.state == nil {
            return placeholder(in: context)
        }
        return entries[0]
    }

    func timeline(for configuration: JourneyWidgetIntent, in context: Context) async -> Timeline<JourneyWidgetEntry> {
        Timeline(entries: Self.entries(countdown: configuration.countdown.target, now: .now), policy: .atEnd)
    }

    /// One entry now and one at every moment the journey's state changes (departures, arrivals,
    /// stops, transfers), so the widget moves on by itself.
    /// Also used by the current-train widget.
    static func entries(countdown: JourneyWidgetState.CountdownTarget, now: Date) -> [JourneyWidgetEntry] {
        let snapshot = WidgetStore.load()
        guard let journey = snapshot?.journey else {
            return [JourneyWidgetEntry(date: now, state: nil, journeyID: nil, updatedAt: snapshot?.updatedAt, countdown: countdown)]
        }
        let dates = [now] + JourneyWidgetState.changeDates(of: journey, after: now).prefix(Self.maxEntries - 1)
        return dates.map { date in
            JourneyWidgetEntry(date: date, state: JourneyWidgetState.from(journey, now: date), journeyID: journey.id,
                               updatedAt: snapshot?.updatedAt, countdown: countdown)
        }
    }
}

struct JourneyOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStore.journeyWidgetKind, intent: JourneyWidgetIntent.self,
                               provider: JourneyWidgetProvider()) { entry in
            JourneyWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.journeyID.map { LiveActivityLink.url(journeyID: $0) })
        }
        .configurationDisplayName("Reiseübersicht")
        .description("Verspätungen, nächster Halt, Umstieg und ein Timer bis zum nächsten Zug oder zum Ziel.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct JourneyWidgetView: View {
    let entry: JourneyWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state {
            switch family {
            case .systemMedium: medium(state)
            default: small(state)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "tram.fill").font(.title2).foregroundStyle(.secondary)
                Text("Keine Reise geplant").font(.subheadline.weight(.semibold))
                Text("Speichere eine Verbindung, um sie hier zu sehen.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Layouts

    private func small(_ state: JourneyWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TrainBadge(name: state.phase == .transfer ? state.transfer?.toTrain ?? state.trainName : state.trainName,
                           product: state.transfer?.toProduct ?? state.product)
                Spacer(minLength: 0)
                DelayBadge(minutes: state.nextStopDelayMinutes, cancelled: state.cancelled)
            }
            Spacer(minLength: 0)
            if let transfer = state.transfer {
                TransferLines(transfer: transfer)
            } else {
                Text(heading(state)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(state.nextStopName).font(.subheadline.weight(.bold)).lineLimit(2).minimumScaleFactor(0.8)
                timeAndPlatform(state)
            }
            Spacer(minLength: 0)
            countdown(state)
        }
    }

    private func medium(_ state: JourneyWidgetState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TrainBadge(name: state.trainName, product: state.product)
                    DelayBadge(minutes: state.nextStopDelayMinutes, cancelled: state.cancelled)
                }
                Spacer(minLength: 0)
                if let transfer = state.transfer {
                    TransferLines(transfer: transfer)
                } else {
                    Text(heading(state)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(state.nextStopName).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                    timeAndPlatform(state)
                }
                Spacer(minLength: 0)
                countdown(state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.phase == .beforeDeparture ? "Nächste Reise" : "Ziel")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(state.destinationName).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    Text(state.finalArrival, style: .time).font(.subheadline.weight(.bold)).monospacedDigit()
                    DelayBadge(minutes: state.finalDelayMinutes, cancelled: false)
                }
                if state.phase == .beforeDeparture {
                    Text("ab \(state.originName)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let warning = state.warning, state.phase != .arrived {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(heavyDelayColor).lineLimit(2)
                } else if let updatedAt = entry.updatedAt {
                    Text("Stand \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Pieces

    private func heading(_ state: JourneyWidgetState) -> String {
        switch state.phase {
        case .beforeDeparture: Calendar.current.isDateInToday(state.nextStopTime) ? "Abfahrt" : "Abfahrt \(state.nextStopTime.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        case .riding, .transfer: "Nächster Halt"
        case .arrived: "Angekommen"
        }
    }

    private func timeAndPlatform(_ state: JourneyWidgetState) -> some View {
        HStack(spacing: 6) {
            Text(state.nextStopTime, style: .time).font(.caption.weight(.semibold)).monospacedDigit()
            if let platform = state.platform, state.phase == .beforeDeparture {
                Text("Gl. \(platform)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func countdown(_ state: JourneyWidgetState) -> some View {
        let end = state.countdownEnd(entry.countdown)
        if state.phase == .arrived || end <= entry.date {
            Label("Angekommen", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.green)
        } else {
            HStack(spacing: 4) {
                Image(systemName: state.countsToDeparture(entry.countdown) ? "arrow.up.right.circle.fill" : "flag.checkered")
                // The range starts at the entry's fixed date, not `.now` (see `countdownRange` in TripLiveActivity).
                Text(timerInterval: entry.date...end, countsDown: true)
                    .monospacedDigit()
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.primary)
        }
    }
}

/// The train's product color with its short name ("RE 5", "ICE 645").
struct TrainBadge: View {
    let name: String
    let product: Product

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: product.symbolName)
            Text(name).lineLimit(1)
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(product.color.gradient, in: .capsule)
        .fixedSize()
    }
}

/// "+5" in the delay color, "Fällt aus" when cancelled, nothing without live data.
struct DelayBadge: View {
    let minutes: Int?
    let cancelled: Bool

    var body: some View {
        if cancelled {
            Text("Fällt aus").font(.caption2.weight(.bold)).foregroundStyle(heavyDelayColor)
        } else if let minutes {
            Text("+\(max(0, minutes))").font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(delayColor(max(0, minutes)))
        }
    }
}

/// "RE 5 → ICE 645" over "Gl. 4 → Gl. 7" at a transfer.
struct TransferLines: View {
    let transfer: JourneyWidgetState.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Umstieg \(transfer.station)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text("\(transfer.fromTrain) → \(transfer.toTrain)").font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text("Gl. \(transfer.fromPlatform ?? "?") → Gl. \(transfer.toPlatform ?? "?")")
                .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text(transfer.departure, style: .time).font(.caption2.weight(.semibold)).monospacedDigit()
                DelayBadge(minutes: transfer.departureDelayMinutes, cancelled: false)
            }
        }
    }
}

extension JourneyWidgetState {
    /// Shown in the widget gallery.
    nonisolated static var preview: JourneyWidgetState? {
        let now = Date.now
        func station(_ name: String) -> Station { Station(id: name, name: name, coordinate: nil, evaNumber: nil, source: .bahnDe) }
        let leg = Leg(origin: station("Köln Hbf"), destination: station("Berlin Hbf"),
                      departure: TimeInfo(planned: now.addingTimeInterval(12 * 60), actual: now.addingTimeInterval(15 * 60)),
                      arrival: TimeInfo(planned: now.addingTimeInterval(4 * 3600), actual: now.addingTimeInterval(4 * 3600 + 5 * 60)),
                      departurePlatform: PlatformInfo(planned: "5", actual: nil), arrivalPlatform: nil, tripId: "preview",
                      line: Line(name: "ICE 645", number: "645", product: .highSpeed, operatorName: nil),
                      direction: "Berlin Hbf", isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
        return from(Journey(legs: [leg], source: .bahnDe), now: now)
    }
}

#Preview(as: .systemMedium) {
    JourneyOverviewWidget()
} timeline: {
    JourneyWidgetEntry(date: .now, state: .preview, journeyID: nil, updatedAt: .now, countdown: .nextConnection)
    JourneyWidgetEntry(date: .now, state: nil, journeyID: nil, updatedAt: nil, countdown: .nextConnection)
}
