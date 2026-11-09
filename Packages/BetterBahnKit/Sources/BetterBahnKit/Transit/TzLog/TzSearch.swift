import Foundation

/// A trainset (Tz) as the train search shows it: its number and what the offline lists know about it (#502).
public struct TzDescription: Sendable, Hashable, Identifiable {
    public var number: Int
    /// "ICE 4".
    public var series: String?
    /// "7-teilig", where a series has several.
    public var variant: String?
    /// The Taufname, e.g. "Freiburg im Breisgau".
    public var name: String?
    /// The special livery, e.g. "Regenbogen".
    public var livery: String?

    public var id: Int { number }
    /// "Tz 8043".
    public var title: String { String(kit: "Tz %@", String(number)) }
    /// "ICE 4 · 7-teilig · Freiburg im Breisgau"; nil without any of them.
    public var detail: String? {
        let parts = [series, variant, name, livery].compactMap(\.self).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Finds trainsets by their number or name for the train search (#502): "Tz 8043", "8043", or part of a Taufname or
/// livery: "Hamburg" finds "Freie und Hansestadt Hamburg", "freib" "Freiburg im Breisgau". Offline, from the
/// fleet list, the names and the liveries.
public enum TzSearch {
    /// Every trainset the offline lists know, by number.
    static let all: [TzDescription] = {
        let fleet = TrainsetFleet.index(TrainsetFleet.all)
        let numbers = Set(fleet.keys).union(TrainsetNames.byUnit.keys).union(TrainsetLiveries.byUnit.keys)
        return numbers.sorted().map { number in
            TzDescription(number: number, series: fleet[number]?.series, variant: fleet[number]?.variant,
                          name: TrainsetNames.byUnit[number], livery: TrainsetLiveries.byUnit[number])
        }
    }()

    /// The trainset with this number, if any list knows it.
    public static func description(of number: Int) -> TzDescription? {
        all.first { $0.number == number }
    }

    /// The trainsets `text` could mean, best first: a number ("Tz 8043", "8043") finds that one, a name (three letters or
    /// more) finds those whose Taufname or livery has every typed word at the start of a word, or, from four letters
    /// on, inside one.
    public static func matches(_ text: String, limit: Int = 8) -> [TzDescription] {
        matches(text, in: all, limit: limit)
    }

    static func matches(_ text: String, in entries: [TzDescription], limit: Int) -> [TzDescription] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Self.number(in: trimmed) {
            return entries.filter { $0.number == number }
        }
        let words = Self.words(of: trimmed)
        guard words.joined().count >= 3 else { return [] }
        return entries.compactMap { entry -> (entry: TzDescription, score: Int)? in
            let candidates = Self.words(of: [entry.name, entry.livery].compactMap(\.self).joined(separator: " "))
            guard !candidates.isEmpty else { return nil }
            var score = 0
            for word in words {
                if candidates.contains(where: { $0.hasPrefix(word) }) {
                    score += candidates.contains(word) ? 0 : 1
                } else if word.count >= 4, candidates.contains(where: { $0.contains(word) }) {
                    score += 3
                } else {
                    return nil
                }
            }
            // Fewer words left over rank higher: the name "Hamburg" before "Freie und Hansestadt Hamburg".
            return (entry, score * 10 + candidates.count)
        }
        .sorted { ($0.score, $0.entry.number) < ($1.score, $1.entry.number) }
        .prefix(limit)
        .map(\.entry)
    }

    /// The number of "Tz 8043", "TZ8043", "Triebzug 8043" or a bare "8043" (up to four digits).
    static func number(in text: String) -> Int? {
        var rest = Substring(folded(text))
        for prefix in ["triebzug", "tz"] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
            break
        }
        rest = Substring(rest.trimmingCharacters(in: .whitespaces))
        guard (1...4).contains(rest.count), rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    /// Lower case, without accents ("Lübeck" → "lubeck", "ß" → "ss").
    static func folded(_ text: String) -> String {
        text.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The words of a text, folded; "Freiburg im Breisgau" → ["freiburg", "im", "breisgau"].
    static func words(of text: String) -> [String] {
        folded(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
