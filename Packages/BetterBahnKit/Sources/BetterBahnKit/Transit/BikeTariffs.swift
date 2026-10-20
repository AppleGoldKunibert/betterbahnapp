import Foundation

/// What a normal bike needs in regional trains and S-Bahns in Germany (#398): a bike ticket, nothing, or no bikes at
/// certain times, per Verkehrsverbund. Researched 2026-10-19 from the Verbünde's and DB's pages:
/// - A ride within one Verbund follows the Verbund's rules (Deutschlandtarif, Teil D).
/// - A ride across Verbund borders follows its state's rule, else DB's Fahrradtageskarte Nahverkehr, valid in all
///   regional trains nationwide.
/// - The Deutschlandticket never includes a bike. Regional trains never take bike reservations; bikes come along
///   while there is room.
/// Verbünde are found by district (`StationNames.district(of:)`, the AGS code in the DHID); a Verbund covering only part
/// of a district is left out of it, so the state rule or the nationwide ticket stands in there, which is always valid.
public struct BikeTariff: Sendable, Hashable {
    /// Weekday hours (Mon–Fri) as minutes after midnight, Berlin time: `start..<end`.
    public struct Hours: Sendable, Hashable {
        public var start: Int
        public var end: Int

        init(_ from: Int, _ to: Int, fromMinute: Int = 0, toMinute: Int = 0) {
            start = from * 60 + fromMinute
            end = to * 60 + toMinute
        }

        func contains(_ minute: Int) -> Bool { minute >= start && minute < end }

        /// "6–9", "6:30–8:30".
        var text: String {
            func time(_ minutes: Int) -> String {
                minutes % 60 == 0 ? "\(minutes / 60)" : String(format: "%d:%02d", minutes / 60, minutes % 60)
            }
            return "\(time(start))–\(time(end))"
        }
    }

    public enum Fare: Sendable, Hashable {
        /// Bikes ride free.
        case free
        /// Always this ticket, e.g. "VBB 24-Stunden-Karte Fahrrad".
        case ticket(String)
        /// This ticket on weekdays in `hours`, free otherwise (BW before 9, RP and Saarland before 9 …).
        case ticketOnWeekdays(String, [Hours])
    }

    /// "VBB", or the state for its own rule.
    public var name: String
    /// In RE and RB trains.
    public var regional: Fare
    /// In S-Bahns; the same as `regional` unless the Verbund has its own rule there.
    public var suburban: Fare
    /// Weekday hours without bikes in S-Bahns (HVV, VGN).
    public var suburbanBlackout: [Hours] = []
    /// A hint for S-Bahns that fits no rule above, e.g. MVV's Sperrzeit that only holds with its own bike ticket.
    public var suburbanNote: String?
    /// The districts (5-digit AGS codes) the Verbund covers.
    public var districts: Set<String> = []

    init(_ name: String, _ fare: Fare, suburban: Fare? = nil, suburbanBlackout: [Hours] = [], suburbanNote: String? = nil,
         districts: [String] = []) {
        self.name = name
        regional = fare
        self.suburban = suburban ?? fare
        self.suburbanBlackout = suburbanBlackout
        self.suburbanNote = suburbanNote
        self.districts = Set(districts)
    }

    // MARK: Which rule applies

    /// The rule for riding from `origin` to `destination` (districts): the Verbund both lie in, else the state's rule
    /// when both lie in one state with its own, else the Fahrradtageskarte Niedersachsen within Niedersachsen, Bremen
    /// and Hamburg, else DB's nationwide Fahrradtageskarte Nahverkehr.
    public static func tariff(from origin: String, to destination: String) -> BikeTariff {
        if let verbund = verbuende.first(where: { $0.districts.contains(origin) && $0.districts.contains(destination) }) {
            return verbund
        }
        let from = String(origin.prefix(2)), to = String(destination.prefix(2))
        if from == to, let state = states[from] { return state }
        let northern: Set<String> = ["02", "03", "04"]
        if northern.contains(from), northern.contains(to) { return states["03"]! }
        return nationwide
    }

    static let nationwide = BikeTariff("Deutschland", .ticket("Fahrradtageskarte Nahverkehr (7,50 €)"))

    private static let fromNine = [Hours(0, 9)]
    private static let morningPeak = [Hours(6, 9)]

