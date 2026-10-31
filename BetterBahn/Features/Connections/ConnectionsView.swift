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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var showTimePicker = false
    @State private var productsTapCount = 0
    @FocusState private var focused: Field?
    /// A station field shows its suggestions (they stay a moment after it loses focus).
    @State private var suggestionsShown = false
    @State private var path: [ConnectionsRoute] = []
    @State private var swapRotation = 0.0
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
                    if let year = reviewBannerYear {
                        YearReviewBanner(year: year)
                            .transition(.fold)
                    }
                    TripTicketsSection()
                    if !model.recentSearches.isEmpty {
                        recentSection
                    }
                    moreLinks
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .closesMenusOnScroll()
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

    /// The whole search on one ticket: the route on top, the options as fields below a perforation and,
    /// torn off by a second one, the search button. On the iPad the button stays at the column's bottom.
    private var ticketCard: some View {
        VStack(spacing: 0) {
            routeSection
                .clipShape(TicketTopShape())
            TicketPerforation()
            optionsSection
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            if sizeClass != .regular {
                TicketPerforation()
                searchButtons
                    .padding(16)
            }
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

    /// The options as ticket fields, two side by side (one below the other with very large text). A tap on
    /// a field opens its menu or popover.
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    timeField
                    Divider()
                    transfersField
                    Divider()
                    productsField
                    Divider()
                    ticketField
                    if model.settings.bikeOption.searchTitle != nil {
                        Divider()
                        bikeField
                    }
                }
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        timeField
                        transfersField
                    }
                    Divider()
                    GridRow {
                        productsField
                        ticketField
                    }
                    if model.settings.bikeOption.searchTitle != nil {
                        Divider()
                        GridRow {
                            bikeField
                                .gridCellColumns(2)
                        }
                    }
                }
            }

            if !viaRows.isEmpty {
                viaTimeNote
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var viaTimeNote: some View {
        Label("Mit Zwischenhalten suchen wir ab der gewählten Abfahrtszeit.", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // Via routing only searches by departure, so the field says so whatever was picked before.
    private var searchesByArrival: Bool { isArrival && viaRows.isEmpty }

    private var timeValue: String {
        useNow ? String(localized: "Jetzt") : TimeSelector.label(for: date)
    }

    /// Departure or arrival and the time; the popover holds both, the clock in a picked time's tile resets it.
    private var timeField: some View {
        let title = searchesByArrival ? String(localized: "Ankunft") : String(localized: "Abfahrt")
        return Button {
            showTimePicker = true
        } label: {
            TicketFieldLabel(title: title, value: timeValue, changed: !useNow || searchesByArrival,
                             indicator: useNow ? "chevron.down" : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(timeValue)
        .popover(isPresented: $showTimePicker) { timePopover }
        .overlay(alignment: .trailing) {
            if !useNow {
                Button {
                    withAnimation(.snappy) {
                        useNow = true
                        date = .now
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Auf jetzt setzen")
                .transition(.opacity)
            }
        }
    }

    private var timePopover: some View {
        VStack(spacing: 12) {
            // With stopovers it shows departure, like the field.
            Picker("Zeit", selection: Binding(get: { searchesByArrival }, set: { isArrival = $0 })) {
                Label("Abfahrt", systemImage: "arrow.up.right").tag(false)
                Label("Ankunft", systemImage: "arrow.down.right").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!viaRows.isEmpty)
            if !viaRows.isEmpty {
                viaTimeNote
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DatePicker("Zeit", selection: Binding(get: { date }, set: { date = $0; useNow = false }))
                .datePickerStyle(.graphical)
                .tint(.brand)
            HStack {
                Button {
                    useNow = true
                    date = .now
                    showTimePicker = false
                } label: {
                    Label("Jetzt", systemImage: "clock.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Fertig") { showTimePicker = false }
                    .buttonStyle(.glassProminent)
            }
            .tint(.brand)
        }
        // The graphical picker has no ideal width of its own, so a popover (wide screens) squeezes it.
        .frame(minWidth: 320, idealWidth: 340)
        .padding()
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.height(viaRows.isEmpty ? 560 : 590)])
    }

    private var transfersValue: String {
        switch maxTransfers {
        case nil: String(localized: "Beliebig")
        case 0?: String(localized: "Direkt")
        case let count?: String(localized: "Höchstens \(count)")
        }
    }

    private var transfersField: some View {
        Menu {
            Section("Weniger Umsteigen, evtl. länger unterwegs") {
                Picker("Max. Umstiege", selection: $maxTransfers) {
                    Text("Beliebig").tag(Int?.none)
                    Text("Direkt").tag(Int?.some(0))
                    Text("Höchstens \(1)").tag(Int?.some(1))
                    Text("Höchstens \(2)").tag(Int?.some(2))
                }
                .pickerStyle(.inline)
            }
        } label: {
            TicketFieldLabel(title: String(localized: "Umstiege"), value: transfersValue, changed: maxTransfers != nil)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Max. Umstiege")
        .accessibilityValue(transfersValue)
    }

    private var productsField: some View {
        Button {
            productsTapCount += 1
        } label: {
            TicketFieldLabel(title: String(localized: "Verkehrsmittel"), value: productSummary,
                             changed: perLeg || products != all, indicator: "chevron.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Verkehrsmittel")
        .accessibilityValue(productSummary)
        .id(Self.productsRowID)
        .popover(isPresented: $showProductsPopover) { productsPopover }
    }

    private var ticketField: some View {
        let ticket = model.settings.ticketType
        let value = onlyValidTicket ? ticket.filterTitle : String(localized: "Alle Verbindungen")
        return Menu {
            Toggle(isOn: $onlyValidTicket) {
                Text(ticket.filterTitle)
                Text(ticket.filterSubtitle)
            }
        } label: {
            TicketFieldLabel(title: String(localized: "Ticket"), value: value, changed: onlyValidTicket)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Ticket")
        .accessibilityValue(value)
    }

    @ViewBuilder
    private var bikeField: some View {
        let option = model.settings.bikeOption
        if let title = option.searchTitle {
            let withBike = model.settings.searchWithBike
            let value = withBike ? String(localized: "Dabei") : String(localized: "Nicht dabei")
            Menu {
                Toggle(isOn: Bindable(model.settings).searchWithBike) {
                    Text(title)
                    Text(option == .foldingBike
                         ? String(localized: "Zeigt, wo dein Klapprad mitkommt") : String(localized: "Zeigt, ob dein Fahrrad mitkommt"))
                }
            } label: {
                TicketFieldLabel(title: option.displayName, value: value, changed: withBike)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel(option.displayName)
            .accessibilityValue(value)
        }
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

    // MARK: Search

    /// The ticket's stub: the search and, small next to it, adding a ticket.
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

    /// The recent searches as plain rows; a tap fills in start and destination.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Zuletzt gesucht"), systemImage: "clock.arrow.circlepath")
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
        }
    }

    /// Past trips and the collection, as plain rows at the page's end.
    private var moreLinks: some View {
        VStack(spacing: 0) {
            RouteLink(value: ConnectionsRoute.pastTrips) {
                LinkRowLabel(title: String(localized: "Vergangene Fahrten"), systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 40)
            CollectionButton()
        }
        .padding(.horizontal, 4)
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
