import BetterBahnKit
import SwiftUI

/// Finds a train by its number (#183), Spotlight-style: a search bar in the middle of the screen over
/// whatever is showing, the day behind a small calendar button, the trains found right below. Opened
/// from the train button on Verbindungen and the search button on the map (`AppModel.showsTrainSearch`);
/// lists only the kinds of trains and countries picked in Settings → Zugschnellsuche.
struct TrainSearchOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var date = Date.now
    @State private var showsCalendar = false
    /// What was last searched for; changing it starts a new search (and cancels the running one).
    @State private var submitted: Submitted?
    @State private var results: [TrainSearchResult]?
    @State private var searching = false
    @State private var error: Error?
    @State private var selected: TrainSearchResult?
    @FocusState private var focused: Bool

    private struct Submitted: Equatable {
        var query: TrainNumberQuery
        var day: String
        var filter: TrainSearchFilter
        /// Bumped by the search key and "Erneut versuchen", so the same search runs again (e.g. after a network error).
        var attempt = 0

        func isSameSearch(as other: Submitted?) -> Bool {
            guard let other else { return false }
            return query == other.query && day == other.day && filter == other.filter
        }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    /// Only the bar, nothing below it: it sits in the middle, like Spotlight.
    private var isBarOnly: Bool { submitted == nil && !showsCalendar }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    bar
                    if showsCalendar {
                        calendar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if submitted != nil {
                        resultsPanel
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal)
                .padding(.top, isBarOnly ? max(16, geometry.size.height * 0.4 - 28) : geometry.size.height * 0.1)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                // Tapping anywhere outside the bar and the results closes the search.
                .contentShape(.rect)
                .onTapGesture(perform: close)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
        }
        .animation(.snappy, value: isBarOnly)
        .animation(.snappy, value: showsCalendar)
        .animation(.snappy, value: results)
        .onAppear { focused = true }
        .onChange(of: date) {
            showsCalendar = false
            submit(again: false)
        }
        .onChange(of: model.settings.trainSearchFilter) { submit(again: false) }
        .task(id: text) {
            // Searches while typing, once the typing pauses.
            guard TrainNumberQuery(text) != nil else {
                submitted = nil
                results = nil
                error = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            submit(again: false)
        }
        .task(id: submitted) { await search() }
        .sheet(item: $selected) { result in
            NavigationStack {
                TrainSearchResultView(result: result)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Schließen", systemImage: "xmark", role: .cancel) { selected = nil }
                        }
                    }
            }
        }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Zugnummer, z. B. ICE 123", text: $text)
                .font(.title3.weight(.medium))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { submit(again: true) }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Eingabe löschen")
            }
            Button {
                focused = false
                showsCalendar.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isToday ? "calendar" : "calendar.badge.clock")
                    if !isToday {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.caption.weight(.semibold))
                    }
                }
                .font(.title3)
                .foregroundStyle(showsCalendar || !isToday ? Color.brand : .secondary)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isToday ? "Tag wählen, heute" : "Tag wählen, \(date.formatted(date: .complete, time: .omitted))")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
        .onTapGesture { focused = true }
    }

    /// Full width below the bar, inside the scroll view, so the calendar is never cut off.
    private var calendar: some View {
        VStack(spacing: 4) {
            DatePicker("Tag", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(.brand)
            if !isToday {
                Button("Heute") { date = .now }
                    .font(.subheadline.weight(.semibold))
                    .tint(.brand)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .onTapGesture {}
    }

    // MARK: Results

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Suche Züge …").foregroundStyle(.secondary)
                }
                .padding(16)
            } else if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error.localizedDescription, systemImage: "exclamationmark.octagon.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.heavyDelay)
                    Button {
                        submit(again: true)
                    } label: {
                        Label("Erneut versuchen", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .tint(.brand)
                }
                .padding(16)
            } else if let results {
                if results.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kein passender Zug an diesem Tag.").font(.subheadline.weight(.semibold))
                        Text("Welche Zugarten und Länder die Suche zeigt, stellst du in den Einstellungen unter „Zugschnellsuche“ ein.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                } else {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        if index > 0 {
                            Divider().padding(.leading, 60)
                        }
                        Button {
                            focused = false
                            selected = result
                        } label: {
                            TrainSearchRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .onTapGesture {}
    }

    // MARK: Search

    /// - Parameter again: also when it is the same search as before (search key, "Erneut versuchen").
    private func submit(again: Bool) {
        guard let query = TrainNumberQuery(text) else { return }
        var next = Submitted(query: query, day: BahnDeClient.berlinDay(date), filter: model.settings.trainSearchFilter)
        if next.isSameSearch(as: submitted) {
            guard again else { return }
            next.attempt = (submitted?.attempt ?? 0) + 1
        }
        if again { focused = false }
        submitted = next
    }

    private func search() async {
        guard let submitted, let finder = TrainNumberSearch(provider: model.provider) else { return }
        searching = true
        error = nil
        defer { if !Task.isCancelled { searching = false } }
        do {
            let found = try await finder.trains(submitted.query, on: date, filter: submitted.filter)
            guard !Task.isCancelled else { return }
            results = found
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            results = nil
            self.error = error
        }
    }

    private func close() {
        focused = false
        model.showsTrainSearch = false
    }
}

/// One train found by its number: what it is and where it runs.
private struct TrainSearchRow: View {
    let result: TrainSearchResult

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: result.product.symbolName, color: result.product.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.name).font(.headline)
                    if let line = result.lineName {
                        InfoChip(text: line, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                Text("\(result.origin) → \(result.destination)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

/// What can be done with a train found by its number: its stops (to save the journey and check in),
/// its Wagenreihung and, while bahn.jetzt has it, its live position on the map.
struct TrainSearchResultView: View {
    let result: TrainSearchResult

    @Environment(AppModel.self) private var model
    @State private var entry: BoardEntry?
    @State private var trip: Trip?
    @State private var error: Error?
    /// bahn.de's sequence for the next stops, else vagonweb's plan; nil while checking or without one.
    @State private var sequence: CoachSequence?
    @State private var checkedSequence = false
    /// nil while checking.
    @State private var hasLivePosition: Bool?
    /// Wagenreihung opened or closed by hand; nil unfolds it around the departure (`CoachSequence.unfoldsByItself`).
    @State private var sequenceExpanded: Bool?
    @State private var showMap = false

    private var color: Color { trip?.line?.product.color ?? result.product.color }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error {
                    ErrorBanner(error: error)
                } else if let entry, let trip {
                    options(entry: entry, trip: trip)
                } else {
                    ProgressView("Lade Fahrt …")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(result.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMap) {
            if let trip {
                LiveTrainMapView(route: LiveTrainRoute(trip: trip))
            }
        }
        .task { await load() }
        .task(id: trip?.id) { await checkSequence() }
        .task(id: trip?.id) { await checkLivePosition() }
    }

    private var header: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(systemImage: (trip?.line?.product ?? result.product).symbolName, color: color, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    if let trip {
                        TrainNameRow(name: trip.line?.nameWithTripNumber ?? result.name, font: .title3.weight(.bold), spacing: 8) {
                            TrainSeriesTag(trip: trip, savedLeg: nil)
                        }
                    } else {
                        Text(result.name).font(.title3.weight(.bold))
                    }
                    Text("\(trip?.origin?.displayName ?? result.origin) → \(trip?.destination?.displayName ?? result.destination)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let departure = trip?.stopovers.lazy.compactMap(\.departure).first?.planned {
                        Text(departure.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func options(entry: BoardEntry, trip: Trip) -> some View {
        NavigationLink {
            TripView(entry: entry, selectsStation: false)
        } label: {
            OptionRow(title: "Zugdetails anzeigen", subtitle: "Alle Halte; Ein- und Ausstieg wählen, um die Fahrt zu speichern",
                      systemImage: "list.bullet.rectangle.portrait", color: .brand)
        }
        .buttonStyle(.plain)

        if let sequence, !sequence.coaches.isEmpty, let request = sequenceRequest(for: trip) {
            TimelineView(.everyMinute) { context in
                let departure = CoachSequenceDisclosure.departure(of: trip, for: request)
                let open = sequenceExpanded ?? CoachSequence.unfoldsByItself(departure: departure, now: context.date)
                VStack(spacing: 12) {
                    Button {
                        withAnimation(.snappy) { sequenceExpanded = !open }
                    } label: {
                        OptionRow(title: sequence.source == .bahnDe ? "Wagenreihung" : "Plan-Wagenreihung",
                                  subtitle: "Wagen, Klassen und Ausstattung",
                                  systemImage: "train.side.front.car", color: .brand,
                                  chevron: open ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(open ? "Ausgeklappt" : "Eingeklappt")
                    if open {
                        Card {
                            CoachSequencePanel(request: request, sequence: sequence)
                        }
                        .transition(.coachSequenceFold)
                    }
                }
            }
        } else if !checkedSequence {
            OptionRow(title: "Wagenreihung", subtitle: "Wird gesucht …", systemImage: "train.side.front.car",
                      color: .secondary, loading: true)
        } else {
            OptionRow(title: "Wagenreihung", subtitle: "Für diesen Zug gibt es keine Wagenreihung.",
                      systemImage: "train.side.front.car", color: .secondary, showsChevron: false)
        }

        switch hasLivePosition {
        case true?:
            Button {
                showMap = true
            } label: {
                OptionRow(title: "Auf Karte zeigen", subtitle: "Wo der Zug gerade ist",
                          systemImage: "location.fill", color: .brand)
            }
            .buttonStyle(.plain)
        case nil:
            OptionRow(title: "Auf Karte zeigen", subtitle: "Live-Position wird gesucht …", systemImage: "location.fill",
                      color: .secondary, loading: true)
        case false?:
            EmptyView()
        }
    }

    private func load() async {
        guard trip == nil, let finder = TrainNumberSearch(provider: model.provider) else { return }
        do {
            let run = try await finder.run(of: result)
            entry = run.entry
            trip = run.trip
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func sequenceRequest(for trip: Trip) -> BahnDeClient.FormationRequest? {
        BahnDeClient.formationRequest(for: trip) ?? BahnDeClient.formationRequest(for: trip, lookahead: nil)
    }

    /// The same lookup as `CoachSequenceDisclosure`: bahn.de's sequence within its lookahead, else the plan.
    private func checkSequence() async {
        guard let trip else { return }
        sequence = nil
        checkedSequence = false
        if let request = BahnDeClient.formationRequest(for: trip),
           let live = try? await model.coachSequence(for: request), !live.coaches.isEmpty {
            sequence = live
        } else if let planned = BahnDeClient.formationRequest(for: trip, lookahead: nil) {
            sequence = await model.plannedCoachSequence(for: planned)
        }
        guard !Task.isCancelled else { return }
        checkedSequence = true
    }

    /// Asks again now and then, like `LiveTrainIconTile`: a train only shows up in bahn.jetzt's list once it runs.
    private func checkLivePosition() async {
        guard let trip else { return }
        let route = LiveTrainRoute(trip: trip)
        guard route.isSupported else {
            hasLivePosition = false
            return
        }
        while !Task.isCancelled {
            if route.mayBeRunning() {
                let found = (try? await model.livePosition(of: route)) != nil
                guard !Task.isCancelled else { return }
                hasLivePosition = found
                if found { return }
            } else {
                hasLivePosition = false
                if Date.now > route.end { return }
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }
}

/// A tappable option on `TrainSearchResultView`.
private struct OptionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    var loading = false
    var showsChevron = true
    var chevron = "chevron.right"

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(systemImage: systemImage, color: color, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                        .foregroundStyle(color == .secondary ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if loading {
                    ProgressView().controlSize(.small)
                } else if showsChevron {
                    Image(systemName: chevron)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