    /// The states' own rules, by the first two digits of the AGS code.
    static let states: [String: BikeTariff] = [
        "01": BikeTariff("Schleswig-Holstein", .ticket("SH-Tarif Fahrradtageskarte (6 €)")),
        "02": hvv,
        "03": BikeTariff("Niedersachsen", .ticket("Fahrradtageskarte Niedersachsen (7 €)")),
        "04": BikeTariff("Bremen", .ticket("Fahrradtageskarte Niedersachsen (7 €)")),
        "05": BikeTariff("Nordrhein-Westfalen", .ticket("24hFahrradTicket NRW (6,30 €)")),
        "06": BikeTariff("Hessen", .free),
        "07": BikeTariff("Rheinland-Pfalz", .ticketOnWeekdays("Fahrkarte für das Fahrrad", fromNine)),
        "08": BikeTariff("Baden-Württemberg", .ticketOnWeekdays("bwFAHRRAD (6 €)", morningPeak)),
        "09": BikeTariff("Bayern", .ticket("Fahrrad-Tageskarte Bayern (7,50 €)")),
        "10": BikeTariff("Saarland", .ticketOnWeekdays("saarVV Einzelfahrkarte Rad (ab 2,60 €)", fromNine)),
        "11": vbb,
        "12": vbb,
        "13": BikeTariff("Mecklenburg-Vorpommern", .ticket("Fahrradtageskarte Nahverkehr (7,50 €)")),
        "14": BikeTariff("Sachsen", .ticket("Fahrradtageskarte Nahverkehr (7,50 €)")),
        "15": BikeTariff("Sachsen-Anhalt", .free),
        "16": BikeTariff("Thüringen", .free),
    ]

    static let vbb = BikeTariff("VBB", .ticket("VBB 24-Stunden-Karte Fahrrad (ab 5,10 €)"),
                                districts: ["11000", "12051", "12052", "12053", "12054"] + (60...73).map { "120\($0)" })

    /// HVV: free in S-Bahn (and U-Bahn, AKN) except on weekdays 6–9 and 16–18, when no bikes ride; a ticket in RE/RB.
    static let hvv = BikeTariff("HVV", .ticket("hvv Fahrradticket (3,50 €)"), suburban: .free,
                                suburbanBlackout: [Hours(6, 9), Hours(16, 18)],
                                districts: ["02000", "01053", "01056", "01060", "01061", "01062",
                                            "03352", "03353", "03354", "03355", "03357", "03358", "03359", "03360"])

    /// The Verbünde with their own rules. Where one isn't sure (VMS, VVV, ZVON, VVW, DING, HNV, VVM) the state rule or
    /// the nationwide ticket applies, which is valid there as well.
    static let verbuende: [BikeTariff] = [
        vbb,
        hvv,
        BikeTariff("GVH", .ticketOnWeekdays("GVH Fahrradkarte", [Hours(6, 8, fromMinute: 30, toMinute: 30), Hours(15, 19)]),
                   districts: ["03241"]),
        BikeTariff("VRB", .ticket("VRB Fahrradtageskarte (3,20 €)"),
                   districts: ["03101", "03102", "03103", "03151", "03153", "03154", "03157", "03158"]),
        BikeTariff("VBN", .ticket("VBN FahrradTicket (ab 2,50 €)"),
                   districts: ["04011", "04012", "03401", "03403", "03451", "03458", "03461", "03356", "03361", "03251",
                               "03460", "03453"]),
        BikeTariff("VRR", .ticket("VRR FahrradTicket (4,60 €)"),
                   districts: ["05111", "05112", "05113", "05114", "05116", "05117", "05119", "05120", "05122", "05124",
                               "05154", "05158", "05162", "05166", "05170", "05512", "05513", "05562", "05911", "05913",
                               "05914", "05916", "05954"]),
        BikeTariff("Rheinlandtarif", .ticket("24hTicket Fahrrad (4,50 €)"),
                   districts: ["05314", "05315", "05316", "05334", "05358", "05362", "05366", "05370", "05374", "05378",
                               "05382"]),
        BikeTariff("Westfalentarif", .ticket("FahrradTagesTicket24 Westfalen (3,50 €)"),
                   districts: ["05515", "05554", "05558", "05566", "05570", "05711", "05754", "05758", "05762", "05766",
                               "05770", "05774", "05915", "05958", "05962", "05966", "05970", "05974", "05978"]),
        BikeTariff("RMV", .free,
                   districts: ["06411", "06412", "06413", "06414", "06531", "06532", "06533", "06534", "06535", "06631"]
                       + (32...40).map { "064\($0)" }),
        BikeTariff("NVV", .free, districts: ["06611", "06632", "06633", "06634", "06635", "06636"]),
        BikeTariff("VRN", .ticketOnWeekdays("VRN Einzelfahrschein Fahrrad", morningPeak),
                   districts: ["08221", "08222", "08225", "08226", "06431", "07340"]
                       + (11...20).filter { $0 != 15 }.map { "073\($0)" } + (31...38).map { "073\($0)" }),
        BikeTariff("RNN", .ticketOnWeekdays("RNN Fahrkarte für das Fahrrad", fromNine),
                   districts: ["07315", "07339", "07133", "07134"]),
        BikeTariff("VRM", .ticketOnWeekdays("VRM Einzelfahrschein, ermäßigt", fromNine),
                   districts: ["07111", "07131", "07132", "07135", "07137", "07138", "07140", "07141", "07143"]),
        BikeTariff("VRT", .ticketOnWeekdays("VRT EinzelTicket Fahrrad", fromNine),
                   districts: ["07211", "07231", "07232", "07233", "07235"]),
        BikeTariff("saarVV", .ticketOnWeekdays("saarVV Einzelfahrkarte Rad (ab 2,60 €)", fromNine),
                   districts: (41...46).map { "100\($0)" }),
        BikeTariff("VVS", .ticketOnWeekdays("VVS KinderTicket", morningPeak),
                   districts: ["08111", "08115", "08116", "08117", "08118", "08119"]),
        BikeTariff("KVV", .ticketOnWeekdays("KVV Fahrradkarte", morningPeak), districts: ["08211", "08212", "08215", "08216"]),
        BikeTariff("naldo", .ticketOnWeekdays("naldo Fahrradfahrschein", morningPeak),
                   districts: ["08415", "08416", "08417", "08437"]),
        BikeTariff("bodo", .ticketOnWeekdays("bodo Fahrradticket", morningPeak), districts: ["08435", "08436"]),
        BikeTariff("RVF", .ticketOnWeekdays("RVF Fahrradkarte", morningPeak), districts: ["08311", "08315", "08316"]),
        BikeTariff("MVV", .ticket("MVV Fahrrad-Tageskarte (3,70 €)"),
                   suburbanNote: "In der S-Bahn Mo–Fr 6–9 Uhr nur mit Fahrrad-Tageskarte Bayern",
                   districts: ["09162", "09163", "09173", "09174", "09175", "09177", "09178", "09179", "09180", "09181",
                               "09182", "09183", "09184", "09187", "09188", "09190", "09261", "09274"]),
        BikeTariff("VGN", .ticket("VGN Einzelfahrkarte Kind"), suburbanBlackout: [Hours(6, 8)],
                   districts: ["09361", "09371", "09373", "09461", "09462", "09471", "09472", "09474", "09561", "09562",
                               "09563", "09564", "09565", "09571", "09572", "09573", "09574", "09575", "09576", "09577"]),
        BikeTariff("AVV", .ticket("AVV Fahrrad-Tagesticket (2,40 €)"), districts: ["09761", "09771", "09772"]),
        BikeTariff("RVV", .ticket("RVV Kinderfahrkarte"), districts: ["09362", "09375"]),
        BikeTariff("MDV", .free, districts: ["14713", "14729", "14730", "15002", "15084", "15088", "16077"]),
        BikeTariff("VVO", .ticket("VVO Fahrrad-Tageskarte (ab 2,40 €)"), districts: ["14612", "14627", "14628"]),
    ]

