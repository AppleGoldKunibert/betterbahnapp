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
    @Environment(\.calmDesign) private var calm
    @State private var journeyToRemove: Journey?

    var body: some View {
        let blocking = entry.issues.first(where: \.isBlocking)
        RouteLink(value: ConnectionsRoute.journey(entry.route(readOnly: readOnly))) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(dayLabel)
                    if isNext, model.liveActivities.isActive(entry.journey) {
                        Image(systemName: "bolt.badge.clock.fill").foregroundStyle(accent)
                    }
                    let tickets = model.tickets(for: entry)
                    if !tickets.isEmpty {
                        let onlyReservations = tickets.allSatisfy(\.ticket.isReservationOnly)
                        Image(systemName: onlyReservations ? "carseat.right.fill" : "ticket.fill").foregroundStyle(accent)
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
                            .strokeBorder(blocking != nil ? Color.heavyDelay : (highlightsAsNext ? accent : .clear), lineWidth: 2)
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

    /// Brand red, grey in the calm design.
    private var accent: Color { calm ? .primary : .brand }

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

struct PastTripsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.pastJourneys.isEmpty {
                    ContentUnavailableView("Keine vergangenen Fahrten", systemImage: "clock.arrow.circlepath")
                        .padding(.top, 60)
                }
                ForEach(model.pastJourneys) { SavedJourneyRow(entry: $0, readOnly: true) }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .tabBarSafePadding()
        .background { AppBackground() }
        .navigationTitle("Vergangene Fahrten")
        .navigationBarTitleDisplayMode(.inline)
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
