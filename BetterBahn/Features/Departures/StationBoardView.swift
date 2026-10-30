import BetterBahnKit
import SwiftUI

struct StationBoardView: View {
    @Environment(AppModel.self) private var model
    @State private var station: Station?
    @State private var kind: BoardKind = .departures
    @State private var date = Date.now
    @State private var useNow = true
    @State private var products: Set<Product> = Set(Product.allCases)
    @State private var onlyValidTicket = false
    @State private var entries: [BoardEntry] = []
    /// Lifts out of order at the station (#486).
    @State private var liftAlerts: [LiftAlert] = []
    /// Open trips; the tab bar is hidden while one is showing (see `ConnectionsRoute` for why it's done here).
    @State private var path: [BoardEntry] = []
    @State private var isLoading = false
    @State private var error: Error?
    @State private var lastUpdate: Date?
    /// `boardKey` the current `entries` belong to; the board is only cleared when it changes, not when the tab reappears
    /// or the filter changes.
    @State private var loadedKey: String?
    /// When the board was last on screen (tab left or app in the background); see `resumeAfterAbsence`.
    @State private var leftAt: Date?
    /// Minutes the board's window starts after its base time ("jetzt" or the chosen time); moved by Früher/Später.
    @State private var windowOffset = 0
    /// Minutes the window covers: one page, two once Früher/Später was tapped. Never more: another tap
    /// drops the page at the other end and quietly moves `windowOffset` on.
    @State private var windowLength = Self.page
    @State private var loadingPage = false
    @State private var scrollPosition = ScrollPosition()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var stationFocused: Bool?

    private var filter: BoardFilter {
        BoardFilter(products: products, ticketFilter: onlyValidTicket ? model.ticketFilter : nil)
    }

    /// What the shown board is about; when it changes the old rows are dropped.
    private var boardKey: String {
        "\(station?.id ?? "")|\(kind)|\(useNow ? "now" : date.description)"
    }

    /// `boardKey` plus the transport filter. A new filter reloads the board (the feed filters by mode too) but keeps
    /// the rows on screen, which are filtered locally meanwhile; clearing them made the open filter menu jump.
    private var reloadKey: String {
        let productsKey = products.map(\.rawValue).sorted().joined(separator: ",")
        return "\(boardKey)|\(productsKey)"
    }

    private var isFiltered: Bool { onlyValidTicket || products.count != Product.allCases.count }

    /// Minutes one board page covers (the initial board and each Früher/Später step).
    private static let page = 90

    /// Time the window is measured from; `windowOffset` is added on top.
    private var baseTime: Date { useNow ? Date.now.addingTimeInterval(-5 * 60) : date }

    var body: some View {
        SplitNavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12, pinnedViews: []) {
                    headerCard

                    if station == nil {
                        favoritesSection
                    }

                    if let error {
                        ErrorBanner(error: error)
                    }

                    if station != nil, !liftAlerts.isEmpty {
                        LiftBanner(alerts: liftAlerts)
                    }

                    if station != nil {
                        let visible = filter.apply(entries)
                        if !visible.isEmpty {
                            SectionHeader(title: kind == .departures ? "Abfahrten" : "Ankünfte",
                                          systemImage: kind == .departures ? "arrow.up.right" : "arrow.down.right",
                                          trailing: lastUpdate.map { "Stand \($0.timeString)" })
                                .padding(.top, 4)
                        }
                        if lastUpdate != nil {
                            pageButton(kind == .departures ? "Frühere Abfahrten" : "Frühere Ankünfte", systemImage: "chevron.up") {
                                await loadPage(later: false)
                            }
                        }
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().padding(.leading, 84) }
                                    RouteLink(value: entry) {
                                        BoardRow(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .id(entry.id)
                                }
                            }
                        }
                        .opacity(visible.isEmpty ? 0 : 1)

                        if lastUpdate != nil, !visible.isEmpty {
                            pageButton(kind == .departures ? "Spätere Abfahrten" : "Spätere Ankünfte", systemImage: "chevron.down") {
                                await loadPage(later: true)
                            }
                        }

