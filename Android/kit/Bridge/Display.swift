// Kit models as the Android app gets them: the model itself (to show its fields and to hand back) plus what the
// iOS app computes from it with Kit code.
import BetterBahnKit
import Foundation

struct LineDisplay: Encodable {
    /// "ICE 940 / 950" for coupled trains (`Line.displayName`).
    var displayName: String
    /// The S-Bahn's run number in the train view: "S 8 (37856)" (`Line.nameWithTripNumber`).
    var nameWithTripNumber: String
    /// The filter group, also the badge colour (night train, IR/FLX next to IC/EC).
    var filterProduct: Product
    var isNightTrain: Bool
    /// The line's own colour (0xRRGGBB) for S-/U-Bahn lines that have one, else nil for the product's.
    var colorHex: UInt32?

    init(_ line: Line) {
        displayName = line.displayName
        nameWithTripNumber = line.nameWithTripNumber
        filterProduct = line.filterProduct
        isNightTrain = line.isNightTrain
        colorHex = line.lineColorHex
    }
}

struct JourneyDisplay: Encodable {
    var id: String
    var journey: Journey
    /// Per leg, what the iOS app computes for it.
    var legs: [LegDisplay]
    var transfers: Int
    /// From the first departure to the last arrival, live times where known (`Journey.duration`).
    var durationSeconds: TimeInterval?
    /// Where each leg sits on the journey's bar (`Journey.barSpans`), as start and end.
    var barSpans: [[Date]]
    var isCancelled: Bool
    /// Over 10 minutes after the arrival (`Journey.isOver`).
    var isOver: Bool
    /// Transfers (index of the leg after it) that can no longer be made with the live times.
    var brokenTransferIndices: [Int]
    /// Missed or tight transfers and cancelled legs (`Journey.currentIssues`).
    var issues: [IssueDisplay]

    init(_ journey: Journey) {
        id = journey.id
        self.journey = journey.withoutGeometry
        legs = journey.legs.map(LegDisplay.init)
        transfers = journey.transfers
        durationSeconds = journey.duration
        barSpans = journey.barSpans.map { [$0.start, $0.end] }
        isCancelled = journey.isCancelled
        isOver = journey.isOver()
        brokenTransferIndices = journey.brokenTransferIndices
        issues = journey.currentIssues().map(IssueDisplay.init)
    }
}

struct LegDisplay: Encodable {
    var line: LineDisplay?
    /// "Düsseldorf Hbf / Köln Hbf" when coupled trains split (`Leg.directionDescription`).
    var direction: String?
    /// The stops between departure and arrival as the iOS app lists them (bahn.de's outlying extra stops dropped).
    var intermediateStops: [Stopover]
    var hasDelayReason: Bool
    /// "Ausstieg in Fahrtrichtung links" where the offline platform list knows it (`ExitSides`).
    var exitSide: String?

    init(_ leg: Leg) {
        line = leg.line.map(LineDisplay.init)
        direction = leg.directionDescription
        intermediateStops = Array(BahnDeClient.droppingOutlyingZusatzhalte(from: leg.stopovers).dropFirst().dropLast())
        hasDelayReason = leg.messages.contains { $0.kind == .delay }
        exitSide = ExitSides.side(leaving: leg)?.displayName
    }
}

struct IssueDisplay: Encodable {
    var title: String
    var message: String
    var isBlocking: Bool

    init(_ issue: ConnectionIssue) {
        title = issue.title
        message = issue.message
        isBlocking = issue.isBlocking
    }
}

struct BoardEntryDisplay: Encodable {
    var id: String
    var entry: BoardEntry
    var line: LineDisplay

    init(_ entry: BoardEntry) {
        id = entry.id
        self.entry = entry
        line = LineDisplay(entry.line)
    }
}

struct TripDisplay: Encodable {
    var trip: Trip
    var line: LineDisplay?

    init(_ trip: Trip) {
        var trip = trip
        // The route's shape is only for a map, which the Android app doesn't have yet; it made answers megabytes.
        trip.geometry = nil
        self.trip = trip
        line = trip.line.map(LineDisplay.init)
    }
}

extension Journey {
    /// Without the legs' route shapes (see `TripDisplay`). The Kit fetches them again where it needs them.
    var withoutGeometry: Journey {
        var journey = self
        for index in journey.legs.indices { journey.legs[index].geometry = nil }
        return journey
    }
}

/// `TrainSearchResult` as JSON both ways (the Kit's type isn't Codable), plus what the list shows.
struct TrainResult: Codable, Sendable {
    var journeyId: String
    var category: String
    var number: Int
    var line: String?
    var product: Product
    var origin: String
    var destination: String
    var originEVA: String?
    var destinationEVA: String?
    /// "ICE 123", or the line's name for a regional train (`TrainSearchResult.name`).
    var name: String?
    var lineName: String?

    init(_ result: TrainSearchResult) {
        journeyId = result.journeyId
        category = result.category
        number = result.number
        line = result.line
        product = result.product
        origin = result.origin
        destination = result.destination
        originEVA = result.originEVA
        destinationEVA = result.destinationEVA
        name = result.name
        lineName = result.lineName
    }

    var kit: TrainSearchResult {
        TrainSearchResult(journeyId: journeyId, category: category, number: number, line: line, product: product,
                          origin: origin, destination: destination, originEVA: originEVA, destinationEVA: destinationEVA)
    }
}
