import BetterBahnKit
import SwiftUI

/// A journey pushed onto a tab's navigation stack. Pushed by value (instead of an inline
/// `NavigationLink`) so the stack's path knows a journey is open and the tab bar can be hidden
/// from the stack itself — hiding it from inside the pushed view made it come back late after a swipe-back.
struct JourneyRoute: Hashable {
    var journey: Journey
    var finalDestination: Station
    var readOnly = false
    var title = "Reiseplan"
    /// The search this journey came from, so a re-plan can start from the same options.
    var search: ConnectionSearch?
}

enum ConnectionsRoute: Hashable {
    case search(ConnectionSearch)
    case journey(JourneyRoute)
    case pastTrips
}

nonisolated struct ConnectionSearch: Hashable, Codable {
    var from: Station
    var to: Station
    var via: [ViaWaypoint] = []
    var date: Date
    var isArrival: Bool
    /// Only journeys valid with the ticket picked in the settings (Deutschlandticket or BahnCard 100).
    var onlyValidTicket: Bool
    var products = Set(Product.allCases)
    var maxTransfers: Int?

    var isFiltered: Bool { products != Set(Product.allCases) || maxTransfers != nil }

    /// Stored under the old "onlyBC100" key so journeys saved before the Deutschlandticket filter still load.
    enum CodingKeys: String, CodingKey {
        case from, to, via, date, isArrival, products, maxTransfers
        case onlyValidTicket = "onlyBC100"
    }
}

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var from: Station?
    @State private var to: Station?
    @State private var viaRows: [ViaRow] = []
    @State private var date = Date.now
    @State private var useNow = true
    @State private var isArrival = false
    @State private var onlyValidTicket = false
    @State private var products = Set(Product.allCases)
    @State private var maxTransfers: Int?
    /// When on, each route section (start → first stop, stop → next stop, …) has its own vehicle selection.
    @State private var productsPerLeg = false
    /// Per-section selections; the section from the start is keyed by `startLegID`, the others by the via row they start at.
    @State private var legProducts: [UUID: Set<Product>] = [:]
    @State private var showProductsPopover = false
    @State private var productsTapCount = 0
    @FocusState private var focused: Field?
    /// A station field shows its suggestions (they stay a moment after it loses focus).
    @State private var suggestionsShown = false
    @State private var path: [ConnectionsRoute] = []
    @State private var swapRotation = 0.0

    private static let startLegID = UUID()
    private static let productsRowID = "productsRow"

    /// Up to this many intermediate stops can be added to a single search.
    private static let maxViaPoints = 4

    enum Field: Hashable {
        case from, to, via(UUID)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    routeCard
                    optionsCard
                    HStack(spacing: 10) {
                        searchButton
                        AddTicketButton()
                    }
                    UpcomingTripsSection()
                    if !model.recentSearches.isEmpty {
                        recentSection
                    }
                    NavigationLink(value: ConnectionsRoute.pastTrips) {
                        Label("Vergangene Fahrten", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .onChange(of: productsTapCount) {
                // Bring the row into view first so the popover has room instead of being squeezed.
                withAnimation(.snappy) { proxy.scrollTo(Self.productsRowID, anchor: .center) }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    showProductsPopover = true
                }
            }
            }
            .tabBarSafePadding()
            .background { AppBackground() }
            .navigationTitle("Verbindungen")
            .navigationDestination(for: ConnectionsRoute.self) { route in
                switch route {
                case .search(let search):
                    JourneyResultsView(search: search)
                case .journey(let journey):
                    JourneyDetailView(journey: journey.journey, finalDestination: journey.finalDestination,
                                      readOnly: journey.readOnly, title: journey.title, search: journey.search)
                case .pastTrips:
                    PastTripsView()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { onlyValidTicket = model.settings.ticketFilterByDefault }
            .task { await model.keepFollowedCheckinsFresh() }
            .onChange(of: model.journeyToOpen, initial: true) { _, entry in
                guard let entry else { return }
                path = [.journey(entry.route())]
                model.journeyToOpen = nil
            }
        }
        .toolbar(showsJourney ? .hidden : .automatic, for: .tabBar)
    }

    private var showsJourney: Bool {
        if case .journey = path.last { return true }
        return false
    }

    // MARK: Route

    private var routeCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                StationInput(label: "Start", placeholder: "Von wo?", systemImage: "circle.circle.fill",
                             iconColor: .primary, station: $from, focus: $focused, focusValue: .from)

                // The swap button always sits right below Start, so it never drifts onto (and
                // covers) a via row's own remove button as the card grows with more stops.
                routeDivider(showAdd: viaRows.isEmpty, showSwap: true)

                ForEach($viaRows) { $row in
                    ViaRowView(row: $row, focus: $focused, focusValue: .via(row.id)) {
                        withAnimation(.snappy) { viaRows.removeAll { $0.id == row.id } }
                    }
                    routeDivider(showAdd: row.id == viaRows.last?.id, showSwap: false)
                }

                StationInput(label: "Ziel", placeholder: "Wohin?", systemImage: "mappin.circle.fill",
                             station: $to, focus: $focused, focusValue: .to)
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .onPreferenceChange(StationSuggestionsShownKey.self) { shown in
            withAnimation(.snappy(duration: 0.25)) { suggestionsShown = shown }
        }
    }

    /// A divider row between two stops, optionally carrying the leading "add via point" button
    /// and/or the trailing "swap" button (both hidden while suggestions are shown). Follows the
    /// suggestions rather than focus: the buttons make the row taller, which would push the
    /// suggestions below it away from a finger still on one.
    private func routeDivider(showAdd: Bool, showSwap: Bool) -> some View {
        ZStack {
            Divider().padding(.leading, 54).padding(.trailing, !suggestionsShown && showSwap ? 72 : 0)
            if !suggestionsShown {
                if showAdd, viaRows.count < Self.maxViaPoints {
                    HStack {
                        addViaButton.padding(.leading, 20)
                        Spacer()
                    }
                }
                if showSwap {
                    HStack {
                        Spacer()
                        swapButton
                    }
                }
            }
        }
    }

    private var swapButton: some View {
        Button {
            withAnimation(.spring(duration: 0.4)) {
                swap(&from, &to)
                swapRotation += 180
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.headline)
                .rotationEffect(.degrees(swapRotation))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .padding(.trailing, 14)
        .disabled(from == nil && to == nil)
        .accessibilityLabel("Start und Ziel tauschen")
        .transition(.opacity)
    }

    private var addViaButton: some View {
        Button {
            withAnimation(.snappy) {
                viaRows.append(ViaRow())
            }
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.brand)
        .accessibilityLabel("Zwischenhalt hinzufügen")
    }

    // MARK: Options

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Picker("Zeit", selection: $isArrival) {
                        Label("Abfahrt", systemImage: "arrow.up.right").tag(false)
                        Label("Ankunft", systemImage: "arrow.down.right").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(!viaRows.isEmpty)

                    Spacer()

                    TimeSelector(date: $date, useNow: $useNow)
                }

                if !viaRows.isEmpty {
                    Label("Mit Zwischenhalten suchen wir ab der gewählten Abfahrtszeit.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle(isOn: $onlyValidTicket) {
                    let ticket = model.settings.ticketType
                    optionLabel(ticket.filterTitle, subtitle: ticket.filterSubtitle, icon: ticket.symbolName, color: .brand)
                }
                .tint(.brand)

                Divider()

                transfersPicker

                productsButton
            }
        }
    }

    private var transfersPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            optionLabel("Max. Umstiege", subtitle: "Weniger Umsteigen, evtl. länger unterwegs", icon: "arrow.triangle.swap", color: .brand)
            MaxTransfersPicker(maxTransfers: $maxTransfers)
        }
    }

    private var productsButton: some View {
        Button {
            productsTapCount += 1
        } label: {
            HStack {
                optionLabel("Verkehrsmittel", subtitle: productSummary,
                            icon: "train.side.front.car", color: .brand)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(Self.productsRowID)
        .popover(isPresented: $showProductsPopover) { productsPopover }
    }

    private var productSummary: String {
        perLeg ? "Pro Abschnitt festgelegt" : BetterBahn.productSummary(products)
    }

    private var all: Set<Product> { Set(Product.allCases) }

    /// Per-section selection only makes sense once there is more than one section.
    private var perLeg: Bool { productsPerLeg && !viaRows.isEmpty }

    private var hasEmptyProductSelection: Bool {
        perLeg ? legProducts.filter { legIDs.contains($0.key) }.values.contains { $0.isEmpty } : products.isEmpty
    }

    private var legIDs: [UUID] { [Self.startLegID] + viaRows.map(\.id) }

    /// The route sections between consecutive stops, as (key, title) pairs.
    private var legs: [(id: UUID, title: String)] {
        let names = [from?.displayName ?? "Start"] + viaRows.map { $0.station?.displayName ?? "Zwischenhalt" } + [to?.displayName ?? "Ziel"]
        return legIDs.enumerated().map { ($1, "\(names[$0]) → \(names[$0 + 1])") }
    }

    private var productsPopover: some View {
        // A ScrollView alone would stretch the popover to full height; only scroll once the content is too tall.
        ViewThatFits(in: .vertical) {
            productsPopoverContent.fixedSize(horizontal: false, vertical: true)
            ScrollView { productsPopoverContent }
        }
        .frame(minWidth: 340)
        .presentationCompactAdaptation(.popover)
    }

    private var productsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 16) {
                Text("Verkehrsmittel").font(.subheadline.weight(.semibold))
                if !viaRows.isEmpty {
                    Picker("Gültig für", selection: $productsPerLeg) {
                        Text("Gesamte Reise").tag(false)
                        Text("Pro Abschnitt").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if perLeg {
                    ForEach(legs, id: \.id) { leg in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(leg.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ProductChips(products: Binding(get: { legProducts[leg.id] ?? all },
                                                           set: { legProducts[leg.id] = $0 }))
                        }
                    }
                } else {
                    ProductChips(products: $products)
                }
                Button("Fertig") { showProductsPopover = false }
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .frame(maxWidth: .infinity)
        }
        .padding()
    }

    private func optionLabel(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Search

    private var searchButton: some View {
        Button(action: search) {
            Label("Verbindungen suchen", systemImage: "magnifyingglass")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(from == nil || to == nil || hasEmptyProductSelection || viaRows.contains { $0.station == nil })
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Zuletzt gesucht", systemImage: "clock.arrow.circlepath")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(model.recentSearches.enumerated()), id: \.element.id) { index, recent in
                        if index > 0 { Divider().padding(.leading, 60) }
                        Button {
                            withAnimation {
                                from = recent.from
                                to = recent.to
                                viaRows = []
                            }
                        } label: {
                            HStack(spacing: 14) {
                                IconTile(systemImage: "arrow.triangle.swap", color: .secondary.opacity(0.6), size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recent.from.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.turn.down.right").font(.caption2)
                                        Text(recent.to.displayName).lineLimit(1)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Entfernen", systemImage: "trash", role: .destructive) {
                                model.recentSearches.removeAll { $0.id == recent.id }
                            }
                        }
                    }
                }
            }
        }
    }

    private func search() {
        guard let from, let to else { return }
        let via = viaRows.compactMap { row in row.station.map { ViaWaypoint(station: $0, minStayMinutes: row.minStayMinutes, products: perLeg ? legProducts[row.id] ?? all : nil) } }
        model.remember(from: from, to: to)
        // Via routing only supports "depart at" — an arrival deadline doesn't compose with per-stop minimum stays.
        path.append(.search(ConnectionSearch(from: from, to: to, via: via, date: useNow ? .now : date,
                                     isArrival: via.isEmpty ? isArrival : false, onlyValidTicket: onlyValidTicket,
                                     products: perLeg ? legProducts[Self.startLegID] ?? all : products,
                                     maxTransfers: maxTransfers)))
    }
}

#Preview {
    ConnectionsView()
        .environment(AppModel())
}
