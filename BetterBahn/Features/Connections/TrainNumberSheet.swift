import BetterBahnKit
import SwiftUI

/// Collects one "ride this train" requirement (#225): a number ("ICE 91", "3300") lists the runs with
/// it at once, like the train search (same kinds and countries from Settings → Zugschnellsuche), and
/// their stops then tell which call on the route and go to the destination; a line ("RE 3") is looked
/// for on the route stations' boards, which also add other trains starting with what was typed.
/// Picking one shows its stops with boarding and exit already chosen; tapping stops changes them.
/// The route itself is planned by the caller once the sheet is done.
struct TrainNumberSheet: View {
    let search: ConnectionSearch
    let suggestions: [String]
    /// Pre-selected boarding station – the end of the previous requirement, or the search origin.
    let defaultBoarding: Station
    /// Where the train could be boarded, most likely first: their boards are searched.
    let stations: [Station]
    /// About when the train should leave.
    let date: Date
    let onAdd: (TrainRequirement) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var train = ""
    @State private var finder: TrainCandidateFinder?
    @State private var candidates: [TrainCandidate] = []
    /// Runs with the typed number, from the train search; nil when there is no number or no answer.
    @State private var numbered: [NumberedTrain]?
    /// Runs whose stops were asked for (answered or not), so ones the countries can't decide yet show then.
    @State private var checkedIDs: Set<String> = []
    @State private var countries: Set<String> = []
    @State private var isSearching = false
    /// The stops of the runs found by number are still loading.
    @State private var isCheckingRoute = false
    @State private var loadingTrainID: String?
    @State private var pickError: Error?
    @State private var searchedText = ""
    @State private var picked: TrainCandidate?
    @State private var boardingID: String?
    @State private var exitID: String?
    /// Typing the stations by hand, for a train none of the lists has.
    @State private var showsManualEntry = false
    @State private var boardingStation: Station?
    @State private var exitStation: Station?
    @FocusState private var focused: Field?

    private enum Field: Hashable { case train, boardingStation, exitStation }

    init(search: ConnectionSearch, suggestions: [String], defaultBoarding: Station, stations: [Station] = [],
         date: Date? = nil, onAdd: @escaping (TrainRequirement) -> Void) {
        self.search = search
        self.suggestions = suggestions
        self.defaultBoarding = defaultBoarding
        self.stations = [defaultBoarding] + stations
        self.date = date ?? search.date
        self.onAdd = onAdd
        _boardingStation = State(initialValue: defaultBoarding)
    }

