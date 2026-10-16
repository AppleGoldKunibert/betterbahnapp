import BetterBahnKit
import SwiftUI
import UserNotifications

// MARK: - App model

extension AppModel {
    /// The Fahrgastrechte claim of a saved journey that has arrived (#311), else nil. Goes by the stored
    /// journey, since past journeys are shown without the delays once their live data is old.
    func passengerRightsClaim(for entry: SavedJourney) -> PassengerRightsClaim? {
        let stored = savedJourneys.first { $0.id == entry.id } ?? entry
        let computed = liveClaim(for: stored)
        // The worst delay seen wins; the recorded one is all that is left once the live data is gone.
        guard let recorded = stored.recordedClaim else { return computed }
        guard let computed else { return recorded }
        return computed.delayMinutes > recorded.delayMinutes ? computed : recorded
    }

    private func liveClaim(for stored: SavedJourney) -> PassengerRightsClaim? {
        let ticketsOfJourney = tickets(for: stored).filter { !$0.ticket.isReservationOnly }
        // A pass barcode doesn't say whether it belongs to a BahnCard 100 (#322), so go by the ticket picked in the settings.
        let hasBahnCard100 = settings.ticketType == .bahnCard100
        return PassengerRights.claim(for: stored.journey, earlierPlans: (stored.previousVersions ?? []).map(\.journey),
                                     hasTicket: !ticketsOfJourney.isEmpty, hasBahnCard100: hasBahnCard100)
    }

    /// The order numbers of the tickets bought for the journey.
    func orderNumbers(for entry: SavedJourney) -> [String] {
        var numbers: [String] = []
        for saved in tickets(for: entry) where !saved.ticket.isReservationOnly && !numbers.contains(saved.ticket.orderNumber) {
            numbers.append(saved.ticket.orderNumber)
        }
        return numbers
    }

    /// Keeps the claim of a journey that has arrived (see `SavedJourney.recordedClaim`), and tells the
    /// user once per level (25 %, 50 %).
    func notifyPassengerRights(for id: UUID) async {
        guard let index = savedJourneys.firstIndex(where: { $0.id == id }),
              let claim = passengerRightsClaim(for: savedJourneys[index]) else { return }
        if savedJourneys[index].recordedClaim != claim { savedJourneys[index].recordedClaim = claim }
        guard settings.connectionWarnings else { return }
        var known = savedJourneys[index].notifiedIssues ?? []
        guard !known.contains(claim.notificationID) else { return }
        known.append(claim.notificationID)
        savedJourneys[index].notifiedIssues = known
        await ConnectionNotifier.notify(claim, journey: savedJourneys[index].journey)
    }
}

extension ConnectionNotifier {
    static func notify(_ claim: PassengerRightsClaim, journey: Journey) async {
        let content = UNMutableNotificationContent()
        content.title = "Anspruch auf \(claim.compensation.percent) % Entschädigung"
        let destination = journey.legs.last?.destination.displayName ?? "deinem Ziel"
        content.body = "Du bist \(claim.delayMinutes) Min. später in \(destination) angekommen. Unter „Vergangene Fahrten“ kannst du den Antrag vorbereiten."
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: claim.notificationID + journey.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Views

extension PassengerRightsClaim {
    var title: String { "Du hast Anspruch auf \(compensation.percent) % Entschädigung" }

    var explanation: String {
        switch cause {
        case .delay: "Du bist \(delayMinutes) Minuten später angekommen als geplant."
        case .missedConnection: "Du hast wegen einer Verspätung einen Anschluss verpasst und kamst \(delayMinutes) Minuten später an als geplant."
        case .replanned: "Wegen eines Ausfalls kamst du \(delayMinutes) Minuten später an als geplant."
        }
    }
}

/// Small hint on a saved journey in the lists.
struct PassengerRightsBadge: View {
    let claim: PassengerRightsClaim

    var body: some View {
        Label("Anspruch auf \(claim.compensation.percent) % Entschädigung", systemImage: "eurosign.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.punctual)
            .padding(.horizontal, 6)
    }
}

/// In the details of a journey: what the user is owed and a way to claim it.
struct PassengerRightsCard: View {
    let entry: SavedJourney
    let claim: PassengerRightsClaim
    @State private var showsRequest = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "eurosign.circle.fill", color: .punctual, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(claim.title).font(.headline)
                        Text(claim.explanation).font(.subheadline).foregroundStyle(.secondary)
                        if claim.isFlatRate {
                            Text("Mit der BahnCard 100 gelten andere Regeln. Mehr dazu auf bahn.de.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Button { showsRequest = true } label: {
                    Label("Antrag vorbereiten", systemImage: "doc.text")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .controlSize(.large)
            }
        }
        .sheet(isPresented: $showsRequest) { PassengerRightsRequestSheet(entry: entry, claim: claim) }
    }
}

/// Everything DB's online form asks for, each with a copy button.
struct PassengerRightsRequestSheet: View {
    let entry: SavedJourney
    let claim: PassengerRightsClaim
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        let orderNumbers = model.orderNumbers(for: entry)
        let fields = PassengerRights.requestFields(for: entry.journey, claim: claim, orderNumbers: orderNumbers)
        NavigationStack {
            List {
                Section {
                    ForEach(fields) { field in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.label).font(.caption).foregroundStyle(.secondary)
                                Text(field.value)
                            }
                            Spacer(minLength: 8)
                            Button(copied == field.id ? "Kopiert" : "Kopieren", systemImage: copied == field.id ? "checkmark" : "doc.on.doc") {
                                copy(field.value, id: field.id)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    if orderNumbers.isEmpty {
                        Text("Die Auftragsnummer steht auf deinem Ticket. Mit „Via Ticket hinzufügen“ ist sie hier gleich dabei.")
                    }
                }
                Section {
                    Button("Alles kopieren", systemImage: "doc.on.doc.fill") {
                        copy(PassengerRights.requestText(for: entry.journey, claim: claim, orderNumbers: orderNumbers), id: "all")
                    }
                    Link(destination: PassengerRights.formURL) {
                        Label("Antrag bei der Bahn öffnen", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .sensoryFeedback(.success, trigger: copied)
            .navigationTitle("Antrag vorbereiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { dismiss() } }
        }
    }

    private func copy(_ text: String, id: String) {
        UIPasteboard.general.string = text
        copied = id
    }
}
