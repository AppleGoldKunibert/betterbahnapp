import BetterBahnKit
import Foundation
import SwiftUI

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

    /// How long the suggestions stay after focus is lost without a pick.
    static var suggestionsLinger: Duration { .milliseconds(600) }

    private var isFocused: Bool { focus.wrappedValue == focusValue }

    /// `query` without its shortcuts ("b", "t", "l", see `StationSearch`).
    private var search: StationSearch { StationSearch(parsing: query) }

    /// Enough typed (shortcuts aside) to search.
    private var isTyping: Bool { search.text.count >= 2 }

    private var suggestions: [Station] {
        if isTyping { return Array(results.prefix(5)) }
        var seen: [Station] = []
        for s in model.favoriteStations + model.recentStations where !seen.contains(where: { $0.isSamePlace(as: s) }) {
            seen.append(s)
        }
        return Array(seen.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(placeholder, text: $query)
                        .font(.headline)
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

            if showsSuggestions {
                suggestionList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .preference(key: StationSuggestionsShownKey.self, value: showsSuggestions)
        .animation(.snappy(duration: 0.25), value: showsSuggestions)
        .animation(.snappy(duration: 0.25), value: suggestions.map(\.id))
        .onAppear { query = station?.displayName ?? "" }
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
            // Another field took the focus: that was a tap on it, not on a suggestion.
            if focus.wrappedValue == nil {
                try? await Task.sleep(for: Self.suggestionsLinger)
                guard !Task.isCancelled, !isFocused else { return }
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
                        if model.settings.ril100Enabled, let code = Ril100.code(for: suggestion) {
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
                InfoChip(text: "Bus", systemImage: "bus.fill", tint: .brand)
            }
            if search.modes.contains(.tram) {
                InfoChip(text: "Tram", systemImage: "tram.fill", tint: .brand)
            }
            if search.byDistance {
                if LocationService.shared.coordinate == nil {
                    InfoChip(text: "Standort unbekannt", systemImage: "location.slash.fill")
                } else {
                    InfoChip(text: "Nach Entfernung", systemImage: "location.fill", tint: .brand)
                }
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
struct StationSuggestionsShownKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
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
                Text(useNow ? "Jetzt" : label)
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
            .padding()
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.height(500)])
        }
    }

    private var label: String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