    private var trimmed: String { train.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let picked {
                        pickedContent(picked)
                    } else {
                        searchField
                        listContent
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Bestimmter Zug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .onAppear {
                if finder == nil {
                    let finder = TrainCandidateFinder(provider: model.provider)
                    self.finder = finder
                    // The boards load while the train is typed, so the list shows right away.
                    let stations = stations, date = date
                    Task { await finder.prefetch(stations: stations, date: date) }
                }
                focused = .train
            }
            // Searches while typing, a moment after the last key.
            .task(id: trimmed) { await searchTrains() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Searching

    private var searchField: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(systemImage: "number", color: .brand, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zug").font(.headline)
                        Text("Ziel: \(search.to.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                TextField("z. B. ICE 423, RE 3 oder 3300", text: $train)
                    .font(.title3.weight(.semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused, equals: .train)
                    .onSubmit {
                        if let first = shownNumbered.first { pick(first) } else if let first = candidates.first { pick(first) }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if trimmed.isEmpty {
            Text("Tippe Zugname, Linie oder Zugnummer. Züge auf deiner Strecke, die zum Ziel fahren, stehen oben.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            if !suggestions.isEmpty {
                SectionHeader(title: "Züge aus den Ergebnissen", systemImage: "tram.fill")
                FlowChips(items: suggestions) { name in train = name }
            }
        } else {
            if isSearching, shownNumbered.isEmpty, candidates.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Suche Züge …").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            if let pickError { ErrorBanner(error: pickError) }
            ForEach(shownNumbered) { train in
                Button { pick(train) } label: { numberedRow(train) }
                    .buttonStyle(.plain)
                    .disabled(loadingTrainID != nil)
            }
            if isCheckingRoute {
                hint("Prüfe, wo die Züge halten …")
            }
            if !candidates.isEmpty, !shownNumbered.isEmpty {
                SectionHeader(title: "Weitere Züge auf deiner Strecke", systemImage: "tram.fill")
                    .padding(.top, 4)
            }
            ForEach(candidates) { candidate in
                Button { pick(candidate) } label: { candidateRow(candidate) }
                    .buttonStyle(.plain)
            }
            if isSearching, !shownNumbered.isEmpty || !candidates.isEmpty {
                hint("Suche auf den Bahnhöfen deiner Strecke …")
            }
            if isDone, shownNumbered.isEmpty, candidates.isEmpty {
                ContentUnavailableView("Kein passender Zug", systemImage: "tram.fill",
                                       description: Text("Auf deiner Strecke fährt um diese Zeit kein Zug „\(trimmed)“. Du kannst Ein- und Ausstieg auch selbst angeben."))
            }
            if isDone { manualEntry }
        }
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var isDone: Bool { !isSearching && !isCheckingRoute && searchedText == trimmed }

    /// The runs by number to show: in a wanted country by their ends, else once their stops say so
    /// (or couldn't be loaded – then rather shown than lost).
    private var shownNumbered: [NumberedTrain] {
        (numbered ?? []).filter { train in
            if let fit = train.fit { return fit.inCountries }
            return TrainCandidateFinder.countryStatus(train.result, countries: countries) == true || checkedIDs.contains(train.id)
        }
    }

    private func numberedRow(_ train: NumberedTrain) -> some View {
        let result = train.result
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LineBadge(line: Line(name: result.name, number: String(result.number), product: result.product, operatorName: nil))
                    Text("\(result.origin) → \(result.destination)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                if let fit = train.fit {
                    if let boarding = fit.boarding {
                        Label("ab \(boarding.displayName)\(fit.departure.map { " " + $0.timeString } ?? "")",
                              systemImage: "arrow.up.right.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if fit.reachesTarget {
                            InfoChip(text: "fährt bis \(search.to.displayName)", systemImage: "checkmark.circle.fill", tint: .punctual)
                        } else {
                            InfoChip(text: "fährt nicht bis \(search.to.displayName)", systemImage: "arrow.triangle.branch")
                        }
                    } else {
                        Label("hält nicht auf deiner Strecke – Einstieg selbst wählen", systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !checkedIDs.contains(train.id) {
                    Text("Prüfe Halte …").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if loadingTrainID == train.id {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }

    private func candidateRow(_ candidate: TrainCandidate) -> some View {
        let trip = candidate.trip
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LineBadge(line: trip.line)
                    if let destination = trip.destination {
                        Text("nach \(destination.displayName)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                if let boarding = candidate.boarding, let departure = boarding.departure {
                    Label("ab \(boarding.station.displayName) \(departure.planned.timeString)", systemImage: "arrow.up.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("hält nicht auf deiner Strecke – Einstieg selbst wählen", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let exit = candidate.exit, let arrival = exit.arrival {
                    InfoChip(text: "bis \(exit.station.displayName), an \(arrival.planned.timeString)",
                             systemImage: "checkmark.circle.fill", tint: .punctual)
                } else if candidate.boarding != nil {
                    InfoChip(text: "fährt nicht bis \(search.to.displayName)", systemImage: "arrow.triangle.branch")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }

    /// The old way: name plus stations typed by hand, for a train neither the boards nor the train search know.
    @ViewBuilder
    private var manualEntry: some View {
        DisclosureGroup(isExpanded: $showsManualEntry) {
            VStack(alignment: .leading, spacing: 12) {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        StationInput(label: "Einstieg", placeholder: "Ab wo einsteigen?", systemImage: "figure.walk",
                                     station: $boardingStation, focus: $focused, focusValue: .boardingStation)
                        Divider().padding(.leading, 54)
                        StationInput(label: "Ausstieg (optional)", placeholder: "Ideal: \(search.to.displayName)",
                                     systemImage: "mappin.circle.fill",
                                     station: $exitStation, focus: $focused, focusValue: .exitStation)
                    }
                }
                Button(action: addTyped) {
                    Label("„\(trimmed)“ vorgeben", systemImage: "pin.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .controlSize(.large)
                .disabled(trimmed.isEmpty || boardingStation == nil)
            }
            .padding(.top, 8)
        } label: {
            Text("Ein- und Ausstieg selbst angeben").font(.subheadline.weight(.semibold))
        }
        .tint(.brand)
        .padding(.horizontal, 4)
    }

    private func searchTrains() async {
        let text = trimmed
        pickError = nil
        guard !text.isEmpty, let finder else {
            candidates = []
            numbered = nil
            searchedText = ""
            isSearching = false
            isCheckingRoute = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        isCheckingRoute = false
        let stations = stations, target = search.to, date = date
        let filter = model.settings.trainSearchFilter
        // The boards load alongside; with a number, the train search's list comes first (one request).
        async let route = finder.routeCandidates(for: text, stations: stations, target: target, date: date)
        let number = TrainNameQuery(text).numberQuery?.number
        let found = await finder.numberTrains(for: text, date: date, filter: filter)
        guard !Task.isCancelled else { return }
        if let found {
            countries = filter.countries
            checkedIDs = []
            withAnimation(.snappy) {
                numbered = found.filter { TrainCandidateFinder.countryStatus($0, countries: filter.countries) != false }
                    .map { NumberedTrain(result: $0) }
                candidates = []
                searchedText = text
            }
            await checkRoute(of: numbered ?? [], stations: stations, target: target, date: date, countries: filter.countries)
            guard !Task.isCancelled else { return }
        } else {
            numbered = nil
        }
        let boards = await route
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) {
            // The runs listed by number aren't repeated from the boards.
            if let number, !(numbered ?? []).isEmpty {
                candidates = TrainCandidateFinder.boardExtras(boards, besides: number)
            } else {
                candidates = boards
            }
            searchedText = text
            isSearching = false
        }
    }

    /// Loads the stops of the runs found by number, to mark (and sort) the ones on the route.
    private func checkRoute(of trains: [NumberedTrain], stations: [Station], target: Station, date: Date,
                            countries: Set<String>) async {
        guard let finder, !trains.isEmpty else { return }
        isCheckingRoute = true
        defer { isCheckingRoute = false }
        await withTaskGroup(of: (String, RouteFit?).self) { group in
            for train in trains.prefix(Self.maxRouteChecks) {
                let result = train.result
                group.addTask { (result.id, await finder.routeFit(of: result, stations: stations, target: target, countries: countries)) }
            }
            for await (id, fit) in group {
                guard !Task.isCancelled, var list = numbered, let index = list.firstIndex(where: { $0.id == id }) else { continue }
                list[index].fit = fit
                checkedIDs.insert(id)
                withAnimation(.snappy) { numbered = TrainCandidateFinder.ranked(list, date: date) }
            }
        }
    }

    /// How many runs found by number get their stops loaded (one request each).
    private static let maxRouteChecks = 12

    // MARK: Picked

    @ViewBuilder
    private func pickedContent(_ candidate: TrainCandidate) -> some View {
        Button {
            withAnimation(.snappy) { picked = nil }
        } label: {
            Label("Anderen Zug wählen", systemImage: "chevron.left")
                .font(.subheadline.weight(.semibold))
        }
        .tint(.brand)

        Text(boardingID == nil
             ? "Tippe auf den Halt, an dem du einsteigst."
             : exitID == nil
                ? "Ohne Ausstieg suchen wir den schnellsten Weg zum Ziel. Tippe auf einen Halt, um dort auszusteigen."
                : "Ab dem Ausstieg suchen wir den schnellsten Weg zum Ziel.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

        addButton(candidate)

        TripContent(trip: candidate.trip, highlight: candidate.boarding?.station,
                    boardingID: $boardingID, exitID: $exitID)
    }

    private func addButton(_ candidate: TrainCandidate) -> some View {
        Button { add(candidate) } label: {
            Label("Zug vorgeben", systemImage: "pin.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(boardingID == nil)
    }

    /// Loads the picked run's trip, then shows its stops.
    private func pick(_ train: NumberedTrain) {
        guard let finder, loadingTrainID == nil else { return }
        loadingTrainID = train.id
        pickError = nil
        let target = search.to
        Task {
            defer { loadingTrainID = nil }
            do {
                pick(try await finder.candidate(for: train, target: target))
            } catch {
                withAnimation(.snappy) { pickError = error }
            }
        }
    }

    private func pick(_ candidate: TrainCandidate) {
        focused = nil
        boardingID = candidate.boarding?.id
        exitID = candidate.exit?.id
        withAnimation(.snappy) { picked = candidate }
    }

    private func add(_ candidate: TrainCandidate) {
        let trip = candidate.trip
        guard let boarding = trip.stopovers.first(where: { $0.id == boardingID }) else { return }
        let exit = trip.stopovers.first { $0.id == exitID }
        onAdd(TrainRequirement(trainName: trip.line?.name ?? trimmed, boarding: boarding.station,
                               exit: exit?.station, tripId: trip.id, tripSource: trip.source))
        dismiss()
    }

    private func addTyped() {
        guard !trimmed.isEmpty, let boarding = boardingStation else { return }
        onAdd(TrainRequirement(trainName: trimmed, boarding: boarding, exit: exitStation))
        dismiss()
    }
}
