import BetterBahnKit
import Foundation
import SwiftUI
import UIKit

/// Generic stop-type suffixes ("Bhf", "Hbf", …) stripped when comparing station names, so "Bernau"
/// and "Bernau Bhf" are recognized as needing to be told apart while "Bernau a. Chiemsee" – whose
/// name already carries real place info beyond a generic suffix – isn't flagged unnecessarily.
private let genericSuffixWords: Set<String> = ["bhf", "hbf", "bahnhof"]

/// Inline station text field. While focused it shows up to 5 suggestions directly below
/// (favorites and recent stations when empty, search results while typing).
struct StationInput<Focus: Hashable>: View {
    let label: String
    let placeholder: String
    let systemImage: String
    var iconColor: Color = .brand
    @Binding var station: Station?
    let focus: FocusState<Focus?>.Binding
    let focusValue: Focus

    @Environment(AppModel.self) private var model
    @Environment(\.stationSearchArea) private var searchArea
    @Environment(\.calmDesign) private var calm
    @Environment(\.cardSurface) private var cardSurface
    @Environment(\.ticketStationFields) private var ticketStyle
    /// This field's key in `searchArea`.
    @State private var areaID = UUID()
    @State private var query = ""
    /// A shortcut ("b", "t", "l") was used once, so the tip explaining them isn't needed any more.
    @AppStorage("usedStationSearchShortcuts") private var usedShortcuts = false
    @State private var results: [Station] = []
    @State private var isSearching = false
    @State private var error: Error?
    /// Enter was pressed before results arrived – pick the first one once they do.
    @State private var submitPending = false
    /// Whether the suggestions are on screen. Follows focus, but stays a moment after focus is lost
    /// without a pick: a touch on a suggestion can end the editing (the scroll view dismissing the
    /// keyboard) before the finger is lifted, and if the list collapsed or changed right away, lifting
    /// it would tap whatever slid underneath – often a different station.
    @State private var showsSuggestions = false
    /// RIL100 codes of the suggestions (by `Station.id`), looked up off the main thread.
    @State private var codes: [String: String] = [:]

    /// How long the suggestions stay after focus is lost without a pick.
    static var suggestionsLinger: Duration { .milliseconds(600) }

    private var isFocused: Bool { focus.wrappedValue == focusValue }

    /// `query` without its shortcuts ("b", "t", "l", see `StationSearch`).
    private var search: StationSearch { StationSearch(parsing: query) }

    /// Enough typed (shortcuts aside) to search.
    private var isTyping: Bool { search.text.count >= 2 }

    private var suggestions: [Station] {
        if isTyping { return Array(search.filtered(results).prefix(5)) }
        var seen: [Station] = []
        for s in model.favoriteStations + model.recentStations where !seen.contains(where: { $0.isSamePlace(as: s) }) {
            seen.append(s)
        }
        return Array(seen.prefix(5))
    }

