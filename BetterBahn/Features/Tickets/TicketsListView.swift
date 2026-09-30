import BetterBahnKit
import SwiftUI

/// Round button next to "Gespeichert" on a saved journey: shows its ticket, or fetches one.
struct TicketButton: View {
    let journey: Journey
    @Environment(AppModel.self) private var model
    @State private var showTickets = false
    @State private var showLookup = false
    /// Set by the lookup; the tickets open once its sheet is gone.
    @State private var openAfterLookup = false

    var body: some View {
        let tickets = model.tickets(for: journey)
        Button {
            if tickets.isEmpty { showLookup = true } else { showTickets = true }
        } label: {
            Image(systemName: tickets.isEmpty ? "ticket" : "ticket.fill")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .tint(.brand)
        .accessibilityLabel(tickets.isEmpty ? "Ticket abrufen" : "Ticket anzeigen")
        .sheet(isPresented: $showTickets) {
            TicketView(tickets: model.tickets(for: journey), journey: journey)
        }
        .sheet(isPresented: $showLookup, onDismiss: {
            if openAfterLookup { showTickets = !model.tickets(for: journey).isEmpty }
            openAfterLookup = false
        }) {
            TicketLookupView { _ in openAfterLookup = true }
        }
    }
}

/// Settings → Tickets: every stored ticket, and fetching new ones.
struct TicketsListView: View {
    @Environment(AppModel.self) private var model
    @State private var showLookup = false
    @State private var shownTickets: [SavedTicket]?
    @State private var notMatched = false
    @State private var lookupFoundNoJourney = false

    var body: some View {
        List {
            Section {
                Button {
                    showLookup = true
                } label: {
                    IconLabel(title: "Ticket per Auftragsnummer abrufen", systemImage: "plus.circle.fill", color: .brand)
                }
            } footer: {
                Text("Tickets werden nur auf diesem Gerät gespeichert, nicht in iCloud.")
            }

            if !model.tickets.isEmpty {
                Section("Gespeicherte Tickets") {
                    ForEach(sortedTickets) { saved in
                        Button { shownTickets = [saved] } label: { row(saved) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets { model.removeTicket(sortedTickets[index]) }
                    }
                }
            }
        }
        .navigationTitle("Tickets")
        .sheet(isPresented: $showLookup, onDismiss: {
            notMatched = lookupFoundNoJourney
            lookupFoundNoJourney = false
        }) {
            TicketLookupView { imported in
                lookupFoundNoJourney = imported.contains { $0.journeyID == nil }
            }
        }
        .sheet(item: Binding(get: { shownTickets.map(TicketSelection.init) }, set: { shownTickets = $0?.tickets })) { selection in
            TicketView(tickets: selection.tickets, journey: journey(for: selection.tickets.first))
        }
        .alert("Verbindung nicht gefunden", isPresented: $notMatched) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Das Ticket ist gespeichert, aber die gebuchte Verbindung wurde in den Fahrplandaten nicht gefunden. Du findest es hier unter „Gespeicherte Tickets“.")
        }
    }

    private var sortedTickets: [SavedTicket] {
        model.tickets.sorted { ($0.ticket.legs.first?.departure ?? .distantPast) > ($1.ticket.legs.first?.departure ?? .distantPast) }
    }

    private func journey(for ticket: SavedTicket?) -> Journey? {
        guard let id = ticket?.journeyID else { return nil }
        return model.savedJourneys.first { $0.id == id }?.journey
    }

    private func row(_ saved: SavedTicket) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: saved.ticket.isReservationOnly ? "carseat.right.fill"
                        : saved.ticket.isPartnerDocument ? "ticket" : "ticket.fill", color: .brand, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.ticket.routeDescription).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([saved.ticket.offerName,
                      saved.ticket.legs.first?.departure.formatted(date: .abbreviated, time: .shortened)]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if saved.journeyID == nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    .accessibilityLabel("Keiner gespeicherten Reise zugeordnet")
            }
        }
        .contentShape(.rect)
    }
}

private struct TicketSelection: Identifiable {
    let tickets: [SavedTicket]
    var id: String { tickets.map(\.id).joined(separator: ",") }
}
