import BetterBahnKit
import SwiftUI

/// A journey pushed onto a tab's navigation stack. Pushed by value (instead of an inline
/// `NavigationLink`) so the stack's path knows a journey is open and the tab bar can be hidden
/// from the stack itself — hiding it from inside the pushed view made it come back late after a swipe-back.
struct JourneyRoute: Hashable {
    var journey: Journey
    var finalDestination: Station
    var readOnly = false
    var title = String(localized: "Reiseplan")
    /// The search this journey came from, so a re-plan can start from the same options.
    var search: ConnectionSearch?
}

enum ConnectionsRoute: Hashable {
    case search(ConnectionSearch)
    case journey(JourneyRoute)
    case pastTrips
    case collection
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
    /// "Mit Fahrrad" (#398): legs say whether a bike can come along, saving warns about bike reservations.
    /// The results aren't filtered by it, since the feeds don't know which German trains take bikes.
    var withBike = false

    var isFiltered: Bool { products != Set(Product.allCases) || maxTransfers != nil }

    /// Stored under the old "onlyBC100" key so journeys saved before the Deutschlandticket filter still load.
    enum CodingKeys: String, CodingKey {
        case from, to, via, date, isArrival, products, maxTransfers, hasProductGroups, withBike
        case onlyValidTicket = "onlyBC100"
    }