    /// The suggestions whose RIL100 codes are shown; nil with the codes off.
    private var codeLookup: [String]? {
        model.settings.ril100Enabled ? suggestions.map(\.id) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    // Covers the line a calm route card draws between its stops.
                    .background(Circle().fill(calm ? cardSurface : .clear).padding(-2))
                    .frame(width: 24)
                    .anchorPreference(key: RouteMarkerKey.self, value: .center) { [$0] }
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(ticketStyle ? .caption2.weight(.semibold) : .caption)
                        .tracking(ticketStyle ? 0.6 : 0)
                        .textCase(ticketStyle ? .uppercase : nil)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                    TextField(placeholder, text: $query)
                        .font(ticketStyle ? .title2.weight(.bold) : .headline)
                        .focused(focus, equals: focusValue)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit {
                            if isTyping, isSearching || results.isEmpty {
                                submitPending = true
                                focus.wrappedValue = focusValue
                            } else if let first = suggestions.first {
                                select(first)
                            }
                        }
                }
                if isSearching, showsSuggestions {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty, showsSuggestions {
                    Button("Leeren", systemImage: "xmark.circle.fill") {
                        query = ""
                        station = nil
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // The whole row opens the search, not just the text line: taps on the icon, the label
            // and the padding land here. Behind the row, so the text field keeps its own taps.
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { focus.wrappedValue = focusValue }
            }

            if showsSuggestions {
                suggestionList
                    // Only fades: sliding up on removal would pass over the buttons and fields above.
                    .transition(.opacity)
            }
        }
        .preference(key: StationSuggestionsShownKey.self, value: showsSuggestions)
        .onGeometryChange(for: CGRect.self) { [space = searchArea?.coordinateSpace] proxy in
            space.map { proxy.frame(in: .named($0)) } ?? .zero
        } action: { frame in
            searchArea?.frames[areaID] = frame
        }
        .onChange(of: isFocused, initial: true) { _, focused in
            if focused {
                searchArea?.focused.insert(areaID)
                searchArea?.closedByOutsideTap = false
            } else {
                searchArea?.focused.remove(areaID)
            }
        }
        .onDisappear {
            searchArea?.frames[areaID] = nil
            searchArea?.focused.remove(areaID)
        }
        .animation(.snappy(duration: 0.25), value: showsSuggestions)
        .animation(.snappy(duration: 0.25), value: suggestions.map(\.id))
        .onAppear { query = station?.displayName ?? "" }
        .task {
            // The RIL100 list is large: load it before a typed code (searched with the codes off too)
            // or the first row needs it.
            await Ril100.preload()
        }
        .task(id: codeLookup) {
            // Off the main thread: the first lookup after launch waits for the list to load (#301).
            guard codeLookup != nil else { codes = [:]; return }
            let found = await Ril100.codes(for: suggestions)
            guard !Task.isCancelled else { return }
            codes = found
        }
        .onChange(of: station) { _, new in
            if !showsSuggestions { query = new?.displayName ?? "" }
        }
        .onChange(of: isFocused) { _, focused in
            guard focused, !showsSuggestions else { return }
            showsSuggestions = true
            // Nearer train stations come first in search, so get a location ready while typing.
            LocationService.shared.refresh()
            // Select all-ish behaviour: start fresh search when a station is set.
            if station != nil { query = "" }
        }
        .task(id: isFocused) {
            // Focus lost without a pick: keep the list (and its rows) as they are for a moment, so a
            // finger still on a suggestion picks that one when lifted, then close.
            guard !isFocused, showsSuggestions else { return }
            // Another field took the focus (a tap on it, not on a suggestion), or a tap outside the
            // fields closed the search: both close right away.
            if focus.wrappedValue == nil {
                if searchArea?.closedByOutsideTap == true {
                    searchArea?.closedByOutsideTap = false
                } else {
                    try? await Task.sleep(for: Self.suggestionsLinger)
                    guard !Task.isCancelled, !isFocused else { return }
                }
            }
            showsSuggestions = false
            if !submitPending { query = station?.displayName ?? "" }
        }
        .task(id: search) {
            let search = self.search
            guard showsSuggestions, search.text.count >= 2 else { results = []; return }
            if search.hasShortcuts { usedShortcuts = true }
            try? await Task.sleep(for: .milliseconds(250)) // debounce
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                results = try await model.provider.searchStations(search, near: LocationService.shared.coordinate)
                error = nil
                if submitPending, let first = results.first {
                    submitPending = false
                    select(first)
                }
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = error
            }
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        VStack(spacing: 0) {
            if search.hasShortcuts {
                shortcutChips
            }
            if let error, isTyping {
                Label(error.localizedDescription, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Color.heavyDelay)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(suggestions) { suggestion in
                Button {
                    select(suggestion)
                } label: {
                    HStack(spacing: 12) {
                        let favorite = model.isFavorite(suggestion)
                        Image(systemName: favorite ? "star.fill" : isTyping ? "building.2.fill" : "clock.arrow.circlepath")
                            .font(.subheadline)
                            .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                            .frame(width: 24)
                        rowLabel(for: suggestion)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        if model.settings.ril100Enabled, let code = codes[suggestion.id] {
                            Text(code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.up.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if isTyping, !isSearching, suggestions.isEmpty, error == nil {
                Label("Kein Bahnhof gefunden", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
            if query.isEmpty, !usedShortcuts {
                Text("Tipp: „b“ vor oder hinter dem Namen sucht Bushaltestellen, „t“ Trams, „l“ sortiert nach Entfernung.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.secondary.opacity(0.06))
    }

    /// Which shortcuts are active, so a typed "b" doesn't silently change the results.
    private var shortcutChips: some View {
        HStack(spacing: 6) {
            if search.modes.contains(.bus) {
                InfoChip(text: String(localized: "Bus"), systemImage: "bus.fill", tint: .brand)
            }
            if search.modes.contains(.tram) {
                InfoChip(text: String(localized: "Tram"), systemImage: "tram.fill", tint: .brand)
            }
            if search.byDistance {
                if LocationService.shared.coordinate == nil {
                    InfoChip(text: String(localized: "Standort unbekannt"), systemImage: "location.slash.fill")
                } else {
                    InfoChip(text: String(localized: "Nach Entfernung"), systemImage: "location.fill", tint: .brand)
                }
            }
            if let country = search.country {
                InfoChip(text: String(localized: "\(TrainSearchCountry.flag(forCode: country) ?? "") nur dieses Land"), systemImage: "flag.fill", tint: .brand)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Bold the part of the name that matches the query.
    private func highlighted(_ name: String) -> Text {
        let query = search.text
        guard query.count >= 2, let range = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name)
        }
        var attributed = AttributedString(name)
        if let attributedRange = Range(range, in: attributed) {
            attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    /// Station name plus, only when another visible suggestion would otherwise look the same,
    /// its region in parentheses – "Bernau (Bayern)" next to "Bernau (Brandenburg)" – the way DB's
    /// own timetables disambiguate same-named stations. Stations whose name is already distinct
    /// (e.g. "Bernau a. Chiemsee") are left alone.
    private func rowLabel(for suggestion: Station) -> Text {
        if isTyping, let flag = model.settings.stationFlagMode.flag(for: suggestion, home: Locale.current.region?.identifier) {
            return Text("\(flag) \(nameLabel(for: suggestion))")
        }
        return nameLabel(for: suggestion)
    }

    private func nameLabel(for suggestion: Station) -> Text {
        let query = search.text
        let displayName = suggestion.displayName
        guard let region = suggestion.region, needsRegion(suggestion) else {
            return highlighted(displayName)
        }
        let fullText = "\(displayName) (\(region))"
        var attributed = AttributedString(fullText)

        // Highlight query match in the main name part
        if query.count >= 2, let range = displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
            }
        }

        // Style region part in secondary color
        if let regionStart = fullText.range(of: " (\(region))") {
            if let attributedRange = Range(regionStart, in: attributed) {
                attributed[attributedRange].foregroundColor = .secondary
            }
        }

        return Text(attributed)
    }

    private func needsRegion(_ suggestion: Station) -> Bool {
        let key = Self.baseKey(suggestion.displayName)
        return suggestions.contains { $0.id != suggestion.id && Self.baseKey($0.displayName) == key }
    }

    private static func baseKey(_ name: String) -> String {
        name.lowercased().split(separator: " ")
            .filter { !genericSuffixWords.contains(String($0)) }
            .joined(separator: " ")
    }

    private func select(_ suggestion: Station) {
        // The list is already closed after a pick, but its rows stay on screen (and tappable) while
        // they fade out: a tap on the button next to them – "+" in the route card – must not pick
        // another station from them.
        guard showsSuggestions else { return }
        submitPending = false
        showsSuggestions = false
        station = suggestion
        query = suggestion.displayName
        model.rememberStation(suggestion)
        focus.wrappedValue = nil
    }
}

/// Whether any `StationInput` in the view shows its suggestions, so a screen can keep its layout
/// around the field still while it does (see `StationInput.showsSuggestions`).
nonisolated private struct TicketStationFieldsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Station fields drawn like a ticket's "Von" and "Nach": a small upper-case label over a large name.
    nonisolated var ticketStationFields: Bool {
        get { self[TicketStationFieldsKey.self] }
        set { self[TicketStationFieldsKey.self] = newValue }
    }
}

/// Centers of the station fields' icons, so a route card can join its stops with a line.
struct RouteMarkerKey: PreferenceKey {
    static let defaultValue: [Anchor<CGPoint>] = []
    static func reduce(value: inout [Anchor<CGPoint>], nextValue: () -> [Anchor<CGPoint>]) {
        value += nextValue()
    }
}

struct StationSuggestionsShownKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Where a screen's `StationInput`s are (field row plus suggestions) and which one has the focus,
/// so a tap anywhere else can close the search (see `closesStationSearchOnOutsideTap`). A plain
/// class: the frames change while scrolling and nothing needs to redraw for that.
final class StationSearchArea {
    let coordinateSpace = UUID()
    var frames: [UUID: CGRect] = [:]
    var focused: Set<UUID> = []
    /// The focus was just taken by a tap outside, so the suggestions close without lingering.
    var closedByOutsideTap = false
}

nonisolated private struct StationSearchAreaKey: EnvironmentKey {
    static let defaultValue: StationSearchArea? = nil
}

extension EnvironmentValues {
    nonisolated var stationSearchArea: StationSearchArea? {
        get { self[StationSearchAreaKey.self] }
        set { self[StationSearchAreaKey.self] = newValue }
    }
}

extension View {
    /// Closes an open station search when the user taps anywhere outside the station fields and
    /// their suggestions. Taps on another station field are left to that field, which takes the focus.
    func closesStationSearchOnOutsideTap<Focus: Hashable>(_ focus: FocusState<Focus?>.Binding) -> some View {
        modifier(StationSearchOutsideTap(focus: focus))
    }
}

private struct StationSearchOutsideTap<Focus: Hashable>: ViewModifier {
    let focus: FocusState<Focus?>.Binding
    @State private var area = StationSearchArea()

    func body(content: Content) -> some View {
        content
            .environment(\.stationSearchArea, area)
            .coordinateSpace(.named(area.coordinateSpace))
            .background {
                WindowTapObserver { location in
                    // Only a station field's focus: other text fields on the screen keep theirs.
                    guard !area.focused.isEmpty, !area.frames.values.contains(where: { $0.contains(location) }) else { return }
                    area.closedByOutsideTap = true
                    focus.wrappedValue = nil
                }
            }
    }
}

/// Reports every tap in the window, in this view's coordinates, without taking it from anything:
/// buttons, text fields and scrolling get their touches as before and without delay.
private struct WindowTapObserver: UIViewRepresentable {
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onTap = onTap
    }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var onTap: ((CGPoint) -> Void)?

        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            window?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            onTap?(recognizer.location(in: self))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Time button with a clock icon: the label opens a date picker, the clock resets to now.
struct TimeSelector: View {
    @Binding var date: Date
    @Binding var useNow: Bool
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    useNow = true
                    date = .now
                }
            } label: {
                Image(systemName: useNow ? "clock.fill" : "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(useNow ? Color.brand : Color.secondary)
                    .frame(width: 36, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auf jetzt setzen")

            Divider().frame(height: 18)

            Button {
                showPicker = true
            } label: {
                Text(useNow ? String(localized: "Jetzt") : Self.label(for: date))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .frame(height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .background(Color.brand.opacity(0.1), in: .capsule)
        .popover(isPresented: $showPicker) {
            VStack(spacing: 12) {
                DatePicker("Zeit", selection: Binding(get: { date }, set: { date = $0; useNow = false }))
                    .datePickerStyle(.graphical)
                    .tint(.brand)
                HStack {
                    Button {
                        useNow = true
                        date = .now
                        showPicker = false
                    } label: {
                        Label("Jetzt", systemImage: "clock.fill")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Fertig") { showPicker = false }
                        .buttonStyle(.glassProminent)
                }
                .tint(.brand)
            }
            // The graphical picker has no ideal width of its own, so a popover (wide screens) squeezes it.
            .frame(minWidth: 320, idealWidth: 340)
            .padding()
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.height(500)])
        }
    }

    /// The time alone today, else with the day.
    static func label(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
