import BetterBahnKit
import SwiftUI

/// Re-plans a journey from a train you are riding: pick which train to leave (and where to get
/// off), adjust the vehicle types, via stops and the final destination, optionally pin a specific
/// train for the rest of the way, then search onwards. Applying keeps everything up to the new exit
/// and appends the chosen continuation – the same shape (and the same cards) as the alternative
/// search after a missed transfer.
struct JourneyReplanSheet: View {
    let journey: Journey
    /// The leg the user tapped. `nil` opens the sheet on the whole journey, where the train to
    /// leave is picked here instead – the exit stays as planned until it is changed by hand.
    let startLeg: Leg?
    let finalDestination: Station
    /// Options the journey was searched with, so they can be edited instead of set up again.
    var search: ConnectionSearch?
    let onApply: (Journey) -> Void

    init(journey: Journey, startLeg: Leg? = nil, finalDestination: Station,
         search: ConnectionSearch? = nil, onApply: @escaping (Journey) -> Void) {
        self.journey = journey
        self.startLeg = startLeg
        self.finalDestination = finalDestination
        self.search = search
        self.onApply = onApply
        _selectedLegID = State(initialValue: (startLeg ?? journey.transitLegs.first)?.id)
        // Opened from a train: the exit is what this is about, so its stop list starts open.
        _showStops = State(initialValue: startLeg != nil)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLegID: String?
    @State private var trip: Trip?
    @State private var tripError: Error?
    @State private var boardingID: String?
    @State private var exitID: String?
    @State private var showStops: Bool

    @State private var destination: Station?
    @State private var viaRows: [ViaRow] = []
    @State private var products = Set(Product.allCases)
    @State private var maxTransfers: Int?
    @State private var onlyBC100 = false
    @State private var minTransferMinutes = defaultTransferMinutes
    @State private var showProductsPopover = false
    @State private var showBufferPopover = false
    @FocusState private var focused: Field?

    /// Trains the continuation has to use, in ride order (same idea as in the results view).
    @State private var requirements: [TrainRequirement] = []
    @State private var resolvedTrainNames: [UUID: String] = [:]
    @State private var breaksBoardingRules = false
    @State private var showTrainSheet = false

    /// A faster way to the goal that gets off somewhere else – offered as a note, never forced.
    @State private var fasterOption: ExitOption?
    @State private var isScanningExits = false

    @State private var results: [Journey] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var error: Error?
    @State private var applyingID: String?

    /// Set once the new route was applied; the sheet then wraps up with the Träwelling step.
    @State private var appliedExit: Leg?
    @State private var appliedJourney: Journey?
    @State private var isLookingUpCheckin = false
    @State private var checkinToFix: TraewellingStatus?
    @State private var isFixingCheckin = false
    @State private var checkinFixed = false
    @State private var checkinError: Error?

    enum Field: Hashable {
        case destination, via(UUID)
    }

    /// Up to this many intermediate stops can be added, matching the normal search.
    private static let maxViaPoints = 4

    /// Default buffer between getting off and the next departure. Anything longer is a break the
    /// user asked for, so the plan isn't argued against in that case.
    private static let defaultTransferMinutes = 5

    /// How much later than the original plan a re-planned arrival has to be before it's worth
    /// pointing out that staying on the train gets there sooner.
    private static let noticeableDelay: TimeInterval = 10 * 60

    /// The train the journey is re-planned from.
    private var leg: Leg {
        if let selectedLegID, let match = journey.legs.first(where: { $0.id == selectedLegID }) { return match }
        return startLeg ?? journey.transitLegs.first ?? journey.legs[0]
    }

    /// Where that leg sits in the current journey, `nil` once it is no longer part of it.
    private var legIndex: Int? { journey.legs.firstIndex { $0.id == leg.id } }

    // MARK: Derived state

    private var shownTrip: Trip? { trip ?? legTrip }

    /// Stand-in built from the leg's own stops, so the exit can be picked before (or without) the
    /// full trip having loaded.
    private var legTrip: Trip? {
        guard leg.stopovers.count > 1 else { return nil }
        return Trip(id: leg.tripId ?? leg.id, line: leg.line, direction: leg.direction,
                    stopovers: leg.stopovers, cancelled: leg.cancelled, remarks: leg.remarks, source: leg.source)
    }

    private var exitStop: Stopover? { shownTrip?.stopovers.first { $0.id == exitID } }
    private var exitStation: Station { exitStop?.station ?? leg.destination }
    private var exitArrival: Date { exitStop?.arrival?.best ?? leg.arrival.best }
    private var exitChanged: Bool { !exitStation.isSamePlace(as: leg.destination) }

    /// The ride as it would be with the new exit.
    private var exitLeg: Leg? {
        guard exitChanged else { return leg }
        return shownTrip?.leg(from: leg.origin, to: exitStation)
    }

    private var target: Station { destination ?? finalDestination }

    /// Whether the user asked to spend time somewhere – then a later arrival is the point, not a problem.
    private var wantsToLinger: Bool {
        minTransferMinutes > Self.defaultTransferMinutes || viaRows.contains { $0.minStayMinutes > 0 }
    }

    /// How much later than the current plan the best option on screen reaches the goal, if that is
    /// worth mentioning. Only applies while the goal itself is unchanged – with a new goal there is
    /// nothing to compare against.
    private var timeLostVersusPlan: TimeInterval? {
        guard target.isSamePlace(as: finalDestination), !wantsToLinger,
              journey.legs.last?.destination.isSamePlace(as: finalDestination) == true,
              let planned = journey.arrival?.best else { return nil }
        let arrivals = results.compactMap { $0.arrival?.best } + [fasterOption?.arrival].compactMap { $0 }
        guard let best = arrivals.min() else { return nil }
        let lost = best.timeIntervalSince(planned)
        return lost >= Self.noticeableDelay ? lost : nil
    }

    /// No continuation is needed when the new exit is already the destination.
    private var endsAtExit: Bool { exitStation.isSamePlace(as: target) && viaRows.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let appliedJourney, let appliedExit {
                        appliedContent(appliedJourney, exit: appliedExit)
                    } else {
                        configureContent
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background { AppBackground() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: appliedJourney == nil ? .cancellationAction : .confirmationAction) {
                    if appliedJourney == nil {
                        Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                    } else {
                        Button("Fertig", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
            .task { await setUp() }
            .task(id: selectedLegID) { await loadSelectedLeg() }
            .sheet(isPresented: $showTrainSheet) {
                TrainNumberSheet(search: continuationSearch, suggestions: trainSuggestions,
                                 defaultBoarding: requirements.last?.exit ?? exitStation) { requirement in
                    requirements.append(requirement)
                    Task { await runSearch() }
                }
            }
        }
    }

    private var navigationTitle: String {
        if appliedJourney != nil { return "Route geändert" }
        return startLeg == nil ? "Reise bearbeiten" : "Ausstieg wechseln"
    }

    /// The remaining route as a normal search, for the sheets that take one.
    private var continuationSearch: ConnectionSearch {
        ConnectionSearch(from: exitStation, to: target, via: viaRows.waypoints(), date: exitArrival,
                         isArrival: false, onlyBC100: onlyBC100, products: products, maxTransfers: maxTransfers)
    }

    // MARK: Configure

    @ViewBuilder
    private var configureContent: some View {
        if journey.transitLegs.count > 1 { legPicker }
        exitCard
        routeCard
        optionsCard
        trainBar
        if !requirements.isEmpty {
            requirementList
            if breaksBoardingRules {
                warningBanner("Ein- oder Ausstieg an einer gewählten Station ist laut Fahrplan nicht vorgesehen (Nur Einstieg/Nur Ausstieg).")
            }
        }
        if let error { ErrorBanner(error: error) }
        searchOrApplyButton
        if isSearching {
            HStack(spacing: 10) {
                ProgressView()
                Text("Suche Verbindungen ab \(exitStation.displayName) …")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        if isScanningExits, !isSearching {
            HStack(spacing: 10) {
                ProgressView()
                Text("Prüfe, ob ein anderer Halt schneller ist …").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        if let timeLostVersusPlan { stayOnTrainNote(lost: timeLostVersusPlan) }
        if let fasterOption { fasterNote(fasterOption) }
        if !results.isEmpty {
            SectionHeader(title: "Weiterfahrt ab \(exitStation.displayName)", systemImage: "arrow.triangle.branch")
                .padding(.top, 4)
            ForEach(results) { option in
                Button {
                    apply(continuation: option)
                } label: {
                    JourneyCard(journey: option)
                        .opacity(applyingID == nil || applyingID == option.id ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(applyingID != nil)
            }
            Text("Der bisherige Reiseplan bleibt unter „Frühere Reisepläne“ erhalten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        } else if hasSearched, !isSearching, error == nil {
            ContentUnavailableView("Keine Weiterfahrt gefunden", systemImage: "tram.fill",
                                   description: Text("Mit diesen Filtern geht es ab \(exitStation.displayName) nicht weiter. Versuche andere Verkehrsmittel oder weniger Zwischenhalte."))
        }
    }

    /// Which train of the journey to leave – everything before it stays untouched.
    private var legPicker: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                OptionLabel(title: "Ab welchem Zug?", subtitle: "Alles davor bleibt unverändert", icon: "tram.fill")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(journey.transitLegs) { option in
                            let isOn = option.id == leg.id
                            Button {
                                withAnimation(.snappy) { selectedLegID = option.id }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.line?.name ?? "Zug").font(.caption.weight(.bold))
                                    Text("\(option.origin.displayName) → \(option.destination.displayName)")
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundStyle(isOn ? Color.white : Color.primary)
                                .background(isOn ? Color.brand : Color.secondary.opacity(0.15),
                                            in: .rect(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Pin a specific train for the rest of the way, exactly like the connection search does.
    private var trainBar: some View {
        HStack(spacing: 10) {
            Button {
                showTrainSheet = true
            } label: {
                Label(requirements.isEmpty ? "Bestimmten Zug wählen" : "Weiteren Zug vorgeben", systemImage: "number")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(.brand)

            if !requirements.isEmpty {
                Button {
                    withAnimation(.snappy) { resetRequirements() }
                } label: {
                    Label("Zurücksetzen", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.iconOnly)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Zugvorgaben zurücksetzen")
            }
        }
    }

    private var requirementList: some View {
        VStack(spacing: 8) {
            ForEach(requirements) { requirement in
                HStack(spacing: 10) {
                    IconTile(systemImage: "pin.fill", color: .brand, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resolvedTrainNames[requirement.id] ?? requirement.trainName.uppercased())
                            .font(.subheadline.weight(.semibold))
                        Text(requirement.exit.map { "ab \(requirement.boarding.displayName) → \($0.displayName)" }
                             ?? "ab \(requirement.boarding.displayName) → schnellster Weiterweg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        withAnimation(.snappy) { remove(requirement) }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zugvorgabe entfernen")
                }
                .padding(10)
                .background(Color.card, in: .rect(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(Color.slightDelay)
            Text(text).font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.slightDelay.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
    }

    /// Trains from the current results, as quick picks in the train sheet.
    private var trainSuggestions: [String] {
        var names: [String] = []
        for option in results.flatMap(\.transitLegs) where option.line?.product.isTrain == true {
            if let name = option.line?.name, !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(12))
    }

    private func remove(_ requirement: TrainRequirement) {
        requirements.removeAll { $0.id == requirement.id }
        results = []
        hasSearched = false
        if !requirements.isEmpty { Task { await runSearch() } }
    }

    private func resetRequirements() {
        requirements = []
        resolvedTrainNames = [:]
        breaksBoardingRules = false
        results = []
        hasSearched = false
        fasterOption = nil
    }

    /// A hint that the journey as planned is simply quicker – shown only while the goal is
    /// unchanged and no extra waiting time was asked for, since a break is a reason of its own.
    private func stayOnTrainNote(lost: TimeInterval) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(systemImage: "tram.fill", color: .slightDelay, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mit dem geplanten Zug bist du früher da").font(.headline).lineLimit(2)
                        Text(stayOnTrainSubtitle(lost: lost)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    dismiss()
                } label: {
                    Label("Reiseplan behalten", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(.brand)
                .controlSize(.large)
                Text("Nur ein Hinweis – du kannst unten trotzdem umplanen.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stayOnTrainSubtitle(lost: TimeInterval) -> String {
        let minutes = Int(lost / 60)
        guard let planned = journey.arrival?.best else { return "Umplanen kostet \(minutes) Min." }
        return "Bleibst du sitzen, bist du um \(planned.timeString) in \(finalDestination.displayName) – "
            + "\(minutes) Min. früher als jede Umplanung hier."
    }

    /// A hint that staying on (or leaving earlier) reaches the goal sooner than the chosen exit.
    /// Purely a suggestion – the user's own results stay listed below it.
    private func fasterNote(_ option: ExitOption) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(systemImage: "bolt.fill", color: .punctual, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.exit.station.isSamePlace(as: leg.destination)
                             ? "Im Zug bleiben bis \(option.exit.station.displayName)"
                             : "Schneller: Ausstieg in \(option.exit.station.displayName)")
                            .font(.headline)
                            .lineLimit(2)
                        Text(fasterSubtitle(option))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let continuation = option.continuation {
                    JourneyCard(journey: continuation)
                } else {
                    Text("Von dort ist es dein Ziel – keine Weiterfahrt nötig.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    apply(continuation: option.continuation, exit: option.ride)
                } label: {
                    Label("Diesen Weg nehmen", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.punctual)
                .controlSize(.large)
                .disabled(applyingID != nil)
                Text("Nur ein Vorschlag – deine eigene Auswahl bleibt unten stehen.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func fasterSubtitle(_ option: ExitOption) -> String {
        let arrival = "an \(option.arrival.timeString) in \(target.displayName)"
        guard let mine = results.compactMap({ $0.arrival?.best }).min() else { return arrival }
        let saved = Int(mine.timeIntervalSince(option.arrival) / 60)
        return saved > 0 ? "\(arrival) · \(saved) Min. früher" : arrival
    }

    /// The train with its stop list – tapping a stop moves the exit.
    private var exitCard: some View {
        VStack(spacing: 12) {
            Card {
                HStack(spacing: 12) {
                    IconTile(systemImage: "arrow.down.right.circle.fill", color: .brand, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ausstieg: \(exitStation.displayName)")
                            .font(.headline)
                            .lineLimit(2)
                        Text(exitChanged
                             ? "statt \(leg.destination.displayName) · an \(exitArrival.timeString)"
                             : "wie geplant · an \(exitArrival.timeString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.snappy) { showStops.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .rotationEffect(.degrees(showStops ? 180 : 0))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .circle)
                    .accessibilityLabel(showStops ? "Halteliste ausblenden" : "Anderen Halt wählen")
                }
            }

            if showStops {
                if let shownTrip {
                    TripContent(trip: shownTrip, highlight: leg.origin,
                                boardingID: $boardingID, exitID: $exitID, exitOnly: true,
                                onSelectStop: { _ in exitPicked() })
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let tripError {
                    ErrorBanner(error: tripError)
                } else {
                    ProgressView("Lade Fahrtverlauf …")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
        }
    }

    /// Where the journey should go from the new exit, with the via points of the original search
    /// still editable.
    private var routeCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    IconTile(systemImage: "smallcircle.filled.circle", color: .secondary, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Weiter ab").font(.caption).foregroundStyle(.secondary)
                        Text(exitStation.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().padding(.leading, 54)

                ForEach($viaRows) { $row in
                    ViaRowView(row: $row, focus: $focused, focusValue: .via(row.id)) {
                        withAnimation(.snappy) { viaRows.removeAll { $0.id == row.id } }
                    }
                    Divider().padding(.leading, 54)
                }

                StationInput(label: "Ziel", placeholder: "Wohin?", systemImage: "mappin.circle.fill",
                             station: $destination, focus: $focused, focusValue: .destination)

                if viaRows.count < Self.maxViaPoints {
                    Divider().padding(.leading, 54)
                    Button {
                        withAnimation(.snappy) { viaRows.append(ViaRow()) }
                    } label: {
                        Label("Zwischenhalt hinzufügen", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .tint(.brand)
                }
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
    }

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    showBufferPopover = true
                } label: {
                    HStack {
                        OptionLabel(title: "Umstiegspuffer", subtitle: "\(minTransferMinutes) Min. nach der Ankunft",
                                    icon: "clock.badge.checkmark")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showBufferPopover) {
                    MinimumStayPopover(minutes: $minTransferMinutes, stationName: exitStation.displayName,
                                       isPresented: $showBufferPopover)
                }

                Divider()

                Toggle(isOn: $onlyBC100) {
                    OptionLabel(title: "Nur BahnCard 100", subtitle: "FlixTrain & Co. ausblenden", icon: "creditcard.fill")
                }
                .tint(.brand)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    OptionLabel(title: "Max. Umstiege", subtitle: "Weniger Umstiege, ggf. längere Fahrzeit",
                                icon: "arrow.triangle.swap")
                    MaxTransfersPicker(maxTransfers: $maxTransfers)
                }

                Button {
                    showProductsPopover = true
                } label: {
                    HStack {
                        OptionLabel(title: "Verkehrsmittel", subtitle: productSummary(products),
                                    icon: "train.side.front.car")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showProductsPopover) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Verkehrsmittel").font(.subheadline.weight(.semibold))
                        ProductChips(products: $products)
                        Button("Fertig") { showProductsPopover = false }
                            .buttonStyle(.glassProminent)
                            .tint(.brand)
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .frame(minWidth: 340)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    @ViewBuilder
    private var searchOrApplyButton: some View {
        if endsAtExit {
            VStack(spacing: 8) {
                Button {
                    apply(continuation: nil)
                } label: {
                    Group {
                        if applyingID != nil {
                            ProgressView()
                        } else {
                            Label("Reise hier beenden", systemImage: "flag.checkered")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .controlSize(.large)
                .disabled(applyingID != nil || exitLeg == nil || legIndex == nil)
                Text("\(exitStation.displayName) ist schon dein Ziel – es braucht keine Weiterfahrt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button {
                Task {
                    await runSearch()
                    await scanForFasterExit()
                }
            } label: {
                Label("Verbindungen suchen", systemImage: "magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.brand)
            .controlSize(.large)
            .disabled(isSearching || products.isEmpty || destination == nil
                      || viaRows.contains { $0.station == nil })
        }
    }

    // MARK: Applied

    @ViewBuilder
    private func appliedContent(_ updated: Journey, exit: Leg) -> some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.punctual.gradient)
                Text("Reiseplan aktualisiert").font(.headline)
                Text("Ausstieg in \(exit.destination.displayName) um \(exit.arrival.best.timeString).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }

        JourneyCard(journey: updated)

        if isLookingUpCheckin {
            HStack(spacing: 10) {
                ProgressView()
                Text("Prüfe deinen Träwelling-Check-in …").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let checkinError { ErrorBanner(error: checkinError) }

        if checkinFixed {
            Card {
                HStack(spacing: 12) {
                    IconTile(systemImage: "checkmark.seal.fill", color: .punctual, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check-in angepasst").font(.headline)
                        Text("Dein Träwelling-Check-in endet jetzt in \(exit.destination.displayName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else if let status = checkinToFix {
            checkinSuggestion(status, exit: exit)
        }
    }

    private func checkinSuggestion(_ status: TraewellingStatus, exit: Leg) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(systemImage: "checkmark.seal.fill", color: .brand, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Träwelling-Check-in anpassen?").font(.headline)
                        Text("Du bist bis \(checkedInDestinationName(status)) eingecheckt, steigst jetzt aber in \(exit.destination.displayName) aus.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    fixCheckin(status, exit: exit)
                } label: {
                    Group {
                        if isFixingCheckin {
                            ProgressView()
                        } else {
                            Label("Ausstieg auf \(exit.destination.displayName) ändern", systemImage: "arrow.down.right.circle.fill")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .controlSize(.large)
                .disabled(isFixingCheckin)
            }
        }
    }

    private func checkedInDestinationName(_ status: TraewellingStatus) -> String {
        if let station = status.journey(geometry: nil)?.legs.first?.destination { return station.displayName }
        let stop = status.checkin.destination
        return stop.station?.name ?? stop.name ?? "?"
    }

    /// A hand-picked exit invalidates results found for the previous one.
    private func exitPicked() {
        withAnimation(.snappy) {
            showStops = false
            results = []
            hasSearched = false
            fasterOption = nil
        }
    }

    // MARK: Actions

    private func setUp() async {
        destination = finalDestination
        viaRows = (search?.via ?? []).map(ViaRow.init)
        products = search?.products ?? Set(Product.allCases)
        maxTransfers = search?.maxTransfers
        onlyBC100 = search?.onlyBC100 ?? model.settings.onlyBC100ByDefault
        // Via stops already passed are no longer part of the remaining route.
        let ridden = journey.legs.prefix((legIndex ?? 0) + 1)
        viaRows.removeAll { row in
            guard let station = row.station else { return false }
            return ridden.contains { $0.destination.isSamePlace(as: station) }
        }
    }

    /// Starts over for the train that is now selected.
    private func loadSelectedLeg() async {
        trip = nil
        tripError = nil
        exitID = nil
        results = []
        hasSearched = false
        fasterOption = nil
        resetRequirements()
        seedStops(in: legTrip)
        await loadTrip()
    }

    /// Picks the boarding and exit stop of the current plan in `trip`'s stop list.
    private func seedStops(in trip: Trip?) {
        guard let trip else { return }
        boardingID = trip.stopovers.first { $0.station.isSamePlace(as: leg.origin) }?.id
        if exitID == nil || !trip.stopovers.contains(where: { $0.id == exitID }) {
            exitID = trip.stopovers.last { $0.station.isSamePlace(as: leg.destination) }?.id
        }
    }

    private func loadTrip() async {
        guard let tripId = leg.tripId else { return }
        do {
            let loaded = try await model.provider.trip(id: tripId, source: leg.source)
            var fresh = loaded
            if let timetables = model.timetablesClient {
                fresh = await timetables.tripWithRealtime(loaded)
            }
            // The full trip has different stop IDs than the leg's own stops – re-seed against it.
            let keptExit = exitStation
            trip = fresh
            boardingID = fresh.stopovers.first { $0.station.isSamePlace(as: leg.origin) }?.id
            exitID = fresh.stopovers.last { $0.station.isSamePlace(as: keptExit) }?.id
            tripError = nil
        } catch is CancellationError {
        } catch {
            tripError = error
        }
    }

    private func runSearch() async {
        guard let destination else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            var found: [Journey]
            if requirements.isEmpty {
                let options = ReplanOptions(destination: destination, via: viaRows.waypoints(),
                                            products: products, maxTransfers: maxTransfers,
                                            minTransferMinutes: minTransferMinutes)
                found = try await model.journeyReplanner.continuations(
                    from: exitStation, arriving: exitArrival, options: options)
                if onlyBC100 { found = found.filter(model.bc100Rules.isValid) }
            } else {
                // A pinned train decides the route; via stops and vehicle filters don't apply to it.
                let departAfter = exitArrival.addingTimeInterval(TimeInterval(minTransferMinutes * 60))
                let plan = try await model.trainRoutePlanner.plan(
                    requirements, from: exitStation, to: destination, date: departAfter)
                resolvedTrainNames = plan.resolvedNames
                breaksBoardingRules = plan.breaksBoardingRules
                found = plan.journeys.filter { ($0.departure?.best ?? .distantPast) >= exitArrival }
                if onlyBC100 {
                    // Don't leave the user with nothing if the pinned train itself isn't BC100 valid.
                    let valid = found.filter(model.bc100Rules.isValid)
                    if !valid.isEmpty { found = valid }
                }
            }
            withAnimation(.snappy) {
                results = found
                hasSearched = true
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error
            hasSearched = true
        }
    }

    /// Looks for a stop that reaches the goal sooner than the one the user picked – e.g. a new goal
    /// that lies before the planned exit, where riding on and coming back costs time. Only stops the
    /// train hasn't passed yet are considered, so a station already left is never proposed.
    private func scanForFasterExit() async {
        fasterOption = nil
        guard requirements.isEmpty, let destination, let trip = shownTrip else { return }
        isScanningExits = true
        defer { isScanningExits = false }
        let options = ReplanOptions(destination: destination, via: viaRows.waypoints(),
                                    products: products, maxTransfers: maxTransfers,
                                    minTransferMinutes: minTransferMinutes)
        let found = await model.journeyReplanner.exitOptions(
            on: trip, boardingAt: leg.origin, notBefore: .now, options: options)
        guard let best = found.first(where: { !$0.exit.station.isSamePlace(as: exitStation) }) else { return }
        // With results of their own, only a noticeably earlier arrival is worth interrupting for.
        if let mine = results.compactMap({ $0.arrival?.best }).min(),
           best.arrival > mine.addingTimeInterval(-JourneyReplanner.worthMentioning) { return }
        withAnimation(.snappy) { fasterOption = best }
    }

    private func apply(continuation: Journey?, exit overrideExit: Leg? = nil) {
        guard let exit = overrideExit ?? exitLeg, let index = legIndex else {
            error = TransitError.notFound("Diese Teilstrecke im Reiseplan")
            return
        }
        applyingID = continuation?.id ?? "end"
        let updated = JourneyReplanner.rebuild(journey, replacingLegAt: index, with: exit,
                                               continuation: continuation)
        let reason = exitChanged ? "Ausstieg in \(exit.destination.displayName)" : "Route neu geplant"
        if let entry = model.savedEntry(for: journey) {
            model.replaceSaved(id: entry.id, with: updated, reason: reason, search: updatedSearch)
        }
        onApply(updated)
        applyingID = nil
        withAnimation(.snappy) {
            appliedExit = exit
            appliedJourney = updated
        }
        Task { await lookUpCheckin(exit: exit) }
    }

    /// The search options as they now stand, stored with the journey for the next re-plan.
    private var updatedSearch: ConnectionSearch? {
        guard let destination, var updated = search else { return nil }
        updated.to = destination
        updated.via = viaRows.waypoints()
        updated.products = products
        updated.maxTransfers = maxTransfers
        updated.onlyBC100 = onlyBC100
        return updated
    }

    /// Checks whether a Träwelling check-in on this train now ends somewhere the user isn't going.
    private func lookUpCheckin(exit: Leg) async {
        guard await model.traewelling.isLoggedIn, !exit.destination.isSamePlace(as: leg.destination) else { return }
        isLookingUpCheckin = true
        defer { isLookingUpCheckin = false }
        guard let status = try? await model.traewelling.checkin(matching: leg),
              let checkedIn = status.journey(geometry: nil)?.legs.first,
              !checkedIn.destination.isSamePlace(as: exit.destination) else { return }
        withAnimation(.snappy) { checkinToFix = status }
    }

    private func fixCheckin(_ status: TraewellingStatus, exit: Leg) {
        isFixingCheckin = true
        Task {
            defer { isFixingCheckin = false }
            do {
                try await model.traewelling.changeDestination(of: status, to: exit.destination,
                                                              arrival: exit.arrival.planned)
                model.updateTrackedCheckin(statusId: status.id, leg: exit)
                withAnimation(.bouncy) {
                    checkinFixed = true
                    checkinToFix = nil
                }
                checkinError = nil
            } catch {
                checkinError = error
            }
        }
    }
}
