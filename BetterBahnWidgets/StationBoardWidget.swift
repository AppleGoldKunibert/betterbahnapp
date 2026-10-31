import AppIntents
import BetterBahnKit
import SwiftUI
import WidgetKit

// MARK: Settings

/// A station the departure board widget can show (#314): one of the favourites, or any station the
/// widget was set to before. The entity's ID is the station itself (`BoardWidgetLink.encode`), so a
/// widget keeps working after its station left the favourites.
struct StationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Bahnhof" }
    static var defaultQuery: StationQuery { StationQuery() }

    let station: Station

    var id: String { BoardWidgetLink.encode(station) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(station.displayName)", subtitle: station.region.map { LocalizedStringResource("\($0)") })
    }
}

struct StationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        identifiers.compactMap(BoardWidgetLink.decode).map(StationEntity.init)
    }

    /// The favourites, as kept in the Abfahrten tab.
    func suggestedEntities() async throws -> [StationEntity] {
        (WidgetStations.load()?.favorites ?? []).map(StationEntity.init)
    }

    func defaultResult() async -> StationEntity? {
        try? await suggestedEntities().first
    }
}

/// The destination of a commuter route: only connections there are shown then.
struct RouteDestinationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Ziel" }
    static var defaultQuery: RouteDestinationQuery { RouteDestinationQuery() }

    let station: Station

    var id: String { BoardWidgetLink.encode(station) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(station.displayName)", subtitle: station.region.map { LocalizedStringResource("\($0)") })
    }
}

struct RouteDestinationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RouteDestinationEntity] {
        identifiers.compactMap(BoardWidgetLink.decode).map(RouteDestinationEntity.init)
    }

    /// The favourites and the ends of the routes searched last.
    func suggestedEntities() async throws -> [RouteDestinationEntity] {
        (WidgetStations.load()?.destinations ?? []).map(RouteDestinationEntity.init)
    }
}

/// Which trains the widget lists, like the board's filter.
enum BoardWidgetProducts: String, AppEnum {
    case all
    case trains
    case longDistance
    case regional
    case regionalAndSuburban

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Verkehrsmittel" }
    static var caseDisplayRepresentations: [BoardWidgetProducts: DisplayRepresentation] {
        [.all: "Alle", .trains: "Nur Züge", .longDistance: "Nur Fernverkehr",
         .regional: "Nur Regionalverkehr", .regionalAndSuburban: "Regionalverkehr und S-Bahn"]
    }

    var products: Set<Product> {
        switch self {
        case .all: Set(Product.allCases)
        case .trains: Set(Product.allCases.filter(\.isTrain))
        case .longDistance: Product.longDistanceProducts
        case .regional: Product.regionalProducts
        case .regionalAndSuburban: Product.regionalProducts.union([.suburban])
        }
    }
}

struct StationBoardWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Abfahrten" }
    static var description: IntentDescription { "Die nächsten Abfahrten an einem Bahnhof, auf Wunsch nur zu einem Ziel." }

    @Parameter(title: "Bahnhof")
    var station: StationEntity?

    /// The widget editor can't clear a station once picked, so the route is switched off with this.
    @Parameter(title: "Nur zu einem Ziel", default: false)
    var onlyToDestination: Bool

    @Parameter(title: "Ziel", description: "Nur Verbindungen zu diesem Bahnhof, z. B. zur Arbeit.")
    var destination: RouteDestinationEntity?

    @Parameter(title: "Verkehrsmittel", default: .all)
    var products: BoardWidgetProducts

    static var parameterSummary: some ParameterSummary {
        When(\.$onlyToDestination, .equalTo, true) {
            Summary {
                \.$station
                \.$onlyToDestination
                \.$destination
                \.$products
            }
        } otherwise: {
            Summary {
                \.$station
                \.$onlyToDestination
                \.$products
            }
        }
    }

    /// The route's destination, when the route is on and one is picked.
    var routeDestination: Station? {
        onlyToDestination ? destination?.station : nil
    }

    init() {}
}

// MARK: Timeline

struct StationBoardEntry: TimelineEntry {
    let date: Date
    let station: Station?
    let destination: Station?
    /// Every row fetched; the view shows the ones still ahead at `date` (`BoardWidgetRows.visible`).
    let rows: [BoardWidgetRow]
    /// When the rows were fetched, shown as "Stand hh:mm".
    let updatedAt: Date?
    /// The fetch failed (no network, Transitous down): the widget says so instead of showing nothing.
    let failed: Bool

