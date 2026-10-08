import BetterBahnKit
import SwiftUI

/// Collects one "ride this train" requirement (#225): typing a name or number ("ICE 91", "RE 3",
/// "3300") lists the fitting trains from the route's stations, the ones going to the destination
/// first. Picking one shows its stops with boarding and exit already chosen; tapping stops changes
/// them. The route itself is planned by the caller once the sheet is done.
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
    @State private var isSearching = false
    /// The train search (by number) is still adding runs to the list.
    @State private var isSearchingMore = false
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
                    .onSubmit { if let first = candidates.first { pick(first) } }
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
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Suche Züge …").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            ForEach(candidates) { candidate in
                Button { pick(candidate) } label: { candidateRow(candidate) }
                    .buttonStyle(.plain)
            }
            if isSearchingMore, !isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Suche weitere Züge mit dieser Nummer …").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            if !isSearching, !isSearchingMore, searchedText == trimmed, candidates.isEmpty {
                ContentUnavailableView("Kein passender Zug", systemImage: "tram.fill",
                                       description: Text("Auf deiner Strecke fährt um diese Zeit kein Zug „\(trimmed)“. Du kannst Ein- und Ausstieg auch selbst angeben."))
            }
            if !isSearching, !isSearchingMore, searchedText == trimmed { manualEntry }
        }
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
        guard !text.isEmpty, let finder else {
            candidates = []
            searchedText = ""
            isSearching = false
            isSearchingMore = false
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        isSearchingMore = true
        let stations = stations, target = search.to, date = date
        // Trains on the route's boards show first; runs found by number join once the slower train search is done.
        async let byNumber = finder.numberCandidates(for: text, stations: stations, target: target, date: date)
        let route = await finder.routeCandidates(for: text, stations: stations, target: target, date: date)
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) {
            candidates = route
            searchedText = text
            isSearching = false
        }
        let more = await byNumber
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) {
            candidates = TrainCandidateFinder.merged(route, more, target: target, date: date)
            isSearchingMore = false
        }
    }

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
