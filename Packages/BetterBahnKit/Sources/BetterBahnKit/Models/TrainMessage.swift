import Foundation

/// A note about a train as DB Navigator shows it under "Aktuelle Informationen", e.g. "10:10 Keine
/// behindertengerechte Einrichtung" or "12:10 Reparatur an einem Signal". Comes from the message
/// codes in DB's own dispatching feed (see `TimetablesClient`).
public struct TrainMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Why the train is late ("Verspätungsgrund").
        case delay
        /// Anything else wrong with the train (missing coaches, no WLAN, no wheelchair access, ...).
        case notice
    }

    public var id: String { "\(kind.rawValue)|\(text)" }
    public var kind: Kind
    public var text: String
    /// When DB reported it, if known.
    public var timestamp: Date?

    public init(kind: Kind, text: String, timestamp: Date?) {
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }

    /// One message per text (the first report of it), oldest first.
    public static func merged(_ messages: [TrainMessage]) -> [TrainMessage] {
        var byID: [String: TrainMessage] = [:]
        for message in messages {
            if let known = byID[message.id], (known.timestamp ?? .distantPast) <= (message.timestamp ?? .distantPast) { continue }
            byID[message.id] = message
        }
        return byID.values.sorted {
            ($0.timestamp ?? .distantPast, $0.text) < ($1.timestamp ?? .distantPast, $1.text)
        }
    }
}

public extension Collection<TrainMessage> {
    var containsDelayReason: Bool { contains { $0.kind == .delay } }
}

/// Texts for the numeric message codes in DB's IRIS feed (the same list DB Navigator
/// uses). Codes below 70 and 99 are delay reasons, 70–98 are quality notices.
enum TrainMessageCodes {
    /// Codes that only say an earlier notice no longer applies, so they clear rather than show.
    static let clearing: [Int: Set<Int>] = [
        84: [80],                   // Zug verkehrt richtig gereiht
        88: Set(70...98),           // keine Qualitätsmängel
        89: [86, 87],               // Reservierungen sind wieder vorhanden
    ]

    static func text(for code: Int) -> String? {
        texts[code]
    }

    private static let texts: [Int: String] = [
        2: "Polizeiliche Ermittlung",
        3: "Feuerwehreinsatz an der Strecke",
        4: "Kurzfristiger Personalausfall",
        5: "Ärztliche Versorgung eines Fahrgastes",
        6: "Betätigen der Notbremse",
        7: "Personen im Gleis",
        8: "Notarzteinsatz am Gleis",
        9: "Streikauswirkungen",
        10: "Tiere im Gleis",
        11: "Unwetter",
        12: "Warten auf ein verspätetes Schiff",
        13: "Pass- und Zollkontrolle",
        14: "Technische Störung am Bahnhof",
        15: "Beeinträchtigung durch Vandalismus",
        16: "Entschärfung einer Fliegerbombe",
        17: "Beschädigung einer Brücke",
        18: "Umgestürzter Baum im Gleis",
        19: "Unfall an einem Bahnübergang",
        20: "Tiere im Gleis",
        21: "Warten auf Fahrgäste aus einem anderen Zug",
        22: "Witterungsbedingte Störung",
        23: "Feuerwehreinsatz auf Bahngelände",
        24: "Verspätung im Ausland",
        25: "Warten auf weitere Wagen",
        28: "Gegenstände im Gleis",
        29: "Ersatzverkehr mit Bus ist eingerichtet",
        31: "Bauarbeiten",
        32: "Verzögerung beim Ein-/Ausstieg",
        33: "Reparatur an der Oberleitung",
        34: "Reparatur an einem Signal",
        35: "Streckensperrung",
        36: "Reparatur am Zug",
        37: "Reparatur am Wagen",
        38: "Reparatur an der Strecke",
        39: "Anhängen von zusätzlichen Wagen",
        40: "Defektes Stellwerk",
        41: "Technische Störung an einem Bahnübergang",
        42: "Außerplanmäßige Geschwindigkeitsbeschränkung",
        43: "Verspätung eines vorausfahrenden Zuges",
        44: "Warten auf einen entgegenkommenden Zug",
        45: "Überholung durch einen anderen Zug",
        46: "Warten auf freie Einfahrt",
        47: "Verspätete Bereitstellung des Zuges",
        48: "Verspätung aus vorheriger Fahrt",
        55: "Technische Störung an einem anderen Zug",
        56: "Warten auf Fahrgäste aus einem Bus",
        57: "Zusätzlicher Halt zum Ein-/Ausstieg",
        58: "Umleitung des Zuges",
        59: "Schnee und Eis",
        60: "Reduzierte Geschwindigkeit wegen Sturm",
        61: "Türstörung",
        62: "Behobene technische Störung am Zug",
        63: "Technische Untersuchung am Zug",
        64: "Weichenstörung",
        65: "Erdrutsch",
        66: "Hochwasser",
        67: "Behördliche Anordnung",
        68: "Hohes Fahrgastaufkommen verlängert Ein- und Ausstieg",
        69: "Zug verkehrt mit verminderter Geschwindigkeit",
        70: "WLAN nicht verfügbar",
        71: "WLAN in einzelnen Wagen nicht verfügbar",
        72: "Info-/Entertainment nicht verfügbar",
        73: "Heute: Mehrzweckabteil vorne",
        74: "Heute: Mehrzweckabteil hinten",
        75: "Heute: 1. Klasse vorne",
        76: "Heute: 1. Klasse hinten",
        77: "Ohne 1. Klasse",
        79: "Ohne Mehrzweckabteil",
        80: "Abweichende Wagenreihung",
        82: "Mehrere Wagen fehlen",
        83: "Störung der fahrzeuggebundenen Einstiegshilfe",
        85: "Ein Wagen fehlt",
        86: "Keine Reservierungsanzeige",
        87: "Einzelne Wagen ohne Reservierungsanzeige",
        90: "Kein gastronomisches Angebot",
        91: "Fahrradmitnahme nicht möglich",
        92: "Eingeschränkte Fahrradmitnahme",
        93: "Keine behindertengerechte Einrichtung",
        94: "Ersatzbewirtung",
        95: "Ohne behindertengerechtes WC",
        96: "Überbesetzung mit Kulanzleistungen",
        97: "Überbesetzung ohne Kulanzleistungen",
        98: "Sonstige Qualitätsmängel",
        99: "Verzögerungen im Betriebsablauf",
    ]
}