    var isRoute: Bool { destination != nil }

    var link: URL? { station.map { BoardWidgetLink.url(station: $0, destination: destination) } }

    /// The same data at a later moment.
    func at(_ date: Date) -> StationBoardEntry {
        StationBoardEntry(date: date, station: station, destination: destination, rows: rows, updatedAt: updatedAt, failed: failed)
    }

    static func empty(at date: Date) -> StationBoardEntry {
        StationBoardEntry(date: date, station: nil, destination: nil, rows: [], updatedAt: nil, failed: false)
    }

    /// Shown in the widget gallery.
    static func preview(at date: Date) -> StationBoardEntry {
        func row(_ line: String, _ product: Product, to: String, minutes: Double, delay: Double? = nil, platform: String) -> BoardWidgetRow {
            let planned = date.addingTimeInterval(minutes * 60)
            return BoardWidgetRow(id: line + to, departure: TimeInfo(planned: planned, actual: delay.map { planned.addingTimeInterval($0 * 60) }),
                                  cancelled: false, lineName: line, product: product, isNightTrain: false, destination: to, platform: platform)
        }
        let berlin = Station(id: "preview", name: "Berlin Hbf", coordinate: nil, evaNumber: "8011160", source: .transitous)
        return StationBoardEntry(date: date, station: berlin, destination: nil, rows: [
            row("ICE 1000", .highSpeed, to: "Hamburg Hbf", minutes: 4, delay: 0, platform: "8"),
            row("RE 1", .regionalExpress, to: "Magdeburg Hbf", minutes: 9, delay: 3, platform: "14"),
            row("S 5", .suburban, to: "Strausberg Nord", minutes: 12, delay: 0, platform: "16"),
            row("ICE 701", .highSpeed, to: "München Hbf", minutes: 17, platform: "7"),
            row("RE 7", .regionalExpress, to: "Dessau Hbf", minutes: 23, delay: 11, platform: "12"),
            row("RB 24", .regional, to: "Eberswalde Hbf", minutes: 31, platform: "11"),
            row("IC 2431", .longDistance, to: "Köln Hbf", minutes: 38, delay: 0, platform: "6"),
            row("S 3", .suburban, to: "Erkner", minutes: 42, platform: "15"),
            row("RE 2", .regionalExpress, to: "Cottbus Hbf", minutes: 55, platform: "13"),
        ], updatedAt: date, failed: false)
    }
}

/// Fetches the board (or the route's connections) from Transitous itself: the app can't refresh it in
/// the background. WidgetKit allows a few reloads an hour, so the rows show their times with the last
/// known delays and when they were fetched, and trains that have left drop off by the timeline alone.
struct StationBoardProvider: AppIntentTimelineProvider {
    /// How far ahead the board is asked for.
    private static let boardMinutes = 120
    private static let maxEntries = 40

    func placeholder(in context: Context) -> StationBoardEntry {
        .preview(at: .now)
    }

    func snapshot(for configuration: StationBoardWidgetIntent, in context: Context) async -> StationBoardEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return await Self.load(configuration, now: .now)
    }

    func timeline(for configuration: StationBoardWidgetIntent, in context: Context) async -> Timeline<StationBoardEntry> {
        let now = Date.now
        let first = await Self.load(configuration, now: now)
        let reload = now.addingTimeInterval(first.failed ? 10 * 60 : first.rows.isEmpty ? 30 * 60 : 20 * 60)
        var entries = [first]
        for date in BoardWidgetRows.changeDates(of: first.rows, after: now, until: reload).prefix(Self.maxEntries - 1) {
            entries.append(first.at(date))
        }
        return Timeline(entries: entries, policy: .after(reload))
    }

    static func load(_ configuration: StationBoardWidgetIntent, now: Date) async -> StationBoardEntry {
        guard let station = configuration.station?.station else { return .empty(at: now) }
        let destination = configuration.routeDestination
        let products = configuration.products.products
        let provider = TransitousProvider()
        do {
            let rows: [BoardWidgetRow]
            if let destination {
                let query = JourneyQuery(from: station, to: destination, date: now, products: products)
                let page = try await provider.journeys(query)
                rows = BoardWidgetRows.rows(journeys: page.journeys.filter(query.allows), destination: destination, now: now)
            } else {
                let entries = try await provider.board(.departures, at: station, date: now.addingTimeInterval(-BoardWidgetRows.grace),
                                                       duration: boardMinutes, products: products)
                rows = BoardWidgetRows.rows(board: entries, products: products, now: now)
            }
            return StationBoardEntry(date: now, station: station, destination: destination, rows: rows, updatedAt: now, failed: false)
        } catch {
            return StationBoardEntry(date: now, station: station, destination: destination, rows: [], updatedAt: nil, failed: true)
        }
    }
}