    init(from: Station, to: Station, via: [ViaWaypoint] = [], date: Date, isArrival: Bool, onlyValidTicket: Bool,
         products: Set<Product> = Set(Product.allCases), maxTransfers: Int? = nil, withBike: Bool = false) {
        self.from = from
        self.to = to
        self.via = via
        self.date = date
        self.isArrival = isArrival
        self.onlyValidTicket = onlyValidTicket
        self.products = products
        self.maxTransfers = maxTransfers
        self.withBike = withBike
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(Station.self, forKey: .from)
        to = try container.decode(Station.self, forKey: .to)
        via = try container.decodeIfPresent([ViaWaypoint].self, forKey: .via) ?? []
        date = try container.decode(Date.self, forKey: .date)
        isArrival = try container.decode(Bool.self, forKey: .isArrival)
        onlyValidTicket = try container.decode(Bool.self, forKey: .onlyValidTicket)
        maxTransfers = try container.decodeIfPresent(Int.self, forKey: .maxTransfers)
        withBike = try container.decodeIfPresent(Bool.self, forKey: .withBike) ?? false
        let stored = try container.decodeIfPresent(Set<Product>.self, forKey: .products) ?? Set(Product.allCases)
        // Searches saved before night trains and IR/FLX were groups of their own lack the marker.
        let isCurrent = try container.decodeIfPresent(Bool.self, forKey: .hasProductGroups) == true
        products = isCurrent ? stored : Product.upgradingLegacySelection(stored)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(via, forKey: .via)
        try container.encode(date, forKey: .date)
        try container.encode(isArrival, forKey: .isArrival)
        try container.encode(onlyValidTicket, forKey: .onlyValidTicket)
        try container.encode(products, forKey: .products)
        try container.encodeIfPresent(maxTransfers, forKey: .maxTransfers)
        try container.encode(withBike, forKey: .withBike)
        try container.encode(true, forKey: .hasProductGroups)
    }
}

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
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
    /// "Zuletzt gesucht" is unfolded.
    @AppStorage("recentSearchesExpanded") private var recentExpanded = false
    /// The year the review banner offers (#319); nil without any rides.
    @State private var reviewBannerYear: Int?

    private static let startLegID = UUID()
    private static let productsRowID = "productsRow"

    /// Up to this many intermediate stops can be added to a single search.
    private static let maxViaPoints = 4

    enum Field: Hashable {
        case from, to, via(UUID)
    }

    var body: some View {
        SplitNavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Text("Wohin geht’s?")
                        .font(.largeTitle.weight(.heavy))
                        .fontDesign(.rounded)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                    ticketCard
                    optionsCard
                    if sizeClass != .regular {
                        searchButtons
                    }
                    if let year = reviewBannerYear {
                        YearReviewBanner(year: year)
                            .transition(.fold)
                    }
                    TripTicketsSection()
                    moreButtons
                    if !model.recentSearches.isEmpty {
                        recentSection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            // Next to a journey the column is often shorter than the search form (iPhone Duo unfolded, #487):
            // the search stays at its bottom.
            .safeAreaBar(edge: .bottom) {
                if sizeClass == .regular {
                    searchButtons
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            // The disabled button is see-through: hide the cards scrolling under it.
            .scrollEdgeEffectStyle(sizeClass == .regular ? .hard : nil, for: .bottom)
            .onChange(of: productsTapCount) {
                // Bring the field into view first so the popover has room instead of being squeezed.
                withAnimation(.snappy) { proxy.scrollTo(Self.productsRowID, anchor: .center) }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    showProductsPopover = true
                }
            }
            }
            .tabBarSafePadding()
            .background { AppBackground() }
            .calmDesign()
            .environment(\.headingDesign, .rounded)
            .navigationTitle("Verbindungen")
            // The page's own headline takes the title's place; the title stays for the back button.
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Zug suchen", systemImage: "train.side.front.car") { model.showsTrainSearch = true }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .closesStationSearchOnOutsideTap($focused)
            .onAppear { onlyValidTicket = model.settings.ticketFilterByDefault }
            .task { await model.keepFollowedCheckinsFresh() }
            .task { reviewBannerYear = await model.featuredYearReview() }
            .onChange(of: model.journeyToOpen, initial: true) { _, entry in
                guard let entry else { return }
                path = [.journey(entry.route())]
                model.journeyToOpen = nil
            }
            // The departure board widget's route was tapped (#314): search it right away.
            .onChange(of: model.searchToOpen, initial: true) { _, search in
                guard let search else { return }
                from = search.from
                to = search.to
                viaRows = []
                model.remember(from: search.from, to: search.to)
                path = [.search(search)]
                model.searchToOpen = nil
            }
            // The followed check-ins list sits on the first page (#266).
            .onChange(of: model.followedCheckinToOpen, initial: true) { _, id in
                if id != nil { path = [] }
            }
        } destination: { route in
            switch route {
            case .search(let search):
                JourneyResultsView(search: search)
            case .journey(let journey):
                JourneyDetailView(journey: journey.journey, finalDestination: journey.finalDestination,
                                  readOnly: journey.readOnly, title: journey.title, search: journey.search)
            case .pastTrips:
                PastTripsView()
            case .collection:
                CollectionView()
            }
        } placeholder: {
            SplitPlaceholder(title: String(localized: "Verbindungen"), systemImage: "arrow.triangle.swap",
                             message: String(localized: "Such eine Verbindung oder wähl eine deiner Reisen."))
        }
        .toolbar(showsJourney ? .hidden : .automatic, for: .tabBar)
    }

    /// A journey hides the tab bar on the iPhone; next to the search on the iPad it stays.
    private var showsJourney: Bool {
        guard sizeClass != .regular else { return false }
        if case .journey = path.last { return true }
        return false
    }

    // MARK: Ticket

    /// The route and the time on one ticket, parted by a perforation between two notches.
    private var ticketCard: some View {
        VStack(spacing: 0) {
            routeSection
                .clipShape(TicketTopShape())
            TicketPerforation()
            timeSection
                .padding(16)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fontDesign(.rounded)
        .ticketBackground()
        .environment(\.cardSurface, Color.ticket)
        .onPreferenceChange(StationSuggestionsShownKey.self) { shown in
            withAnimation(.snappy(duration: 0.25)) { suggestionsShown = shown }
        }
    }

    private var routeSection: some View {
        VStack(spacing: 0) {
            StationInput(label: String(localized: "Von"), placeholder: String(localized: "Von wo?"), systemImage: "circle.circle.fill",
                         iconColor: .primary, station: $from, focus: $focused, focusValue: .from)
                .environment(\.ticketStationFields, true)

            // The swap button always sits right below Start, so it never drifts onto (and
            // covers) a via row's own remove button as the card grows with more stops.
            routeDivider(showAdd: viaRows.isEmpty, showSwap: true)

            ForEach($viaRows) { $row in
                ViaRowView(row: $row, focus: $focused, focusValue: .via(row.id)) {
                    withAnimation(.snappy) { viaRows.removeAll { $0.id == row.id } }
                }
                routeDivider(showAdd: row.id == viaRows.last?.id, showSwap: false)
            }

            StationInput(label: String(localized: "Nach"), placeholder: String(localized: "Wohin?"), systemImage: "mappin.circle.fill",
                         station: $to, focus: $focused, focusValue: .to)
                .environment(\.ticketStationFields, true)
        }
        .backgroundPreferenceValue(RouteMarkerKey.self) { anchors in
            // The stops sit on one line, like on a route map; hidden while suggestions push between them.
            GeometryReader { proxy in
                let points = anchors.map { proxy[$0] }
                if !suggestionsShown, let top = points.min(by: { $0.y < $1.y }), let bottom = points.max(by: { $0.y < $1.y }) {
                    Path { path in
                        path.move(to: top)
                        path.addLine(to: CGPoint(x: top.x, y: bottom.y))
                    }
                    .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
        }
        .frame(maxWidth: .infinity)
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
                        // The plus sits on the line between the stops.
                        addViaButton.padding(.leading, 16)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(swapRotation))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.ticket))
                .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        .disabled(from == nil && to == nil)
        .opacity(from == nil && to == nil ? 0.5 : 1)
        .accessibilityLabel("Start und Ziel tauschen")
        .transition(.opacity)
    }

    private var addViaButton: some View {
        Button {
            withAnimation(.snappy) {
                viaRows.append(ViaRow())
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.ticket))
                    .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 1))
                Text("Zwischenhalt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Covers the divider behind the text.
            .padding(.trailing, 8)
            .background(Capsule().fill(Color.ticket))
            .frame(height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zwischenhalt hinzufügen")
    }

    // MARK: Options

    /// Departure or arrival and the time: the ticket's lower part.
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                // Via routing only searches by departure, so with stopovers the switch shows that.
                Picker("Zeit", selection: Binding(get: { isArrival && viaRows.isEmpty }, set: { isArrival = $0 })) {
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
        }
    }

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $onlyValidTicket) {
                    let ticket = model.settings.ticketType
                    optionLabel(ticket.filterTitle, subtitle: ticket.filterSubtitle, icon: ticket.symbolName, color: .brand)
                }
                .tint(.brand)

                Divider()

                if let title = model.settings.bikeOption.searchTitle {
                    Toggle(isOn: Bindable(model.settings).searchWithBike) {
                        optionLabel(title, subtitle: model.settings.bikeOption == .foldingBike
                                    ? String(localized: "Zeigt, wo dein Klapprad mitkommt") : String(localized: "Zeigt, ob dein Fahrrad mitkommt"),
                                    icon: "bicycle", color: .brand)
                    }
                    .tint(.brand)

                    Divider()
                }

                transfersPicker

                productsButton
            }
        }
    }

    private var transfersPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            optionLabel(String(localized: "Max. Umstiege"), subtitle: String(localized: "Weniger Umsteigen, evtl. länger unterwegs"), icon: "arrow.triangle.swap", color: .brand)
            MaxTransfersPicker(maxTransfers: $maxTransfers)
        }
    }

    private var productsButton: some View {
        Button {
            productsTapCount += 1
        } label: {
            HStack {
                optionLabel(String(localized: "Verkehrsmittel"), subtitle: productSummary,
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
        perLeg ? String(localized: "Pro Abschnitt festgelegt") : BetterBahn.productSummary(products)
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
        let names: [String] = [from?.displayName ?? String(localized: "Start")]
            + viaRows.map { $0.station?.displayName ?? String(localized: "Zwischenhalt") }
            + [to?.displayName ?? String(localized: "Ziel")]
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

    private var searchButtons: some View {
        HStack(spacing: 10) {
            searchButton
            AddTicketButton()
        }
    }

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

    /// The recent searches as plain rows, folded away by default; a tap fills in start and destination.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { recentExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Zuletzt gesucht")
                        .font(.title3.weight(.bold))
                        .fontDesign(.rounded)
                    Text(verbatim: "\(model.recentSearches.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(recentExpanded ? 0 : -90))
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(recentExpanded ? String(localized: "Ausgeklappt") : String(localized: "Eingeklappt"))

            if recentExpanded {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(model.recentSearches.enumerated()), id: \.element.id) { index, recent in
                        if index > 0 { Divider().padding(.leading, 16) }
                        Button {
                            withAnimation {
                                from = recent.from
                                to = recent.to
                                viaRows = []
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(recent.from.displayName) → \(recent.to.displayName)")
                                    .font(.subheadline.weight(.semibold))
                                    .fontDesign(.rounded)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Entfernen", systemImage: "trash", role: .destructive) {
                                model.recentSearches.removeAll { $0.id == recent.id }
                            }
                        }
                        .accessibilityLabel("\(recent.from.displayName) nach \(recent.to.displayName)")
                    }
                }
            }
            .transition(.opacity)
            }
        }
    }

    /// Past trips and the collection.
    private var moreButtons: some View {
        HStack(spacing: 10) {
            RouteLink(value: ConnectionsRoute.pastTrips) {
                Label("Vergangene Fahrten", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            CollectionButton()
        }
    }

    private func search() {
        guard let from, let to else { return }
        let via = viaRows.compactMap { row in row.station.map { ViaWaypoint(station: $0, minStayMinutes: row.minStayMinutes, products: perLeg ? legProducts[row.id] ?? all : nil) } }
        model.remember(from: from, to: to)
        // Via routing only supports "depart at" — an arrival deadline doesn't compose with per-stop minimum stays.
        // Replaces what is open: on the iPad the search stays visible next to earlier results.
        path = [.search(ConnectionSearch(from: from, to: to, via: via, date: useNow ? .now : date,
                                     isArrival: via.isEmpty ? isArrival : false, onlyValidTicket: onlyValidTicket,
                                     products: perLeg ? legProducts[Self.startLegID] ?? all : products,
                                     maxTransfers: maxTransfers, withBike: model.settings.searchWithBike))]
    }
}

#Preview {
    ConnectionsView()
        .environment(AppModel())
}
