import Foundation

/// The days a coach runs on, as vagonweb notes them below it: "runs on ⑥, ⑦ until 13.6. and from 17.10.,
/// on 24., 25., 26., 31.12., 1., 2., …" (Saturdays and Sundays until 13 June and from 17 October, and the
/// holidays listed) or "runs until 02.02.". Circled digits are the weekdays, ① Monday to ⑦ Sunday.
///
/// Only a note that is read completely becomes a restriction. Anything else (another wording, "not on …",
/// weekday names) is no restriction, so a coach is never left out on a guess.
struct DayRestriction: Sendable, Hashable {
    struct MonthDay: Sendable, Hashable, Comparable {
        var month: Int
        var day: Int

        init?(month: Int, day: Int) {
            guard (1...12).contains(month), (1...31).contains(day) else { return nil }
            self.month = month
            self.day = day
        }

        /// Days into the timetable year, which starts on 14 December (a year-less date can't be told by year).
        var position: Int {
            if month == 12, day >= 14 { return day - 14 }
            let before = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
            return 18 + before[month - 1] + day - 1
        }

        static func < (a: MonthDay, b: MonthDay) -> Bool { a.position < b.position }
    }

    /// 1 = Monday … 7 = Sunday; empty: every day.
    var weekdays: Set<Int>
    var until: MonthDay?
    var from: MonthDay?
    /// The extra days it runs on regardless of weekday and period (the holidays).
    var extraDays: Set<MonthDay>

    /// `nil` unless the whole note is understood.
    init?(note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.firstMatch(of: #/^runs\s+(?:on|from|until)\b/#.ignoresCase()) != nil else { return nil }
        var main = note
        var extras: [MonthDay] = []
        if let match = note.firstMatch(of: #/,\s*on\s+(.+)$/#.ignoresCase()) {
            guard let days = Self.days(in: String(match.1)) else { return nil }
            extras = days
            main = String(note[..<match.range.lowerBound])
        } else if let match = note.firstMatch(of: #/^runs\s+on\s+(.+)$/#.ignoresCase()), let days = Self.days(in: String(match.1)) {
            // Only dates: "runs on 24., 25.12."
            extras = days
            main = "runs"
        }
        var weekdays: Set<Int> = []
        for scalar in main.unicodeScalars where (0x2460...0x2467).contains(scalar.value) {
            // ① … ⑦ are Monday to Sunday; ⑧ is something else (holidays), which isn't read.
            let number = Int(scalar.value - 0x2460) + 1
            guard number <= 7 else { return nil }
            weekdays.insert(number)
        }
        var until: MonthDay?
        if let match = main.firstMatch(of: #/\buntil\s+(\d{1,2})\.(\d{1,2})\./#.ignoresCase()) {
            guard let date = MonthDay(month: Int(match.2)!, day: Int(match.1)!) else { return nil }
            until = date
        }
        var from: MonthDay?
        if let match = main.firstMatch(of: #/\bfrom\s+(\d{1,2})\.(\d{1,2})\./#.ignoresCase()) {
            guard let date = MonthDay(month: Int(match.2)!, day: Int(match.1)!) else { return nil }
            from = date
        }
        // Nothing but these words, the weekdays and the dates may be left.
        var rest = main
        for piece in [#"\b(until|from)\s+\d{1,2}\.\d{1,2}\."#, #"\b(runs|on|and)\b"#, "[①②③④⑤⑥⑦]", #"[\s,]"#] {
            rest = rest.replacingOccurrences(of: piece, with: "", options: [.regularExpression, .caseInsensitive])
        }
        guard rest.isEmpty, !weekdays.isEmpty || until != nil || from != nil || !extras.isEmpty else { return nil }
        self.weekdays = weekdays
        self.until = until
        self.from = from
        self.extraDays = Set(extras)
    }

    /// "24., 25., 26., 31.12., 1., 2., 5., 6.1." → every day takes the month of the next one that names it.
    /// `nil` when something else is in the list or a day has no month to take.
    static func days(in text: String) -> [MonthDay]? {
        let tokens = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var month: Int?
        var days: [MonthDay] = []
        for token in tokens.reversed() {
            let numbers = token.split(separator: ".").compactMap { Int($0) }
            guard token.hasSuffix("."), numbers.count == 1 || numbers.count == 2,
                  token.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
            if numbers.count == 2 { month = numbers[1] }
            guard let month, let day = MonthDay(month: month, day: numbers[0]) else { return nil }
            days.append(day)
        }
        return days
    }

    /// Whether the coach runs on the operating day with this month, day and weekday (1 = Monday … 7 = Sunday).
    func runs(month: Int, day: Int, weekday: Int) -> Bool {
        guard let today = MonthDay(month: month, day: day) else { return true }
        if extraDays.contains(today) { return true }
        if !weekdays.isEmpty, !weekdays.contains(weekday) { return false }
        switch (until, from) {
        case let (until?, from?): return until < from ? (today <= until || today >= from) : (today >= from && today <= until)
        case let (until?, nil): return today <= until
        case let (nil, from?): return today >= from
        case (nil, nil): return !weekdays.isEmpty
        }
    }
}
