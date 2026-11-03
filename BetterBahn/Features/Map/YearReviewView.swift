import BetterBahnKit
import SwiftUI

/// The year in review ("Jahresrückblick", #319): one fact per card, swiped through like a story,
/// each card shareable as an image. Opened only from the banner on the Verbindungen tab (December and
/// January); other years are picked in the view. Everything is computed on the device.
struct YearReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @Environment(\.colorScheme) private var colorScheme
    @State var year: Int
    @State private var years: [Int] = []
    @State private var review: YearReview?
    @State private var runs: [SegmentHeatmap.Run] = []
    @State private var progress: (done: Int, total: Int)?
    @State private var page: YearReviewCard = .intro
    @State private var shareImage: Image?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background((isTicket ? Color.canvas : Color.black).ignoresSafeArea())
                .navigationTitle("Jahresrückblick")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(isTicket ? nil : .dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) { yearMenu }
                    ToolbarItem(placement: .confirmationAction) {
                        if let shareImage {
                            ShareLink(item: shareImage,
                                      preview: SharePreview("Mein Bahnjahr \(String(year))", image: shareImage)) {
                                Label("Teilen", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
        }
        // The stories glow on black; the tickets lie on the page like the rest of the app.
        .preferredColorScheme(isTicket ? nil : .dark)
        .task { await loadYears() }
        .task(id: year) { await load() }
        .task(id: "\(page)|\(review?.year ?? 0)|\(design)|\(colorScheme)") { renderShareImage() }
    }

    /// Fahrkarte draws each card as a ticket on the page; Minimal as a colored story on black.
    private var isTicket: Bool { design == .fahrkarte }

    @ViewBuilder private var content: some View {
        if let review, review.year == year {
            if review.isEmpty {
                ContentUnavailableView("Keine Fahrten \(String(year))", systemImage: "tram",
                                       description: Text("Gespeicherte Reisen und Träwelling-Check-ins aus diesem Jahr erscheinen hier."))
            } else {
                TabView(selection: $page) {
                    ForEach(YearReviewCard.cards(for: review, hasMap: !runs.isEmpty), id: \.self) { card in
                        ScaledCard { YearReviewCardView(card: card, review: review, runs: runs) }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 44)
                            .tag(card)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                // The white dots need a backing on the light page.
                .indexViewStyle(.page(backgroundDisplayMode: isTicket ? .always : .automatic))
            }
        } else {
            VStack(spacing: 12) {
                if let progress, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(.brandText)
                        .frame(maxWidth: 220)
                    Text("Strecken \(progress.done)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
    }

    private var yearMenu: some View {
        Menu {
            Picker("Jahr", selection: $year) {
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(String(year)).font(.headline.monospacedDigit())
                if years.count > 1 { Image(systemName: "chevron.down").font(.caption.weight(.bold)) }
            }
            .foregroundStyle(isTicket ? Color.primary : Color.white)
        }
        .disabled(years.count < 2)
    }

    private func loadYears() async {
        let found = await model.yearReviewYears()
        years = found.contains(year) ? found : (found.isEmpty ? [year] : found)
        // Opened for a year without rides: show the latest one with rides.
        if !found.isEmpty, !found.contains(year) { year = found[0] }
    }

    private func load() async {
        review = nil
        runs = []
        progress = nil
        page = .intro
        guard let result = await model.yearReview(for: year, onProgress: { done, total in progress = (done, total) })
        else { return } // cancelled
        withAnimation {
            runs = result.runs
            review = result.review
        }
    }

    /// The visible card, drawn at the size of a phone story (1080 × 1920).
    private func renderShareImage() {
        guard let review, !review.isEmpty else { shareImage = nil; return }
        let renderer = ImageRenderer(content: YearReviewCardView(card: page, review: review, runs: runs)
            .frame(width: YearReviewCardView.size.width, height: YearReviewCardView.size.height)
            .environment(\.appDesign, design)
            .environment(\.colorScheme, isTicket ? colorScheme : .dark))
        renderer.scale = 3
        shareImage = renderer.uiImage.map { Image(uiImage: $0) }
    }
}

/// Lays a card out at its fixed size and scales it to fit, so it looks the same on screen and in the
/// shared image.
private struct ScaledCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let size = YearReviewCardView.size
            let scale = min(proxy.size.width / size.width, proxy.size.height / size.height)
            content
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: 28, style: .continuous))
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - Cards

enum YearReviewCard: Hashable {
    case intro, distance, co2, time, punctuality, series, stations, routes, longestRide, abroad, map, summary

    /// The cards there is something to say on.
    static func cards(for review: YearReview, hasMap: Bool) -> [YearReviewCard] {
        var cards: [YearReviewCard] = [.intro]
        if review.kilometers > 0 { cards.append(.distance) }
        if review.co2.savedComparedToCar >= 1 { cards.append(.co2) }
        cards.append(.time)
        if review.punctuality != nil { cards.append(.punctuality) }
        if !review.series.isEmpty { cards.append(.series) }
        cards.append(.stations)
        if !review.routes.isEmpty { cards.append(.routes) }
        if review.longestRide != nil { cards.append(.longestRide) }
        if review.nightTrains > 0 || review.countries.count > 1 { cards.append(.abroad) }
        if hasMap { cards.append(.map) }
        cards.append(.summary)
        return cards
    }
}

struct YearReviewCardView: View {
    let card: YearReviewCard
    let review: YearReview
    let runs: [SegmentHeatmap.Run]

    @Environment(\.appDesign) private var design

    static let size = CGSize(width: 360, height: 640)
    private static let earthKilometers = 40_075.0

    private var isTicket: Bool { design == .fahrkarte }

    var body: some View {
        if isTicket { ticket } else { story }
    }

    /// Minimal: a story card in shades of the accent color, white text.
    private var story: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("BetterBahn", systemImage: "tram.fill")
                    Spacer()
                    Text(String(review.year)).monospacedDigit()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(soft(0.8))
                Spacer(minLength: 16)
                content(for: card)
                Spacer(minLength: 16)
            }
            .padding(28)
        }
        .foregroundStyle(.white)
    }

    /// Fahrkarte: a ticket on the page, the app and year in its stub above the perforation.
    private var ticket: some View {
        ZStack {
            Color.canvas
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("BetterBahn", systemImage: "tram.fill")
                    Spacer()
                    Text(String(review.year)).monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                TicketPerforation()
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 8)
                    content(for: card)
                    Spacer(minLength: 8)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .fontDesign(.rounded)
            .foregroundStyle(.primary)
            .ticketBackground()
            .environment(\.cardSurface, Color.ticket)
            .padding(16)
        }
    }

    /// The story's gradients, all from the accent color (the CO₂ card in green for the saving), darkened
    /// where needed so the white text always reads, also on a pale accent.
    private var colors: [Color] {
        let accent = Theme.shared.accent.color.readable(on: RGBColor(red: 1, green: 1, blue: 1)).swiftUIColor
        let deep = accent.mix(with: .black, by: 0.4)
        switch card {
        case .intro, .summary: return [accent, deep]
        case .distance, .map, .series, .routes: return [deep, .black]
        case .time, .stations: return [accent.mix(with: .black, by: 0.2), deep.mix(with: .black, by: 0.5)]
        case .co2:
            let green = RGBColor(red: 0.13, green: 0.62, blue: 0.35).readable(on: RGBColor(red: 1, green: 1, blue: 1)).swiftUIColor
            return [green, green.mix(with: .black, by: 0.55)]
        case .punctuality, .longestRide, .abroad: return [accent.mix(with: .black, by: 0.1), deep.mix(with: .black, by: 0.2)]
        }
    }

    /// Secondary text: grey on the ticket, translucent white on the story.
    private func soft(_ opacity: Double) -> AnyShapeStyle {
        isTicket ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white.opacity(opacity))
    }

    @ViewBuilder private func content(for card: YearReviewCard) -> some View {
        switch card {
        case .intro:
            headline("Dein Bahnjahr \(String(review.year))")
            big(review.rides.formatted(), unit: review.rides == 1 ? String(localized: "Fahrt") : String(localized: "Fahrten"))
            caption(review.activeDays == 1 ? String(localized: "an \(review.activeDays) Tag unterwegs")
                    : String(localized: "an \(review.activeDays) Tagen unterwegs"))
        case .distance:
            headline("So weit bist du gefahren")
            big(kilometers(review.kilometers), unit: "km")
            caption(distanceComparison)
        case .co2:
            headline("So viel CO₂ gespart")
            big(kilometers(review.co2.savedComparedToCar), unit: "kg")
            caption(String(localized: "gegenüber denselben Strecken mit dem Auto."))
        case .time:
            headline("So lange warst du im Zug")
            big(review.hours.formatted(.number.precision(.fractionLength(0))), unit: String(localized: "Stunden"))
            caption(timeComparison)
        case .punctuality:
            headline("Pünktlich angekommen")
            big((review.punctuality ?? 0).formatted(.percent.precision(.fractionLength(0))), unit: nil)
            caption(String(localized: "\(review.delayMinutes.formatted()) Minuten Verspätung insgesamt"))
            if let late = review.mostDelayed {
                caption(String(localized: "Am längsten gewartet: \(late.name) mit +\(late.count) min"))
            }
        case .series:
            headline("Deine Lieblingszüge")
            list(review.series)
            if let trainset = review.trainsets.first {
                caption(String(localized: "Am öftesten im selben Zug: \(trainset.name), \(trainset.count)×"))
            }
        case .stations:
            headline("Deine Bahnhöfe")
            list(review.stations)
        case .routes:
            headline("Deine Strecken")
            list(review.routes)
            if let train = review.trains.first {
                caption(String(localized: "Am öftesten gefahren: \(train.name), \(train.count)×"))
            }
        case .longestRide:
            if let ride = review.longestRide {
                headline("Deine längste Fahrt")
                big(kilometers(ride.kilometers), unit: "km")
                VStack(alignment: .leading, spacing: 4) {
                    Text(ride.from)
                    Text("→ \(ride.to)")
                }
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)
                caption([ride.train, ride.date.formatted(.dateTime.day().month(.wide)),
                         String(localized: "\(ride.hours.formatted(.number.precision(.fractionLength(1)))) Std.")]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        case .abroad:
            if review.countries.count > 1 {
                headline("Unterwegs in")
                big("\(review.countries.count)", unit: String(localized: "Ländern"))
                caption(review.countries.joined(separator: ", "))
            } else {
                headline("Unterwegs bei Nacht")
            }
            if review.nightTrains > 0 {
                Label(review.nightTrains == 1 ? "\(review.nightTrains) Nachtzug" : "\(review.nightTrains) Nachtzüge", systemImage: "bed.double.fill")
                    .font(.title2.weight(.bold))
                    .padding(.top, 16)
            }
        case .map:
            headline("Deine Karte")
            YearReviewHeatmap(runs: runs)
                .frame(height: 420)
                .padding(.top, 12)
        case .summary:
            headline("Mein Bahnjahr \(String(review.year))")
            VStack(alignment: .leading, spacing: 14) {
                summaryRow(review.rides.formatted(), review.rides == 1 ? "Fahrt" : "Fahrten")
                if review.kilometers > 0 { summaryRow(kilometers(review.kilometers), "Kilometer") }
                summaryRow(review.hours.formatted(.number.precision(.fractionLength(0))), "Stunden im Zug")
                if let punctuality = review.punctuality {
                    summaryRow(punctuality.formatted(.percent.precision(.fractionLength(0))), "pünktlich")
                }
                if let series = review.series.first { summaryRow(series.name, "Lieblingszug") }
                if let station = review.stations.first { summaryRow(station.name, "Lieblingsbahnhof") }
            }
            .padding(.top, 16)
        }
    }

    // MARK: Pieces

    private func headline(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func big(_ value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                // The ticket's one splash of color.
                .foregroundStyle(isTicket ? Color.brandText : Color.white)
            if let unit { Text(unit).font(.title2.weight(.semibold)) }
        }
        .padding(.top, 12)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.body.weight(.medium))
            .foregroundStyle(soft(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    private func list(_ entries: [YearReview.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(isTicket ? AnyShapeStyle(Color.brandText) : soft(0.6))
                        .frame(width: 22, alignment: .leading)
                    Text(entry.name)
                        .font(index == 0 ? .title3.weight(.bold) : .body.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Text("\(entry.count)×")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(soft(0.8))
                }
            }
        }
        .padding(.top, 20)
    }

    private func summaryRow(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(soft(0.8))
        }
    }

    private func kilometers(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private var distanceComparison: String {
        let laps = review.kilometers / Self.earthKilometers
        if laps >= 1 {
            return String(localized: "Das ist \(laps.formatted(.number.precision(.fractionLength(1))))-mal um die Erde.")
        }
        return String(localized: "Das sind \(laps.formatted(.percent.precision(.fractionLength(0)))) einer Reise um die Erde.")
    }

    private var timeComparison: String {
        let days = review.hours / 24
        if days >= 1 {
            return String(localized: "Das sind \(days.formatted(.number.precision(.fractionLength(1)))) Tage am Stück.")
        }
        return String(localized: "Das sind \((review.hours * 60).formatted(.number.precision(.fractionLength(0)))) Minuten.")
    }
}

/// The year's heatmap without a base map, so it can be drawn into the shared image (a map view can't).
private struct YearReviewHeatmap: View {
    let runs: [SegmentHeatmap.Run]

    var body: some View {
        // Styled up front: `HeatColor` belongs to the main actor, the renderer may not.
        let lines = runs.sorted { $0.count < $1.count }.filter { $0.coordinates.count > 1 }.map { run in
            (coordinates: run.coordinates, color: Color(HeatColor.color(for: run.count)), width: HeatColor.width(for: run.count) / 2)
        }
        Canvas { context, size in
            let points = lines.flatMap(\.coordinates)
            guard let minLat = points.map(\.latitude).min(), let maxLat = points.map(\.latitude).max(),
                  let minLon = points.map(\.longitude).min(), let maxLon = points.map(\.longitude).max()
            else { return }
            // Equirectangular, with longitudes shrunk to the latitude's scale so the shape isn't stretched.
            let lonScale = cos((minLat + maxLat) / 2 * .pi / 180)
            let width = max((maxLon - minLon) * lonScale, 0.01), height = max(maxLat - minLat, 0.01)
            let inset = 12.0
            let scale = min((size.width - 2 * inset) / width, (size.height - 2 * inset) / height)
            let offsetX = (size.width - width * scale) / 2, offsetY = (size.height - height * scale) / 2
            func point(_ coordinate: Coordinate) -> CGPoint {
                CGPoint(x: offsetX + (coordinate.longitude - minLon) * lonScale * scale,
                        y: offsetY + (maxLat - coordinate.latitude) * scale)
            }
            for line in lines {
                var path = Path()
                path.move(to: point(line.coordinates[0]))
                for coordinate in line.coordinates.dropFirst() { path.addLine(to: point(coordinate)) }
                context.stroke(path, with: .color(line.color),
                               style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Banner

/// Offers the review on the Verbindungen tab in December (the running year) and January (the year
/// just ended), for the whole month.
struct YearReviewBanner: View {
    let year: Int
    @State private var showsReview = false

    var body: some View {
        Button {
            showsReview = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.brandText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dein Bahnjahr \(String(year))").font(.headline)
                    Text("Kilometer, Lieblingszüge und mehr im Jahresrückblick.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            // Flat like the page's other cards, the red only in the symbol.
            .background(Color.card, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showsReview) { YearReviewView(year: year) }
    }
}

// MARK: - Data

extension AppModel {
    /// The travel map's selection for a calendar year, so the review shares its rides and cached heatmap.
    func yearReviewSelection(for year: Int) -> TravelMapSelection {
        let calendar = Calendar.current
        return TravelMapSelection(range: .custom,
                                  customFrom: calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                                  customTo: calendar.date(from: DateComponents(year: year, month: 12, day: 31)),
                                  includeSaved: true, includeTraewelling: settings.traewellingEnabled)
    }

    /// The years with rides, newest first.
    func yearReviewYears() async -> [Int] {
        await loadTraewellingTrips()
        let all = TravelMapSelection(range: .all, includeTraewelling: settings.traewellingEnabled)
        return YearReview.years(of: travelledLegs(of: mapJourneys(for: all)).map(\.leg))
    }

    /// The year the banner offers right now, if it has rides; cheap enough for every visit of the tab.
    func featuredYearReview() async -> Int? {
        #if DEBUG
        // `-showYearReview YES` (launch argument): the banner all year round, for testing. The review itself
        // falls back to the latest year with rides.
        if UserDefaults.standard.bool(forKey: "showYearReview") {
            return Calendar.current.component(.year, from: .now)
        }
        #endif
        guard let year = YearReview.featuredYear(on: .now) else { return nil }
        await loadTraewellingTrips()
        let calendar = Calendar.current
        let journeys = savedJourneys.map(\.journey) + (settings.traewellingEnabled ? traewellingTrips.map(\.journey) : [])
        let hasRides = journeys.contains { journey in
            journey.transitLegs.contains { calendar.component(.year, from: $0.departure.planned) == year && $0.arrival.best <= .now }
        }
        return hasRides ? year : nil
    }

    /// The review of `year` and its heatmap. Loads the missing track geometry like the travel map
    /// (and caches the heatmap for it); nil when cancelled.
    func yearReview(for year: Int, onProgress: (Int, Int) -> Void) async -> (review: YearReview, runs: [SegmentHeatmap.Run])? {
        let selection = yearReviewSelection(for: year)
        guard let heatmap = await mapHeatmap(for: selection, progressively: false, onProgress: onProgress) else { return nil }
        let legs = travelledLegs(of: mapJourneys(for: selection)).map(\.leg)
        let (lines, _) = await cachedGeometries(for: legs)
        guard !Task.isCancelled else { return nil }
        let geometries = Dictionary(lines.map { ($0.leg.id, $0.coordinates) }, uniquingKeysWith: { first, _ in first })
        let formations = rememberedFormations(for: legs)
        let review = await Task.detached(priority: .userInitiated) {
            YearReview(year: year, rides: zip(legs, formations).map { leg, formation in
                YearReview.Ride(leg: leg, geometry: geometries[leg.id], formation: formation)
            })
        }.value
        guard !Task.isCancelled else { return nil }
        return (review, heatmap.runs)
    }
}
