import Foundation

/// One scheduled composition ("Planmäßige Reihung") from a vagonweb.cz train page: the coaches in
/// the order vagonweb draws them, with the dates it applies to when the page gives any.
public struct VagonwebComposition: Sendable, Hashable {
    /// A stretch of the train's run ("Zürich - Buchs"), which vagonweb names for vehicles and
    /// compositions that only apply to part of it (locomotives changing on the way, coaches added or
    /// left behind, a different composition after Innsbruck).
    public struct Section: Sendable, Hashable {
        public var from: String
        public var to: String

        /// From vagonweb's label. Notes in brackets that continue the run ("(- Zagreb)", "(Buchs SG - )")
        /// are left out, a name's own ("Buchs (SG)") stays.
        init?(label: String) {
            let text = label.replacing(#/\([^)]*-[^)]*\)/#, with: "")
            let parts = text.components(separatedBy: " - ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard parts.count == 2 else { return nil }
            from = parts[0]
            to = parts[1]
        }

        /// Whether the train is in this section when it leaves the last stop of `route` (its stops from
        /// the first one up to that station): it has come by the section's start and not yet reached its end.
        func covers(route: [String]) -> Bool {
            let stops = Set(route.map(VagonwebClient.stationKey))
            return stops.contains(VagonwebClient.stationKey(from)) && !stops.contains(VagonwebClient.stationKey(to))
        }
    }

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
        /// Sleeping car ("Schlafwagen") and couchette car ("Liegewagen").
        public var sleeper = false
        public var couchette = false
        /// Car-carrier wagon of an Autoreisezug (or another service wagon without passengers).
        public var carCarrier = false
        /// Where the vehicle runs when that is only part of the train's run.
        public var section: Section?
        /// The days it runs on when its note says ("runs on ⑥, ⑦ …"), read completely or not at all.
        var restriction: DayRestriction?

        /// A driving vehicle at the end of a trainset ("…f": Bpmzf, Apmzf, Bpmbdzf).
        var hasCab: Bool { typeCode?.hasSuffix("f") == true }
        var hasSeats: Bool { firstClass || secondClass || diningSeats != nil || hasBar || sleeper || couchette }
    }

    /// First and last day the composition applies to (`14.12.2025 - 30.10.2026`); nil when vagonweb
    /// gives it for the whole timetable year.
    public var validFrom: Date?
    public var validUntil: Date?
    public var coaches: [Coach]
    /// Stations where the train changes direction, from vagonweb's note ("Fahrtrichtungswechsel in
    /// Frankfurt (Main) Hbf, Basel SBB und Bern, …"). vagonweb draws the composition as it leaves its
    /// first station, so after an odd number of these the train runs the other way round.
    public var reversalStations: [String] = []
    /// vagonweb draws the train as it leaves its first station, unless its note says the first part of
    /// the run is the one in reverse order ("Changes direction in Buchs SG, from Zürich until Buchs in
    /// reverse order"): then the drawing is the train after that station.
    public var startsReversed = false
    /// Where the composition applies when the page gives one per section ("Scheduled composition for the
    /// section: Zürich - Innsbruck").
    public var section: Section?
    /// Trains running together with this one on part of the run ("RJX 184"); their coaches are drawn
    /// in the same composition and carry the train's name as a note.
    public var coupledTrains: [String] = []

    /// Whether the composition applies on `day` (calendar day, Europe/Berlin).
    public func applies(on day: Date) -> Bool {
        let calendar = VagonwebComposition.calendar
        if let validFrom, calendar.startOfDay(for: day) < calendar.startOfDay(for: validFrom) { return false }
        if let validUntil, calendar.startOfDay(for: day) > calendar.startOfDay(for: validUntil) { return false }
        return true
    }

    /// The composition as the train leaves the last stop of `route`: only the vehicles whose section
    /// covers it, and none of the coaches that belong to a train running together with this one.
    /// The composition itself when that would leave no passenger coach (a station name vagonweb spells
    /// differently), as a wrong composition beats none less than a plain one.
    public func restricted(to route: [String]) -> VagonwebComposition {
        let kept = coaches.filter { coach in
            (coach.section?.covers(route: route) ?? true) && !coach.notes.contains { coupledTrains.contains($0) }
        }
        guard kept.contains(where: \.hasSeats) else { return self }
        var composition = self
        composition.coaches = kept
        return composition
    }

    /// The operating day (month, day and weekday, 1 = Monday) of a train leaving at `departure`: the one it started on,
    /// which for a stop in the first hours after midnight is the day before.
    static func operatingDay(of departure: Date) -> (month: Int, day: Int, weekday: Int) {
        var date = departure
        if calendar.component(.hour, from: date) < 4 { date = date.addingTimeInterval(-6 * 3600) }
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        // Calendar counts Sunday as 1.
        return (parts.month ?? 1, parts.day ?? 1, ((parts.weekday ?? 1) + 5) % 7 + 1)
    }

