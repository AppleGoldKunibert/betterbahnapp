import BetterBahnKit
import Foundation

/// A ticket fetched from bahn.de and the saved journey it belongs to.
nonisolated struct SavedTicket: Codable, Hashable, Identifiable {
    var ticket: DBTicket
    /// `SavedJourney.id` (nil if no saved journey matched).
    var journeyID: UUID?
    /// The last name the order was looked up with, so the Komfort-Check-in can open it again (#605).
    var lastName: String?

    var id: String { ticket.id }
}

/// A train of a saved ticket whose Komfort-Check-in the app offers (#605).
nonisolated struct KomfortCheckinTarget: Identifiable, Hashable {
    var ticket: SavedTicket
    var leg: KomfortCheckin.Leg

    var id: String { ticket.id + "-\(leg.index)" }
}

/// Tickets stay on this device only: unlike saved journeys they're never mirrored to iCloud, and
/// the files are encrypted while the device is locked. The last name the order was looked up with
/// and the BahnCard number for the Komfort-Check-in stay here too, so the check-in on the train
/// doesn't ask for them again.
nonisolated enum TicketStore {
    private static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "BetterBahn/Tickets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var listFile: URL { directory.appending(path: "tickets.json") }
    private static var passesFile: URL { directory.appending(path: "passes.json") }
    private static var bahnCardFile: URL { directory.appending(path: "bahncard.txt") }

    /// The BahnCard number last used for a Komfort-Check-in.
    static var bahnCardNumber: String? {
        get { (try? String(contentsOf: bahnCardFile, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            guard let newValue, !newValue.isEmpty else {
                try? FileManager.default.removeItem(at: bahnCardFile)
                return
            }
            try? Data(newValue.utf8).write(to: bahnCardFile, options: [.atomic, .completeFileProtection])
        }
    }

    private static func pdfFile(_ id: String) -> URL {
        directory.appending(path: id.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".pdf")
    }

    static func load() -> [SavedTicket] {
        guard let data = try? Data(contentsOf: listFile) else { return [] }
        return (try? JSONDecoder().decode([SavedTicket].self, from: data)) ?? []
    }

    static func save(_ tickets: [SavedTicket]) {
        guard let data = try? JSONEncoder().encode(tickets) else { return }
        try? data.write(to: listFile, options: [.atomic, .completeFileProtection])
    }

    static func loadPasses() -> [TravelPass] {
        guard let data = try? Data(contentsOf: passesFile) else { return [] }
        return (try? JSONDecoder().decode([TravelPass].self, from: data)) ?? []
    }

    static func savePasses(_ passes: [TravelPass]) {
        guard let data = try? JSONEncoder().encode(passes) else { return }
        try? data.write(to: passesFile, options: [.atomic, .completeFileProtection])
    }

    static func savePDF(_ data: Data, for id: String) {
        try? data.write(to: pdfFile(id), options: [.atomic, .completeFileProtection])
    }

    static func pdf(for id: String) -> Data? {
        try? Data(contentsOf: pdfFile(id))
    }

    static func removePDF(for id: String) {
        try? FileManager.default.removeItem(at: pdfFile(id))
    }
}

// MARK: - App model

extension AppModel {
    func tickets(for journey: Journey) -> [SavedTicket] {
        guard let entry = savedEntry(for: journey) else { return [] }
        return tickets(for: entry)
    }

    func tickets(for entry: SavedJourney) -> [SavedTicket] {
        tickets.filter { $0.journeyID == entry.id }
    }

    /// Reads an order fetched on bahn.de's page, links each ticket to the saved journey it was
    /// booked for (saving the booked connection when there's none yet) and keeps it on this device.
    /// Returns the tickets in order; `journeyID` is nil where the connection couldn't be found.
    func importTickets(_ result: DBOrderPage.Result, orderNumber: String, lastName: String? = nil) async throws -> [SavedTicket] {
        let order = result.order, pdfs = result.pdfs
        // Rendering and scanning the PDFs takes a moment, so it runs off the main thread.
        let fetched = try await Task.detached(priority: .userInitiated) {
            let barcodes = pdfs.compactMapValues(TicketBarcodeReader.barcode(inPDF:))
            return try DBOrder.tickets(from: order, orderNumber: orderNumber, barcodes: barcodes)
        }.value

        var journeyIDs: [DBTicket.Direction: UUID?] = [:]
        var imported: [SavedTicket] = []
        for ticket in fetched {
            let journeyID: UUID?
            if let known = journeyIDs[ticket.direction] {
                journeyID = known
            } else {
                journeyID = await savedJourneyID(for: ticket)
                // `.some`, so a connection that wasn't found is remembered too instead of removing the key.
                journeyIDs[ticket.direction] = .some(journeyID)
            }
            if let pdf = pdfs[ticket.bundleID] { TicketStore.savePDF(pdf, for: ticket.id) }
            imported.append(SavedTicket(ticket: ticket, journeyID: journeyID, lastName: lastName))
        }
        let ids = Set(imported.map(\.id))
        tickets = tickets.filter { !ids.contains($0.id) } + imported
        return imported
    }

    private func savedJourneyID(for ticket: DBTicket) async -> UUID? {
        if let entry = savedJourneys.first(where: { ticket.matches($0.journey) }) { return entry.id }
        guard let connection = ticket.sharedConnection,
              let journey = try? await dbShareImporter.journey(from: connection) else { return nil }
        save(journey)
        return savedEntry(for: journey)?.id
    }

    // MARK: Seat reservations

    /// The seats reserved on the journey's tickets.
    func reservations(for entry: SavedJourney) -> [SeatReservation] {
        tickets(for: entry).flatMap(\.ticket.seats).map(SeatReservation.init)
    }

    /// The reservation for the train `leg` rides; one for a train no longer on the journey (e.g.
    /// after choosing another train) simply matches no leg and isn't shown.
    func reservation(for leg: Leg, in journey: Journey) -> SeatReservation? {
        #if DEBUG
        if let demo = debugReservation(for: leg) { return demo }
        #endif
        guard let entry = savedEntry(for: journey) else { return nil }
        return reservations(for: entry).first { $0.matches(leg) }
    }

    // MARK: Komfort-Check-in

    /// The Komfort-Check-in for the train `leg` rides, from the journey's tickets (a full ticket
    /// before a reservation of its own).
    func komfortCheckin(for leg: Leg, in journey: Journey) -> KomfortCheckinTarget? {
        guard let entry = savedEntry(for: journey) else { return nil }
        let candidates = tickets(for: entry).filter { !$0.ticket.isPartnerDocument }
            .sorted { !$0.ticket.isReservationOnly && $1.ticket.isReservationOnly }
        for saved in candidates {
            if let checkin = saved.ticket.komfortCheckin?.leg(for: leg) { return KomfortCheckinTarget(ticket: saved, leg: checkin) }
        }
        return nil
    }

    /// The ticket's trains with a Komfort-Check-in.
    func komfortCheckins(forTicket id: String) -> [KomfortCheckinTarget] {
        guard let saved = tickets.first(where: { $0.id == id }), !saved.ticket.isPartnerDocument else { return [] }
        return (saved.ticket.komfortCheckin?.legs ?? []).map { KomfortCheckinTarget(ticket: saved, leg: $0) }
    }

    /// `target` as currently saved (its status may have changed since it was made).
    func current(_ target: KomfortCheckinTarget) -> KomfortCheckinTarget {
        komfortCheckins(forTicket: target.ticket.id).first { $0.leg.index == target.leg.index } ?? target
    }

    /// Keeps the status bahn.de answered a check-in with, and the name it was made with.
    func updateKomfortCheckin(_ target: KomfortCheckinTarget, status: KomfortCheckin.Status, lastName: String) {
        guard let position = tickets.firstIndex(where: { $0.id == target.ticket.id }) else { return }
        tickets[position].ticket.updateKomfortCheckin(legIndex: target.leg.index, status: status)
        tickets[position].lastName = lastName
    }

    func removeTicket(_ ticket: SavedTicket) {
        tickets.removeAll { $0.id == ticket.id }
        TicketStore.removePDF(for: ticket.id)
    }

    // MARK: Passes

    /// Reads a pass (e.g. the Deutschland-Ticket) from a screenshot of its barcode. The same pass
    /// added again replaces the old one.
    func addTravelPass(fromImage data: Data) async throws -> TravelPass {
        // Scanning a full-size screenshot takes a moment, so it runs off the main thread.
        let pass = try await Task.detached(priority: .userInitiated) {
            guard let barcode = TicketBarcodeReader.barcode(inImage: data) else { throw TravelPass.ImportError.noBarcode }
            return try TravelPass(barcode: barcode)
        }.value
        travelPasses = travelPasses.filter { !$0.isSamePass(as: pass) } + [pass]
        return pass
    }

    func removeTravelPass(_ pass: TravelPass) {
        travelPasses.removeAll { $0.id == pass.id }
    }
}
