import Foundation

/// One scheduled composition ("Planmäßige Reihung") from a vagonweb.cz train page: the coaches in
/// the order vagonweb draws them, with the dates it applies to when the page gives any.
public struct VagonwebComposition: Sendable, Hashable {
    public struct Coach: Sendable, Hashable {
        /// Coach number passengers look for ("21"); nil for locomotives and power cars.
        public var number: String?
        /// vagonweb's series, e.g. "408.5" or "812".
        public var series: String?
        /// UIC type code, e.g. "Bpmdzf", "ARmz".
        public var typeCode: String?
        /// Baureihe from the coach's drawing (`…/img/DB/408-5-b.gif` → "408"), which is the trainset's
        /// series even where `series` names the coach's own one (ICE 4: "812" coaches in a BR 412).
        public var baureihe: String?
        public var firstClass: Bool
        public var secondClass: Bool
        /// Seats in a dining section ("jidel"); with no other seats it's a full dining car.
        public var diningSeats: Int?
        public var hasBar: Bool
        public var bikeSpaces: Int?
        public var wheelchairSpaces: Int?
        public var hasInfoPoint: Bool
        /// vagonweb's notes below the coach, e.g. "quiet zone", "seats 11-46 for bahn.comfort".
        public var notes: [String]

        /// A driving vehicle at the end of a trainset ("…f": Bpmzf, Apmzf, Bpmbdzf).
        var hasCab: Bool { typeCode?.hasSuffix("f") == true }
        var hasSeats: Bool { firstClass || secondClass || diningSeats != nil || hasBar }
    }

    /// First and last day the composition applies to (`14.12.2025 - 30.10.2026`); nil when vagonweb
    /// gives it for the whole timetable year.
    public var validFrom: Date?
    public var validUntil: Date?
    public var coaches: [Coach]

    /// Whether the composition applies on `day` (calendar day, Europe/Berlin).
    public func applies(on day: Date) -> Bool {
        let calendar = VagonwebComposition.calendar
        if let validFrom, calendar.startOfDay(for: day) < calendar.startOfDay(for: validFrom) { return false }
        if let validUntil, calendar.startOfDay(for: day) > calendar.startOfDay(for: validUntil) { return false }
        return true
    }

    /// The trainsets: a new one starts after a cab car that doesn't open the current one, e.g. the
    /// two coupled ICE 3 of ICE 1005 (Wagen 31–39 and 21–29).
    public var units: [[Coach]] {
        var units: [[Coach]] = []
        var current: [Coach] = []
        for coach in coaches {
            current.append(coach)
            if coach.hasCab, current.count > 1 {
                units.append(current)
                current = []
            }
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
}

// MARK: - Parsing

extension VagonwebComposition {
    /// The scheduled compositions on a vagonweb.cz train page (`razeni/vlak.php`). Compositions people
    /// reported seeing on one day ("Real composition on: …") are left out.
    public static func scheduled(fromHTML html: String) -> [VagonwebComposition] {
        let blocks = html.components(separatedBy: "<div id='vlak_").dropFirst()
        return blocks.compactMap { block -> VagonwebComposition? in
            // Scheduled compositions have the heading class `color-z`, reported ones `color-ex`,
            // whatever the page's language.
            guard let heading = block.between("<h4", "</h4>"), heading.contains("color-z") else { return nil }
            let dates = heading.matches(of: #/(\d{1,2})\.(\d{1,2})\.(\d{4})/#).compactMap { match in
                calendar.date(from: DateComponents(year: Int(match.3), month: Int(match.2), day: Int(match.1), hour: 12))
            }
            let coaches = block.components(separatedBy: "<td class='bunka_vozu'").dropFirst().map(coach(from:))
            guard !coaches.isEmpty else { return nil }
            return VagonwebComposition(validFrom: dates.first, validUntil: dates.count > 1 ? dates[1] : nil, coaches: coaches)
        }
    }

    static func coach(from cell: String) -> Coach {
        let icons = cell.matches(of: #/popisy/ico/([A-Za-z0-9_]+)\.svg'[^>]*>\s*(\d*)/#).map { (String($0.1), Int($0.2)) }
        let count = { (name: String) in icons.first { $0.0 == name }?.1 }
        let has = { (name: String) in icons.contains { $0.0 == name } }
        let baureihe = cell.firstMatch(of: #/popisy/img/DB/(\d{3})-/#).map { String($0.1) }
        let notes = cell.components(separatedBy: "<div class=maly>").dropFirst().compactMap { part -> String? in
            guard let text = part.components(separatedBy: "</div>").first?.strippingTags, !text.isEmpty else { return nil }
            return text
        }
        return Coach(
            number: cell.between("raz-cislo>", "<")?.strippingTags.nonEmpty,
            series: cell.between("tab-radam>", "<")?.strippingTags.nonEmpty,
            typeCode: cell.between("<small>", "</small>")?.strippingTags.nonEmpty,
            baureihe: baureihe,
            firstClass: has("tr1") || cell.contains("'tab-1tr'"),
            secondClass: has("tr2") || cell.contains("'tab-2tr'"),
            diningSeats: has("jidel") ? count("jidel") ?? 0 : nil,
            hasBar: has("bar"),
            bikeSpaces: count("kolo"),
            wheelchairSpaces: has("inv3") || has("inv2") || has("inv1") ? count("inv3") ?? count("inv2") ?? count("inv1") ?? 0 : nil,
            hasInfoPoint: has("info"),
            notes: notes)
    }
}

private extension String {
    /// The text between the first `start` and the following `end`.
    func between(_ start: String, _ end: String) -> String? {
        guard let from = range(of: start), let to = self[from.upperBound...].range(of: end) else { return nil }
        return String(self[from.upperBound..<to.lowerBound])
    }

    /// Tags removed, entities decoded, whitespace collapsed.
    var strippingTags: String {
        var text = replacing(#/<[^>]*>/#, with: " ")
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var nonEmpty: String? { isEmpty ? nil : self }
}