                        if !isLoading, visible.isEmpty, error == nil, lastUpdate != nil {
                            ContentUnavailableView("Keine Züge", systemImage: "tram.fill",
                                                   description: Text(isFiltered ? "Versuch es ohne Filter." : "In den nächsten 90 Minuten fährt hier nichts."))
                                .padding(.top, 40)
                            pageButton(kind == .departures ? "Spätere Abfahrten" : "Spätere Ankünfte", systemImage: "chevron.down") {
                                await loadPage(later: true)
                            }
                        }
                        if entries.first?.source == .transitous {
                            SourceNotice()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .scrollPosition($scrollPosition)
            .tabBarSafePadding()
            .background { AppBackground() }
            .overlay {
                if isLoading, entries.isEmpty, station != nil {
                    ProgressView()
                }
            }
            .navigationTitle("Bahnhofstafel")
            .toolbar {
                if let station {
                    ToolbarItem {
                        Button {
                            withAnimation { model.toggleFavorite(station) }
                        } label: {
                            Image(systemName: model.isFavorite(station) ? "star.fill" : "star")
                                .foregroundStyle(model.isFavorite(station) ? .yellow : .primary)
                        }
                        .accessibilityLabel("Favorit")
                    }
                }
                ToolbarItem {
                    BoardFilterMenu(products: $products, onlyValidTicket: $onlyValidTicket)
                }
            }
            .refreshable { await load() }
            .task(id: reloadKey) {
                if loadedKey != boardKey {
                    entries = []
                    liftAlerts = []
                    lastUpdate = nil
                    loadedKey = boardKey
                    resetWindow()
                }
                // Auto-refresh every 60 seconds while visible; coming back to the tab keeps the
                // rows on screen and just updates them.
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .closesStationSearchOnOutsideTap($stationFocused)
            .onAppear {
                onlyValidTicket = model.settings.ticketFilterByDefault
                resumeAfterAbsence()
            }
            .onDisappear { if path.isEmpty { leftAt = .now } }
            // The departure board widget was tapped (#314): its station's departures from now.
            .onChange(of: model.boardStationToOpen, initial: true) { _, opened in
                guard let opened else { return }
                kind = .departures
                useNow = true
                date = .now
                path = []
                withAnimation { station = opened }
                model.boardStationToOpen = nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    if path.isEmpty { leftAt = .now }
                } else if phase == .active {
                    resumeAfterAbsence()
                }
            }
        } destination: { entry in
            TripView(entry: entry)
        } placeholder: {
            SplitPlaceholder(title: "Bahnhofstafel", systemImage: "clock.arrow.2.circlepath",
                             message: "Wähl einen Zug, um seinen Fahrtverlauf zu sehen.")
        }
        // The tab bar stays next to the board on the iPad.
        .toolbar(path.isEmpty || sizeClass == .regular ? .automatic : .hidden, for: .tabBar)
    }

    private var headerCard: some View {
        VStack(spacing: 12) {
            Card(padding: 0) {
                StationInput(label: "Bahnhof", placeholder: "Bahnhof suchen", systemImage: "building.2.fill",
                             station: $station, focus: $stationFocused, focusValue: true)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
            }
            Card(padding: 12) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Picker("Anzeige", selection: $kind) {
                        Label("Abfahrten", systemImage: "arrow.up.right").tag(BoardKind.departures)
                        Label("Ankünfte", systemImage: "arrow.down.right").tag(BoardKind.arrivals)
                    }
                    .pickerStyle(.segmented)

                    TimeSelector(date: $date, useNow: $useNow)
                }

                if isFiltered {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if onlyValidTicket {
                                let ticket = model.settings.ticketType
                                InfoChip(text: ticket.displayName, systemImage: ticket.symbolName, tint: .brand)
                            }
                            if products.count != Product.allCases.count {
                                ForEach(Product.allCases.filter(products.contains), id: \.self) { product in
                                    InfoChip(text: product.displayName, systemImage: product.symbolName, tint: product.color)
                                }
                            }
                        }
                    }
                }
            }
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if model.favoriteStations.isEmpty {
            ContentUnavailableView {
                Label("Bahnhof wählen", systemImage: "building.2.fill")
            } description: {
                Text("Such einen Bahnhof, um Abfahrten und Ankünfte zu sehen. Mit dem Stern merkst du ihn dir.")
            }
            .padding(.top, 30)
        } else {
            SectionHeader(title: "Favoriten", systemImage: "star.fill")
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(model.favoriteStations) { favorite in
                    Button {
                        withAnimation { station = favorite }
                    } label: {
                        HStack(spacing: 10) {
                            IconTile(systemImage: "star.fill", color: .yellow, size: 30)
                            Text(favorite.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(Color.card, in: .rect(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Aus Favoriten entfernen", systemImage: "star.slash", role: .destructive) {
                            model.toggleFavorite(favorite)
                        }
                    }
                }
            }
        }
    }

    /// After 5 minutes away the board jumps back to "jetzt"; after 7.5 minutes the station is closed.
    private func resumeAfterAbsence() {
        guard let leftAt else { return }
        self.leftAt = nil
        let away = Date.now.timeIntervalSince(leftAt)
        guard away >= 5 * 60 else { return }
        useNow = true
        date = .now
        if windowOffset != 0 || windowLength != Self.page {
            resetWindow()
            Task { await load() }
        }
        if away >= 7.5 * 60 {
            station = nil
            error = nil
        }
    }

    /// Takes over a loaded board. Animates only if the rows on screen change: after a filter change the board is
    /// already filtered locally, so the answer for the same filter must not move anything while the menu is open.
    private func show(_ loaded: [BoardEntry]) {
        if filter.apply(loaded) == filter.apply(entries) {
            entries = loaded
        } else {
            withAnimation(.snappy) { entries = loaded }
        }
    }

    private func resetWindow() {
        windowOffset = 0
        windowLength = Self.page
    }

    private func load() async {
        guard let station else { return }
        isLoading = true
        defer { isLoading = false }
        // A Früher/Später tap while this loads changes the window; this answer is stale then.
        let window = (windowOffset, windowLength)
        do {
            let start = baseTime.addingTimeInterval(TimeInterval(windowOffset * 60))
            let loaded = try await model.provider.board(kind, at: station, date: start, duration: windowLength, products: products)
            guard window == (windowOffset, windowLength) else { return }
            show(loaded)
            lastUpdate = .now
            error = nil
            // Once the board is already showing (so this never blocks the initial render): DB's own delays,
            // early times and cancellations over bahn.de's and Transitous' (which show a train that runs early
            // as on time). Some feeds (e.g. S-Bahn Berlin's own) also leave the platform out entirely even at
            // stations where other lines on the same board carry one; that gap is filled from DB's schedule.
            if let timetables = model.timetablesClient {
                let live = await timetables.applyingRealtime(to: loaded, at: station)
                let filled = await timetables.fillMissingPlatforms(in: live, at: station)
                guard window == (windowOffset, windowLength) else { return }
                if filled != entries { show(filled) }
            }
            await loadLiftAlerts(at: station)
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            self.error = error
        }
    }

    /// Lifts out of order at `station` (#486); DB's list is asked at most every 5 minutes.
    private func loadLiftAlerts(at station: Station) async {
        let alerts = await model.liftAlerts(at: station)
        guard self.station == station, alerts != liftAlerts else { return }
        withAnimation { liftAlerts = alerts }
    }

    private func pageButton(_ title: String, systemImage: String, action: @escaping () async -> Void) -> some View {
        Button {
            loadingPage = true
            Task {
                await action()
                loadingPage = false
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(loadingPage)
    }

    /// Loads one page before or after the window and adds it. With two pages on the board already,
    /// the page at the other end goes: the board stays two pages long and its start moves along
    /// without reloading the rows that stay.
    private func loadPage(later: Bool) async {
        guard let station else { return }
        let key = reloadKey
        let pageOffset = later ? windowOffset + windowLength : windowOffset - Self.page
        let start = baseTime.addingTimeInterval(TimeInterval(pageOffset * 60))
        do {
            var page = try await model.provider.board(kind, at: station, date: start, duration: Self.page, products: products)
            if let timetables = model.timetablesClient {
                page = await timetables.fillMissingPlatforms(in: page, at: station)
            }
            guard key == reloadKey else { return }
            let shown = Set(entries.map(\.id))
            page.removeAll { shown.contains($0.id) }
            withAnimation(.snappy) { entries = later ? entries + page : page + entries }
            error = nil

            guard windowLength > Self.page else {
                windowLength += Self.page
                if !later { windowOffset -= Self.page }
                return
            }
            windowOffset += later ? Self.page : -Self.page
            let windowStart = baseTime.addingTimeInterval(TimeInterval(windowOffset * 60))
            let windowEnd = windowStart.addingTimeInterval(TimeInterval(windowLength * 60))
            if later {
                // The rows above the visible ones go. Keep the first new row at the bottom edge, where the
                // button was, so the board doesn't jump.
                let anchor = filter.apply(page).first?.id ?? filter.apply(entries).last?.id
                entries.removeAll { $0.time.best < windowStart }
                if let anchor { scrollPosition.scrollTo(id: anchor, anchor: .bottom) }
            } else {
                entries.removeAll { $0.time.planned > windowEnd }
            }
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            self.error = error
        }
    }
}

/// The toolbar's filter menu. A view of its own, so loading the board (which changes `StationBoardView`'s state several
/// times) doesn't rebuild the menu while it is open: only the two filters it edits can.
private struct BoardFilterMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var products: Set<Product>
    @Binding var onlyValidTicket: Bool

    private var isFiltered: Bool { onlyValidTicket || products.count != Product.allCases.count }

    var body: some View {
        Menu {
            Toggle(isOn: $onlyValidTicket) {
                Label(model.settings.ticketType.filterTitle, systemImage: model.settings.ticketType.symbolName)
            }
            Section("Verkehrsmittel") {
                Button("Nur Züge", systemImage: "train.side.front.car") {
                    products = Set(Product.allCases.filter(\.isTrain))
                }
                Button("Nur Fernverkehr", systemImage: "train.side.front.car") {
                    products = Product.longDistanceProducts
                }
                Button("Nur Regionalverkehr", systemImage: "train.side.rear.car") {
                    products = Product.regionalProducts
                }
                Button("Alle anzeigen", systemImage: "square.grid.2x2") {
                    products = Set(Product.allCases)
                }
                productMenu("Züge", systemImage: "tram.fill", products: Product.allCases.filter(\.isTrain))
                productMenu("Bus, Tram & Co.", systemImage: "bus.fill", products: Product.allCases.filter { !$0.isTrain })
            }
        } label: {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Filter")
    }

    /// One menu per group, so none is taller than the screen: iOS rebuilds an open menu on every change and set a
    /// scrolling one back by a bit, which made the single long list jump whenever a vehicle was switched.
    private func productMenu(_ title: String, systemImage: String, products group: [Product]) -> some View {
        Menu(title, systemImage: systemImage) {
            ForEach(group, id: \.self) { product in
                Toggle(isOn: Binding(
                    get: { products.contains(product) },
                    set: { if $0 { products.insert(product) } else { products.remove(product) } }
                )) {
                    Label(product.displayName, systemImage: product.symbolName)
                }
            }
        }
        .menuActionDismissBehavior(.disabled)
    }
}

struct BoardRow: View {
    let entry: BoardEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TimeStack(time: entry.time, cancelled: entry.cancelled, font: .title3.weight(.bold))
                .frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                LineBadge(line: entry.line, size: .small)
                HStack(spacing: 4) {
                    Image(systemName: entry.kind == .departures ? "arrow.right" : "arrow.left")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    Text(entry.otherEnd ?? "?")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .strikethrough(entry.cancelled)
                }
                if entry.access == .exitOnly {
                    InfoChip(text: "Nur Ausstieg", systemImage: "arrow.down.right.circle.fill", tint: .slightDelay)
                } else if entry.access == .entryOnly {
                    InfoChip(text: "Nur Einstieg", systemImage: "arrow.up.right.circle.fill", tint: .blue)
                }
                if let remark = entry.remarks.first {
                    Label(remark, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.slightDelay)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
            PlatformBadge(platform: entry.platform)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}

#Preview("Abfahrtstafel") {
    ScrollView {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(PreviewData.board.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 84) }
                    BoardRow(entry: entry)
                }
            }
        }
        .padding()
    }
    .background { AppBackground() }
}
