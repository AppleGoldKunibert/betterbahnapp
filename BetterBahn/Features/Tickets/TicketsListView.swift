import BetterBahnKit
import PhotosUI
import SwiftUI

/// Round button next to "Gespeichert" on a saved journey that has tickets: shows them.
/// Tickets are added with `AddTicketButton` next to "Verbindungen suchen".
struct TicketButton: View {
    let tickets: [SavedTicket]
    let journey: Journey
    @State private var showTickets = false

    var body: some View {
        Button {
            showTickets = true
        } label: {
            Image(systemName: "ticket.fill")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .tint(.brand)
        .accessibilityLabel("Ticket anzeigen")
        .sheet(isPresented: $showTickets) {
            TicketView(tickets: tickets, journey: journey)
        }
    }
}

/// Icon next to "Verbindungen suchen": fetches a ticket by order number and links it to its journey.
struct AddTicketButton: View {
    @State private var showLookup = false
    @State private var notMatched = false
    @State private var lookupFoundNoJourney = false

    var body: some View {
        Button {
            showLookup = true
        } label: {
            // Same font and padding as the search button so both are the same height.
            Label("Via Ticket hinzufügen", systemImage: "ticket")
                .labelStyle(.iconOnly)
                .font(.headline)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .tint(.brand)
        .controlSize(.large)
        .sheet(isPresented: $showLookup, onDismiss: {
            notMatched = lookupFoundNoJourney
            lookupFoundNoJourney = false
        }) {
            TicketLookupView { imported in
                lookupFoundNoJourney = imported.contains { $0.journeyID == nil }
            }
        }
        .alert("Verbindung nicht gefunden", isPresented: $notMatched) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Das Ticket ist gespeichert, aber die gebuchte Verbindung wurde in den Fahrplandaten nicht gefunden. Du findest es in den Einstellungen unter „Gespeicherte Tickets“.")
        }
    }
}

/// Settings → Tickets: passes like the Deutschland-Ticket (added here from a screenshot) and every
/// stored ticket. New tickets are fetched from the search page.
struct TicketsListView: View {
    @Environment(AppModel.self) private var model
    @State private var shownTickets: [SavedTicket]?
    @State private var shownPass: TravelPass?
    @State private var pickedImage: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: Error?

    var body: some View {
        List {
            Section {
                ForEach(sortedPasses) { pass in
                    Button { shownPass = pass } label: { row(pass) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets { model.removeTravelPass(sortedPasses[index]) }
                }
                // The label closure isn't main-actor isolated, so it gets a copy of the state.
                PhotosPicker(selection: $pickedImage, matching: .images) { [isImporting] in
                    HStack {
                        Label("Zeitkarte hinzufügen", systemImage: "plus.circle.fill")
                        if isImporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isImporting)
            } header: {
                Text("Zeitkarten")
            } footer: {
                Text("Wähl einen Screenshot des QR-Codes deines Deutschland-Tickets aus. Bitte beachte, dass nicht alle Anbieter unterstützt werden.")
            }

            Section {
                if model.tickets.isEmpty {
                    Text("Noch keine Tickets. Füge sie unter „Verbindungen“ mit „Via Ticket hinzufügen“ hinzu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedTickets) { saved in
                    Button { shownTickets = [saved] } label: { row(saved) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets { model.removeTicket(sortedTickets[index]) }
                }
            } header: {
                Text("Tickets")
            } footer: {
                Text("Tickets und Zeitkarten werden nur auf diesem Gerät gespeichert, nicht in iCloud.")
            }
        }
        .navigationTitle("Tickets")
        .sheet(item: Binding(get: { shownTickets.map(TicketSelection.init) }, set: { shownTickets = $0?.tickets })) { selection in
            TicketView(tickets: selection.tickets, journey: journey(for: selection.tickets.first))
        }
        .sheet(item: $shownPass) { TravelPassView(pass: $0) }
        .onChange(of: pickedImage) { _, item in
            guard let item else { return }
            Task { await importPass(item) }
        }
        .alert("Zeitkarte nicht hinzugefügt", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError?.localizedDescription ?? "")
        }
    }

    /// Newest validity first, so this month's pass is on top.
    private var sortedPasses: [TravelPass] {
        model.travelPasses.sorted { ($0.validUntil ?? $0.issued) > ($1.validUntil ?? $1.issued) }
    }

    private func importPass(_ item: PhotosPickerItem) async {
        isImporting = true
        defer {
            isImporting = false
            pickedImage = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw TravelPass.ImportError.noBarcode }
            shownPass = try await model.addTravelPass(fromImage: data)
        } catch {
            importError = error
        }
    }

    private func row(_ pass: TravelPass) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: pass.isBahnCard100 ? "creditcard.fill" : "ticket.fill",
                     color: pass.isExpired() ? .secondary : .brand, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([pass.kindDescription, validity(of: pass)].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(pass.isExpired() ? Color.slightDelay : .secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
    }

    private func validity(of pass: TravelPass) -> String? {
        if pass.isExpired() { return "Abgelaufen" }
        if !pass.isValid(), let from = pass.validFrom { return "ab " + from.formatted(date: .abbreviated, time: .omitted) }
        return pass.validUntil.map { "bis " + $0.formatted(date: .abbreviated, time: .shortened) }
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
