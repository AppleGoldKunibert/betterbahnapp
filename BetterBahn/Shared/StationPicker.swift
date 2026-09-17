import BetterBahnKit
import Foundation
import SwiftUI

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
    @State private var results: [Station] = []
    @State private var isSearching = false
    @State private var error: Error?
    /// Enter was pressed before results arrived – pick the first one once they do.
    @State private var submitPending = false

    private var isFocused: Bool { focus.wrappedValue == focusValue }

    private var suggestions: [Station] {
        if query.count >= 2 { return Array(results.prefix(5)) }
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
                            if query.count >= 2, isSearching || results.isEmpty {
                                submitPending = true
                                focus.wrappedValue = focusValue
                            } else if let first = suggestions.first {
                                select(first)
                            }
                        }
                }
                if isSearching, isFocused {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty, isFocused {
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

            if isFocused {
                suggestionList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: isFocused)
        .animation(.snappy(duration: 0.25), value: suggestions.map(\.id))
        .onAppear { query = station?.displayName ?? "" }
        .onChange(of: station) { _, new in
            if !isFocused { query = new?.displayName ?? "" }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                // Select all-ish behaviour: start fresh search when a station is set.
                if station != nil { query = "" }
            } else if !submitPending {
                query = station?.displayName ?? ""
            }
        }
        .task(id: query) {
            guard isFocused, query.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(250)) // debounce
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                results = try await model.provider.searchStations(query)
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
            if let error, query.count >= 2 {
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
                        Image(systemName: favorite ? "star.fill" : query.count >= 2 ? "building.2.fill" : "clock.arrow.circlepath")
                            .font(.subheadline)
                            .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                            .frame(width: 24)
                        highlighted(suggestion.displayName)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
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
            if query.count >= 2, !isSearching, suggestions.isEmpty, error == nil {
                Label("Kein Bahnhof gefunden", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
        }
        .background(Color.secondary.opacity(0.06))
    }

    /// Bold the part of the name that matches the query.
    private func highlighted(_ name: String) -> Text {
        guard query.count >= 2, let range = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name)
        }
        var attributed = AttributedString(name)
        if let attributedRange = Range(range, in: attributed) {
            attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    private func select(_ suggestion: Station) {
        submitPending = false
        station = suggestion
        query = suggestion.displayName
        model.rememberStation(suggestion)
        focus.wrappedValue = nil
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
            .presentationDetents([.medium, .large])
        }
    }

    private var label: String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
