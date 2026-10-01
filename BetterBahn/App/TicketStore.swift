import BetterBahnKit
import Foundation

/// A ticket fetched from bahn.de and the saved journey it belongs to.
nonisolated struct SavedTicket: Codable, Hashable, Identifiable {
    var ticket: DBTicket
    /// `SavedJourney.id` (nil if no saved journey matched).
    var journeyID: UUID?

    var id: String { ticket.id }
}

/// Tickets stay on this device only: unlike saved journeys they're never mirrored to iCloud, and
/// the files are encrypted while the device is locked. The order number and name aren't kept at
/// all – bahn.de's own page asks for them each time.
nonisolated enum TicketStore {
    private static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "BetterBahn/Tickets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var listFile: URL { directory.appending(path: "tickets.json") }
    private static var passesFile: URL { directory.appending(path: "passes.json") }

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
    func importTickets(_ result: DBOrderPage.Result, orderNumber: String) async throws -> [SavedTicket] {
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
            imported.append(SavedTicket(ticket: ticket, journeyID: journeyID))
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
        guard let entry = savedEntry(for: journey) else { return nil }
        return reservations(for: entry).first { $0.matches(leg) }
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