    // MARK: Applying it

    /// What a normal bike needs on a train of `product` leaving at `departure`.
    func transport(for product: Product, departure: Date) -> BikeTransport {
        let (weekday, minute) = Self.weekdayAndMinute(of: departure)
        let isSuburban = product == .suburban
        if isSuburban, weekday, suburbanBlackout.contains(where: { $0.contains(minute) }) {
            return BikeTransport(kind: .notAllowed, isConfirmed: false,
                                 note: "Mo–Fr \(Self.hoursText(suburbanBlackout)) Uhr keine Fahrräder in der S-Bahn")
        }
        var transport = BikeTransport(kind: .allowed, isConfirmed: false)
        switch isSuburban ? suburban : regional {
        case .free:
            break
        case .ticket(let ticket):
            transport.ticket = ticket
        case .ticketOnWeekdays(let ticket, let hours):
            if weekday, hours.contains(where: { $0.contains(minute) }) {
                transport.ticket = ticket
                transport.note = "Nur Mo–Fr \(Self.hoursText(hours)) Uhr kostenpflichtig"
            } else {
                transport.note = "Mo–Fr \(Self.hoursText(hours)) Uhr: \(ticket)"
            }
        }
        if isSuburban, let note = suburbanNote { transport.note = note }
        if isSuburban, transport.note == nil, !suburbanBlackout.isEmpty {
            transport.note = "Mo–Fr \(Self.hoursText(suburbanBlackout)) Uhr keine Fahrräder in der S-Bahn"
        }
        return transport
    }

    /// "6–9 und 16–18"; hours from midnight read "vor 9".
    static func hoursText(_ hours: [Hours]) -> String {
        if hours.count == 1, hours[0].start == 0 { return "vor \(hours[0].end / 60)" }
        let texts = hours.map(\.text)
        guard texts.count > 1 else { return texts.first ?? "" }
        return texts.dropLast().joined(separator: ", ") + " und " + texts.last!
    }

    /// Whether `date` falls on Monday to Friday, and its minute of the day, in Berlin. Public holidays and school
    /// holidays (when HVV and MVV lift their Sperrzeiten) aren't known here.
    static func weekdayAndMinute(of date: Date) -> (weekday: Bool, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let weekday = (2...6).contains(parts.weekday ?? 1)
        return (weekday, (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}