// MARK: Widget

/// The next departures from a station picked in the widget's settings, or the next connections of a
/// commuter route (#314). Tapping opens the station's board, or the route in the connection search.
struct StationBoardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStore.boardWidgetKind, intent: StationBoardWidgetIntent.self,
                               provider: StationBoardProvider()) { entry in
            BoardWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.link)
        }
        .configurationDisplayName("Abfahrten")
        .description("Die nächsten Züge an deinem Bahnhof oder auf deiner Strecke.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct BoardWidgetView: View {
    let entry: StationBoardEntry
    @Environment(\.widgetFamily) private var family

    /// Rows the family has room for; the Home Screen families try the first count and fall back to fewer
    /// (`ViewThatFits`), since the widget's height differs between devices.
    private var rowLimits: [Int] {
        switch family {
        case .systemSmall: [3, 2]
        case .systemLarge: [10, 9, 8, 7]
        case .accessoryRectangular: [2]
        case .accessoryInline: [1]
        default: [4, 3]
        }
    }

    private var rows: [BoardWidgetRow] { BoardWidgetRows.visible(entry.rows, at: entry.date, limit: rowLimits[0]) }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        default: home
        }
    }

    // MARK: Home Screen

    @ViewBuilder
    private var home: some View {
        if let station = entry.station {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
                BoardHeader(station: station, destination: entry.destination, compact: family == .systemSmall)
                if rows.isEmpty {
                    Spacer(minLength: 0)
                    emptyMessage
                    Spacer(minLength: 0)
                } else {
                    ViewThatFits(in: .vertical) {
                        ForEach(rowLimits, id: \.self) { limit in
                            rowList(Array(rows.prefix(limit)))
                        }
                    }
                    Spacer(minLength: 0)
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "building.2.fill").font(.title2).foregroundStyle(.secondary)
                Text("Bahnhof wählen").font(.subheadline.weight(.semibold))
                Text("Widget gedrückt halten und bearbeiten.").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func rowList(_ rows: [BoardWidgetRow]) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            ForEach(rows) { row in
                if family == .systemSmall {
                    SmallBoardRow(row: row, isRoute: entry.isRoute)
                } else {
                    WideBoardRow(row: row, isRoute: entry.isRoute)
                }
            }
        }
    }

    private var emptyMessage: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.failed ? "Keine Daten" : entry.isRoute ? "Keine Verbindung" : "Keine Abfahrten")
                .font(.subheadline.weight(.semibold))
            Text(entry.failed ? "Gerade nicht erreichbar." : entry.isRoute ? "Demnächst fährt hier nichts hin." : "In den nächsten 2 Stunden fährt hier nichts.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 4) {
            if let updatedAt = entry.updatedAt {
                Text("Stand \(updatedAt.formatted(date: .omitted, time: .shortened))")
            }
            Spacer(minLength: 0)
            RefreshButton()
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let station = entry.station {
                HStack(spacing: 3) {
                    Image(systemName: entry.isRoute ? "arrow.triangle.swap" : "building.2.fill")
                    Text(entry.destination?.displayName ?? station.displayName)
                }
                .font(.caption.weight(.semibold)).lineLimit(1)
                .widgetAccentable()
                if rows.isEmpty {
                    Text(entry.failed ? "Keine Daten" : entry.isRoute ? "Keine Verbindung" : "Keine Abfahrten").font(.caption)
                } else {
                    ForEach(rows) { row in
                        HStack(spacing: 4) {
                            Text(row.departure.planned, style: .time).monospacedDigit().strikethrough(row.cancelled)
                            Text(row.lineName).lineLimit(1).fixedSize()
                            Text(entry.isRoute ? row.arrival.map { String(localized: "an \($0.best.formatted(date: .omitted, time: .shortened))") } ?? "" : row.destination)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            DelayBadge(minutes: row.delayMinutes, cancelled: row.cancelled)
                        }
                        .font(.caption)
                    }
                }
            } else {
                Text("Bahnhof wählen").font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inline: some View {
        if entry.station == nil {
            Text("Bahnhof wählen")
        } else if let row = rows.first {
            let delay = row.cancelled ? " " + String(localized: "Ausfall") : row.delayMinutes.map { $0 > 0 ? " +\($0)" : "" } ?? ""
            Text("\(row.departure.planned.formatted(date: .omitted, time: .shortened)) \(row.lineName) → \(row.destination)\(delay)")
        } else {
            Text(entry.failed ? "Keine Daten" : entry.isRoute ? "Keine Verbindung" : "Keine Abfahrten")
        }
    }
}

// MARK: Pieces

/// "Berlin Hbf", or "Berlin Hbf → Potsdam Hbf" for a route.
private struct BoardHeader: View {
    let station: Station
    let destination: Station?
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: destination == nil ? "building.2.fill" : "arrow.triangle.swap")
                .font(.caption2.weight(.bold))
            Text(station.displayName)
                .lineLimit(1)
            if let destination {
                Image(systemName: "arrow.right").font(.caption2.weight(.bold))
                Text(destination.displayName).lineLimit(1)
            }
        }
        .font(compact ? .caption.weight(.bold) : .subheadline.weight(.bold))
        .minimumScaleFactor(0.8)
        // Tinted and clear Home Screens draw everything in one colour: the station gets the accent.
        .widgetAccentable()
    }
}