    /// The composition for the day of a train leaving at `departure`: without the coaches whose note says they
    /// don't run then (`DayRestriction`). Itself when that would leave no passenger coach.
    public func operating(on departure: Date) -> VagonwebComposition {
        let day = Self.operatingDay(of: departure)
        let kept = coaches.filter { $0.restriction?.runs(month: day.month, day: day.day, weekday: day.weekday) ?? true }
        guard kept.count < coaches.count, kept.contains(where: \.hasSeats) else { return self }
        var composition = self
        composition.coaches = kept
        return composition
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
        // The page as vagonweb sends it has `id='vlak_12'`, the one a browser serializes `id="vlak_12"`.
        let blocks = html.split(separator: #/<div id=['"]?vlak_/#, omittingEmptySubsequences: false).dropFirst()
        return blocks.compactMap { block -> VagonwebComposition? in
            let block = String(block)
            // Scheduled compositions have the heading class `color-z`, reported ones `color-ex`,
            // whatever the page's language.
            guard let heading = block.between("<h4", "</h4>"), heading.contains("color-z") else { return nil }
            let dates = heading.matches(of: #/(\d{1,2})\.(\d{1,2})\.(\d{4})/#).compactMap { match in
                calendar.date(from: DateComponents(year: Int(match.3), month: Int(match.2), day: Int(match.1), hour: 12))
            }
            let cells = block.split(separator: #/<td class=['"]?bunka_vozu/#, omittingEmptySubsequences: false).dropFirst()
            let coaches = cells.flatMap { vehicles(inCell: String($0)) }
            guard !coaches.isEmpty else { return nil }
            let notes = notes(inBlock: block)
            var composition = VagonwebComposition(
                validFrom: dates.first, validUntil: dates.count > 1 ? dates[1] : nil, coaches: coaches,
                reversalStations: reversalStations(fromNotes: block))
            composition.startsReversed = startsReversed(fromNotes: notes, reversals: composition.reversalStations)
            composition.coupledTrains = coupledTrains(fromNotes: notes)
            composition.section = heading.firstMatch(of: #/(?:section|Abschnitt)[^:]*:\s*<b>([^<]*)<\/b>/#.ignoresCase())
                .flatMap { Section(label: String($0.1).strippingTags) }
            return composition
        }
    }

    /// The vehicles of one position of the train. Where the vehicle there changes on the way (the
    /// locomotive), vagonweb stacks the alternatives in the cell, each with its section.
    static func vehicles(inCell cell: String) -> [Coach] {
        let labels = cell.matches(of: #/<div><b>[^<]*<\/b><\/div>/#).count
        guard labels > 1 else { return [coach(from: cell)] }
        let entries = cell.split(separator: #/<hr[^>]*>/#, omittingEmptySubsequences: false).map(String.init)
        // The class bar above the first vehicle belongs to every alternative.
        let header = cell.range(of: "vagonek").map { String(cell[..<$0.lowerBound]) } ?? ""
        return entries.enumerated().map { index, entry in coach(from: index == 0 ? entry : header + entry) }
    }

    /// vagonweb's notes of a composition: the English text and the German original of each ("Bad
    /// translation?" link), read first for station names as DB spells them.
    static func notes(inBlock block: String) -> [String] {
        var notes = block.matches(of: #/spatny_preklad2[^>]*text=(?:'([^']*)'|"([^"]*)")/#).map { String($0.1 ?? $0.2 ?? "").strippingTags }
        if let info = block.firstMatch(of: #/class=['"]?info_i['"]?>/#) {
            let rest = block[info.range.upperBound...]
            if let end = rest.range(of: "</div>") { notes.append(String(rest[..<end.lowerBound]).strippingTags) }
        }
        return notes
    }

    /// "Changes direction in Buchs SG, from Zürich until Buchs in reverse order": the stretch from the
    /// train's first station is the reverse of the drawing, which shows the train after Buchs. A stretch
    /// that starts at a station where the train changes direction anyway ("from Frankfurt until Basel"
    /// after "changes direction in Frankfurt …") is what counting the reversals already gives.
    static func startsReversed(fromNotes notes: [String], reversals: [String]) -> Bool {
        let pattern = #/(?:von|from)\s+(.+?)\s+(?:bis|until)\s+.+?\s+(?:in umgekehrter Reihung|in reverse order)/#.ignoresCase()
        let reversing = reversals.map(VagonwebClient.stationKey)
        for note in notes {
            guard let match = note.firstMatch(of: pattern) else { continue }
            let start = VagonwebClient.stationKey(String(match.1))
            if !start.isEmpty, !reversing.contains(where: { $0.hasPrefix(start) || start.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// "RJX 161 runs together with train RJX 184 …" / "… gemeinsam mit [link ÖBB RJX 184] geführt".
    static func coupledTrains(fromNotes notes: [String]) -> [String] {
        let pattern = #/(?:runs together with(?: train)?|gemeinsam mit)\s+(?:\[link\s+)?(?:[A-ZÖ]{2,4}\s+)?([A-Z]{1,4}\s\d+)/#.ignoresCase()
        var trains: [String] = []
        for note in notes {
            for match in note.matches(of: pattern) {
                let train = String(match.1).uppercased()
                if !trains.contains(train) { trains.append(train) }
            }
        }
        return trains
    }

    /// The stations in a composition's "changes direction in …" note. The note's German original
    /// (the `text` of its "Bad translation?" link) is read first, as it names the stations the way DB does.
    static func reversalStations(fromNotes block: String) -> [String] {
        let notes = notes(inBlock: block)
        let pattern = #/(?:fahrtrichtungswechsel|richtungswechsel|wechsel der fahrtrichtung|changes? (?:of )?direction|direction change)\s+(?:in|at)\s+(.+)/#.ignoresCase()
        for note in notes {
            guard let match = note.firstMatch(of: pattern) else { continue }
            // The list ends where the note goes on ("…, von Frankfurt bis Basel …", "…, from Frankfurt …").
            var list = Substring(match.1)
            if let end = list.firstMatch(of: #/,\s*(?:von|ab|bis|dort|danach|from|until|then)\s|;|\s[–-]\s/#.ignoresCase()) {
                list = list[..<end.range.lowerBound]
            }
            // A sentence ending ("… Leipzig Hbf. Ab …"), but not an abbreviation like "St. Gallen".
            if let end = list.firstMatch(of: #/[A-Za-zäöüß]{3}\.(?:\s|$)/#) {
                list = list[..<list.index(end.range.lowerBound, offsetBy: 3)]
            }
            let stations = list.replacing(#/\s+(?:und|and)\s+/#, with: ",")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:"))) }
                .map { $0.replacing(#/^(?:in|at)\s+/#, with: "") }
                .filter { !$0.isEmpty }
            if !stations.isEmpty { return stations }
        }
        return []
    }

    static func coach(from cell: String) -> Coach {
        let icons = cell.matches(of: #/popisy/ico/([A-Za-z0-9_]+)\.svg['"][^>]*>\s*(\d*)/#).map { (String($0.1), Int($0.2)) }
        let count = { (name: String) in icons.first { $0.0 == name }?.1 }
        let has = { (name: String) in icons.contains { $0.0 == name } }
        // The class bar over a coach (`tab-2tr`) and the pictograms' titles, for coaches whose class icon has no file name to read.
        let hasClass = { (name: String) in cell.hasClass(name) }
        let titles = cell.matches(of: #/class=['"]?pikto['"]?[^>]*?title=(?:'([^']*)'|"([^"]*)")/#).map { String($0.1 ?? $0.2 ?? "") }
        let titled = { (text: String) in titles.contains { $0.contains(text) } }
        let baureihe = cell.firstMatch(of: #/popisy/img/DB/(\d{3})-/#).map { String($0.1) }
        let notes = cell.split(separator: #/<div class=['"]?maly['"]?>/#, omittingEmptySubsequences: false).dropFirst().compactMap { part -> String? in
            guard let text = part.components(separatedBy: "</div>").first?.strippingTags, !text.isEmpty else { return nil }
            return text
        }
        let section = cell.firstMatch(of: #/<div><b>([^<]*)<\/b><\/div>/#).flatMap { Section(label: String($0.1).strippingTags) }
        return Coach(
            number: cell.text(ofClass: "raz-cislo")?.strippingTags.nonEmpty,
            series: cell.text(ofClass: "tab-radam")?.strippingTags.nonEmpty,
            typeCode: cell.between("<small>", "</small>")?.strippingTags.nonEmpty,
            baureihe: baureihe,
            firstClass: has("tr1") || hasClass("tab-1tr") || hasClass("tab-club") || titled("1st class"),
            secondClass: has("tr2") || hasClass("tab-2tr") || titled("2nd class"),
            diningSeats: has("jidel") ? count("jidel") ?? 0 : nil,
            hasBar: has("bar"),
            bikeSpaces: count("kolo"),
            wheelchairSpaces: has("inv3") || has("inv2") || has("inv1") ? count("inv3") ?? count("inv2") ?? count("inv1") ?? 0 : nil,
            hasInfoPoint: has("info"),
            notes: notes,
            sleeper: hasClass("tab-luzk"),
            couchette: hasClass("tab-lehat"),
            carCarrier: hasClass("tab-sluz"),
            section: section,
            restriction: notes.lazy.compactMap { DayRestriction(note: $0) }.first)
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

    /// The class attribute of a tag that is `name` (or has it among several), written `class=name`,
    /// `class='name'` or `class="name"`.
    private func classTag(_ name: String) -> Regex<Substring>? {
        try? Regex("class=['\"]?\(NSRegularExpression.escapedPattern(for: name))['\" ][^>]*>|class=['\"]?\(NSRegularExpression.escapedPattern(for: name))>")
    }

    func hasClass(_ name: String) -> Bool {
        guard let pattern = classTag(name) else { return false }
        return firstMatch(of: pattern) != nil
    }

    /// The text of the first element with the class `name`, up to the next tag.
    func text(ofClass name: String) -> String? {
        guard let pattern = classTag(name), let tag = firstMatch(of: pattern) else { return nil }
        let rest = self[tag.range.upperBound...]
        return String(rest[..<(rest.firstIndex(of: "<") ?? rest.endIndex)])
    }
}
