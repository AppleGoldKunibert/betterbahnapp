import BetterBahnKit
import SwiftUI

/// Upcoming saved journeys, shown below the connection search.
struct UpcomingTripsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let upcoming = model.upcomingJourneys
        VStack(alignment: .leading, spacing: 10) {
            FollowedCheckinsSection()
            SectionHeader(title: String(localized: "Deine Reisen"), systemImage: "bookmark.fill",
                          trailing: upcoming.isEmpty ? nil : "\(upcoming.count)")
            if upcoming.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        IconTile(systemImage: "bookmark", color: .secondary.opacity(0.6), size: 34)
                        Text("Hier erscheinen deine gespeicherten Reisen.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, entry in
                    SavedJourneyRow(entry: entry, isNext: index == 0)
                }
            }
        }
    }
}

extension SavedJourney {
    func route(readOnly: Bool = false) -> JourneyRoute {
        JourneyRoute(journey: journey,
                     finalDestination: journey.legs.last?.destination ?? journey.legs[0].destination,
                     readOnly: readOnly, search: search)
    }
}

struct SavedJourneyRow: View {
    let entry: SavedJourney
    var isNext = false
    var readOnly = false
    @Environment(AppModel.self) private var model
    @State private var journeyToRemove: Journey?

    var body: some View {
        let blocking = entry.issues.first(where: \.isBlocking)
        RouteLink(value: ConnectionsRoute.journey(entry.route(readOnly: readOnly))) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(dayLabel)
                    if isNext, model.liveActivities.isActive(entry.journey) {
                        Image(systemName: "bolt.badge.clock.fill").foregroundStyle(Color.brandText)
                    }
                    let tickets = model.tickets(for: entry)
                    if !tickets.isEmpty {
                        let onlyReservations = tickets.allSatisfy(\.ticket.isReservationOnly)
                        Image(systemName: onlyReservations ? "carseat.right.fill" : "ticket.fill").foregroundStyle(Color.brandText)
                            .accessibilityLabel(onlyReservations ? "Reservierung gespeichert" : "Ticket gespeichert")
                    }
                    Spacer()
                    if let first = entry.journey.legs.first, let last = entry.journey.legs.last {
                        Text("\(first.origin.displayName) → \(last.destination.displayName)").lineLimit(1)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

                JourneyCard(journey: entry.journey)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(blocking != nil ? Color.heavyDelay : (highlightsAsNext ? Color.brand : .clear), lineWidth: 2)
                    }

                if let blocking {
                    Label(blocking.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.heavyDelay)
                        .padding(.horizontal, 6)
                }
                if let claim = model.passengerRightsClaim(for: entry) {
                    PassengerRightsBadge(claim: claim)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reise löschen", systemImage: "trash", role: .destructive) {
                model.remove(entry.journey, askingToCheckOut: &journeyToRemove)
            }
        }
        .checkoutPrompt($journeyToRemove)
    }

    /// The next journey is only framed once it departs within the next 24 hours (or is already
    /// underway), so a trip days away doesn't look as urgent as a broken connection.
    private var highlightsAsNext: Bool {
        guard isNext, let departure = entry.journey.departure?.best else { return false }
        return departure <= Date.now.addingTimeInterval(24 * 3600)
    }

    private var dayLabel: String {
        guard let date = entry.journey.departure?.planned else { return "" }
        if Calendar.current.isDateInToday(date) { return String(localized: "Heute") }
        if Calendar.current.isDateInTomorrow(date) { return String(localized: "Morgen") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// The finished journeys, newest first, under a header per month. Minimal shows them like the upcoming ones,
/// Fahrkarte as small tickets like on the search page.
struct PastTripsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appDesign) private var design

    var body: some View {
        let months = Self.months(of: model.pastJourneys)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: design == .fahrkarte ? 8 : 12) {
                if months.isEmpty {
                    ContentUnavailableView("Keine vergangenen Fahrten", systemImage: "clock.arrow.circlepath")
                        .padding(.top, 60)
                }
                ForEach(months) { month in
                    SectionHeader(title: month.start.formatted(.dateTime.month(.wide).year()), systemImage: "calendar",
                                  trailing: "\(month.entries.count)")
                        .padding(.top, month.start == months.first?.start ? 0 : 16)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(month.entries) { entry in
                        if design == .fahrkarte {
                            PastTripTicket(entry: entry)
                        } else {
                            SavedJourneyRow(entry: entry, readOnly: true)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .tabBarSafePadding()
        .background { AppBackground() }
        .navigationTitle("Vergangene Fahrten")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The journeys by the month they departed in, keeping their order.
    private static func months(of entries: [SavedJourney]) -> [PastMonth] {
        var months: [PastMonth] = []
        let calendar = Calendar.current
        for entry in entries {
            let date = entry.journey.departure?.planned ?? .distantPast
            let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
            if let last = months.indices.last, months[last].start == start {
                months[last].entries.append(entry)
            } else {
                months.append(PastMonth(start: start, entries: [entry]))
            }
        }
        return months
    }
}

/// The past journeys of one month.
private struct PastMonth: Identifiable {
    let start: Date
    var entries: [SavedJourney]
    var id: Date { start }
}

/// A finished journey as a small ticket (Fahrkarte), matching the saved journeys on the search page: the day and
/// the trains above the perforation, the times and the route below. Opens the journey read-only.
private struct PastTripTicket: View {
    let entry: SavedJourney
    @Environment(AppModel.self) private var model
    @State private var journeyToRemove: Journey?

    private static let notchRadius: CGFloat = 7
    private static let cornerRadius: CGFloat = 18

    var body: some View {
        let journey = entry.journey
        let blocking = entry.issues.first(where: \.isBlocking)
        RouteLink(value: ConnectionsRoute.journey(entry.route(readOnly: true))) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                TicketPerforation(notchRadius: Self.notchRadius)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let departure = journey.departure {
                                TimeStack(time: departure, cancelled: journey.isCancelled, font: .title3.weight(.bold))
                            }
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            if let arrival = journey.arrival {
                                TimeStack(time: arrival, cancelled: journey.isCancelled, font: .title3.weight(.bold))
                            }
                        }
                        if let first = journey.legs.first, let last = journey.legs.last {
                            Text("\(first.origin.displayName) → \(last.destination.displayName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let blocking {
                            Label(blocking.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.heavyDelay)
                                .padding(.top, 4)
                        }
                        if let claim = model.passengerRightsClaim(for: entry) {
                            PassengerRightsBadge(claim: claim)
                                .padding(.horizontal, -6)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
            }
            .fontDesign(.rounded)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ticketBackground(notchRadius: Self.notchRadius, cornerRadius: Self.cornerRadius,
                              outline: blocking != nil ? Color.heavyDelay : Color.hairline,
                              outlineWidth: blocking != nil ? 2 : 1)
            .environment(\.cardSurface, Color.ticket)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reise löschen", systemImage: "trash", role: .destructive) {
                model.remove(entry.journey, askingToCheckOut: &journeyToRemove)
            }
        }
        .checkoutPrompt($journeyToRemove)
    }

    /// The day and, on the right, the trains ridden ("ICE 597 · RE 5").
    private var header: some View {
        let trains = entry.journey.legs.compactMap { $0.line?.name }
        return HStack(spacing: 6) {
            Text(dayLabel)
                .tracking(0.5)
                .textCase(.uppercase)
            let tickets = model.tickets(for: entry)
            if !tickets.isEmpty {
                let onlyReservations = tickets.allSatisfy(\.ticket.isReservationOnly)
                Image(systemName: onlyReservations ? "carseat.right.fill" : "ticket.fill")
                    .accessibilityLabel(onlyReservations ? "Reservierung gespeichert" : "Ticket gespeichert")
            }
            Spacer(minLength: 8)
            if !trains.isEmpty {
                Text(trains.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .accessibilityLabel(String(localized: "Züge: \(trains.formatted(.list(type: .and)))"))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var dayLabel: String {
        guard let date = entry.journey.departure?.planned else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Save/unsave toggle for a journey.
struct SaveJourneyButton: View {
    let journey: Journey
    /// Options the journey was found with, kept with it so a re-plan can start from them.
    var search: ConnectionSearch?
    /// Shortens the label to just "Speichern", so the button can share its row with the round
    /// share/edit actions without squeezing them out.
    var shortLabel = false
    @Environment(AppModel.self) private var model
    @State private var journeyToRemove: Journey?
    /// What the journey's trains need (a reservation, in bike mode a bike reservation), while the warning is up.
    @State private var warnings = SaveWarnings()
    @State private var showsReservationWarning = false
    @State private var isCheckingReservation = false

    private var title: String {
        if shortLabel { return model.isSaved(journey) ? String(localized: "Gespeichert") : String(localized: "Speichern") }
        return model.isSaved(journey) ? String(localized: "Reise gespeichert") : String(localized: "Reise speichern")
    }

    var body: some View {
        let saved = model.isSaved(journey)
        Button(action: { toggle(saved) }) {
            Label(title, systemImage: saved ? "bookmark.fill" : "bookmark")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .tint(saved ? Color.punctual : Color.brand)
        .controlSize(.large)
        .sensoryFeedback(.success, trigger: saved)
        .disabled(isCheckingReservation)
        .checkoutPrompt($journeyToRemove)
        .alert(warningTitle, isPresented: $showsReservationWarning) {
            Button("Abbrechen", role: .cancel) {}
            Button("Verstanden, weiter") { save() }
        } message: {
            Text(warningMessage)
        }
    }

    private var warningTitle: String {
        if warnings.seatReservation.isEmpty {
            return warnings.bikeReservation.isEmpty ? String(localized: "Achtung: Keine Fahrradmitnahme") : String(localized: "Achtung: Fahrradreservierung nötig")
        }
        return warnings.bikeReservation.isEmpty && warnings.noBikes.isEmpty ? String(localized: "Achtung: Zug ist reservierungspflichtig") : String(localized: "Achtung: Reservierung nötig")
    }

    private var warningMessage: String {
        func trains(_ legs: [Leg]) -> String { legs.compactMap { $0.line?.displayName }.formatted(.list(type: .and)) }
        var lines: [String] = []
        if !warnings.seatReservation.isEmpty {
            lines.append(String(localized: "\(trains(warnings.seatReservation)): Nur mit Reservierung. Du kannst sie über „Via Ticket hinzufügen“ importieren."))
        }
        if !warnings.bikeReservation.isEmpty {
            lines.append(String(localized: "\(trains(warnings.bikeReservation)): Fahrrad nur mit Fahrradreservierung."))
        }
        if !warnings.noBikes.isEmpty {
            lines.append(String(localized: "\(trains(warnings.noBikes)): Keine Fahrradmitnahme."))
        }
        return lines.joined(separator: "\n")
    }

    private func toggle(_ saved: Bool) {
        if saved {
            withAnimation(.snappy) { model.remove(journey, askingToCheckOut: &journeyToRemove) }
            return
        }
        // A journey added from a ticket or reservation import is saved by the import itself and never
        // gets here, so every journey saved with this button still lacks a reservation.
        isCheckingReservation = true
        Task {
            let bike = model.settings.bike(searchingWithBike: search?.withBike ?? model.settings.searchWithBike)
            let found = await model.saveWarnings(for: journey, bike: bike)
            isCheckingReservation = false
            if found.isEmpty {
                save()
            } else {
                warnings = found
                showsReservationWarning = true
            }
        }
    }

    private func save() {
        withAnimation(.snappy) { model.save(journey, search: search) }
    }
}
