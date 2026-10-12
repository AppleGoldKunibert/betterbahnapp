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
    /// Open trips; the tab bar is hidden while one is showing (see `ConnectionsRoute` for why it's done here).
    @State private var path: [BoardEntry] = []
    @State private var isLoading = false
    @State private var error: Error?
    @State private var lastUpdate: Date?
    /// `reloadKey` the current `entries` belong to; the board is only cleared when it changes, not when the tab reappears.
    @State private var loadedKey: String?
    /// When the board was last on screen (tab left or app in the background); see `resumeAfterAbsence`.
    @State private var leftAt: Date?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var stationFocused: Bool?

    private var filter: BoardFilter {
        BoardFilter(products: products, ticketFilter: onlyValidTicket ? model.ticketFilter : nil)
    }

    private var reloadKey: String {
        let productsKey = products.map(\.rawValue).sorted().joined(separator: ",")
        return "\(station?.id ?? "")|\(kind)|\(useNow ? "now" : date.description)|\(productsKey)"
    }

    private var isFiltered: Bool { onlyValidTicket || products.count != Product.allCases.count }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12, pinnedViews: []) {
                    headerCard

                    if station == nil {
                        favoritesSection
                    }

                    if let error {
                        ErrorBanner(error: error)
                    }

                    if station != nil {
                        let visible = filter.apply(entries)
                        if !visible.isEmpty {
                            SectionHeader(title: kind == .departures ? "Abfahrten" : "Ankünfte",
                                          systemImage: kind == .departures ? "arrow.up.right" : "arrow.down.right",
                                          trailing: lastUpdate.map { "Stand \($0.timeString)" })
                                .padding(.top, 4)
                        }
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().padding(.leading, 84) }
                                    NavigationLink(value: entry) {
                                        BoardRow(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .opacity(visible.isEmpty ? 0 : 1)

                        if !isLoading, visible.isEmpty, error == nil, lastUpdate != nil {
                            ContentUnavailableView("Keine Züge", systemImage: "tram.fill",
                                                   description: Text(isFiltered ? "Versuch es ohne Filter." : "In den nächsten 90 Minuten fährt hier nichts."))
                                .padding(.top, 40)
                        }
                        if entries.first?.source == .transitous {
                            SourceNotice()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
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
                    filterMenu
                }
            }
            .refreshable { await load() }
            .task(id: reloadKey) {
                if loadedKey != reloadKey {
                    entries = []
                    lastUpdate = nil
                    loadedKey = reloadKey
                }
                // Auto-refresh every 60 seconds while visible; coming back to the tab keeps the
                // rows on screen and just updates them.
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                onlyValidTicket = model.settings.ticketFilterByDefault
                resumeAfterAbsence()
            }
            .onDisappear { if path.isEmpty { leftAt = .now } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    if path.isEmpty { leftAt = .now }
                } else if phase == .active {
                    resumeAfterAbsence()
                }
            }
            .navigationDestination(for: BoardEntry.self) { TripView(entry: $0) }
        }
        .toolbar(path.isEmpty ? .automatic : .hidden, for: .tabBar)
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

    private var filterMenu: some View {
        Menu {
            Toggle(isOn: $onlyValidTicket) {
                Label(model.settings.ticketType.filterTitle, systemImage: model.settings.ticketType.symbolName)
            }
            productFilterItems
        } label: {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Filter")
    }

    @ViewBuilder
    private var productFilterItems: some View {
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
        }
        Section {
            ForEach(Product.allCases, id: \.self) { product in
                Toggle(isOn: Binding(
                    get: { products.contains(product) },
                    set: { if $0 { products.insert(product) } else { products.remove(product) } }
                )) {
                    Label(product.displayName, systemImage: product.symbolName)
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
        if away >= 7.5 * 60 {
            station = nil
            error = nil
        }
    }

    private func load() async {
        guard let station else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let start = useNow ? Date.now.addingTimeInterval(-5 * 60) : date
            let loaded = try await model.provider.board(kind, at: station, date: start, duration: 90, products: products)
            withAnimation(.snappy) { entries = loaded }
            lastUpdate = .now
            error = nil
            // Some feeds (e.g. S-Bahn Berlin's own) leave the platform out entirely even at stations
            // where other lines on the same board carry one; fill the gap from DB's own schedule once
            // the board is already showing, so this never blocks the initial render.
            if let timetables = model.timetablesClient {
                let filled = await timetables.fillMissingPlatforms(in: loaded, at: station)
                if filled != entries { withAnimation(.snappy) { entries = filled } }
            }
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            self.error = error
        }
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