/// One row on the medium and large widget: time with delay, line, destination (or arrival and changes
/// for a route), platform.
private struct WideBoardRow: View {
    let row: BoardWidgetRow
    let isRoute: Bool

    var body: some View {
        HStack(spacing: 6) {
            // One column for time and delay, so the lines up the rows align whether or not there is a delay.
            HStack(spacing: 4) {
                Text(row.departure.planned, style: .time)
                    .font(.subheadline.weight(.bold)).monospacedDigit()
                    .strikethrough(row.cancelled)
                    .foregroundStyle(row.cancelled ? .secondary : .primary)
                DelayBadge(minutes: row.delayMinutes, cancelled: row.cancelled)
            }
            .frame(width: 92, alignment: .leading)
            TrainBadge(name: row.lineName, product: row.product, nightTrain: row.isNightTrain)
            if isRoute, let arrival = row.arrival {
                HStack(spacing: 4) {
                    Text("an \(arrival.best.formatted(date: .omitted, time: .shortened))").monospacedDigit().fixedSize()
                    Text(Self.transfersText(row.transfers)).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.caption.weight(.semibold))
            } else {
                Text(row.destination).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 2)
            if let platform = row.platform {
                Text("Gl. \(platform)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
        }
    }

    static func transfersText(_ transfers: Int?) -> String {
        switch transfers ?? 0 {
        case 0: String(localized: "direkt")
        case 1: String(localized: "1 Umstieg")
        case let count: String(localized: "\(count) Umstiege")
        }
    }
}

/// One row on the small widget: time, delay and line above the destination.
private struct SmallBoardRow: View {
    let row: BoardWidgetRow
    let isRoute: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(row.departure.planned, style: .time)
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .strikethrough(row.cancelled)
                    .foregroundStyle(row.cancelled ? .secondary : .primary)
                DelayBadge(minutes: row.delayMinutes, cancelled: row.cancelled)
                Spacer(minLength: 0)
                TrainBadge(name: row.lineName, product: row.product, nightTrain: row.isNightTrain)
            }
            HStack(spacing: 4) {
                if isRoute, let arrival = row.arrival {
                    Text("an \(arrival.best.formatted(date: .omitted, time: .shortened)) · \(WideBoardRow.transfersText(row.transfers))")
                } else {
                    Text(row.destination)
                }
                Spacer(minLength: 0)
                if let platform = row.platform {
                    Text("Gl. \(platform)").monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

#Preview(as: .systemMedium) {
    StationBoardWidget()
} timeline: {
    StationBoardEntry.preview(at: .now)
    StationBoardEntry.empty(at: .now)
}
