import Foundation

/// A journey the user takes on the same weekdays again and again (#397), e.g. Mon–Fri RE 3 at 7:42
/// Eberswalde → Berlin Gesundbrunnen. On each of those days the app asks shortly before the departure
/// whether the user rides today ("Fährst du heute?"); a yes saves that day's run of the same trains as a
/// normal saved journey (`RegularTripPlanner`), which then only reports problems (`CommuteAlerts`).
public struct RegularTrip: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The journey it was set up from. Its trains are looked up again for every day (by name, run number
    /// and planned time), the walks between them are taken over as they are.
    public var template: Journey
    /// The days it runs on, ISO weekdays: 1 = Monday … 7 = Sunday.
    public var weekdays: Set<Int>
    /// How many minutes before the first departure the question comes.
    public var questionLead: Int
    /// Delays from this many minutes on are reported; smaller ones stay quiet.
    public var delayThreshold: Int
    /// No questions up to and including this day ("Pausieren bis …", e.g. for holidays).
    public var pausedUntil: Date?
    public var createdAt: Date

    public static let defaultQuestionLead = 30
    public static let defaultDelayThreshold = 5
    /// How far ahead the questions are scheduled; the app schedules them again whenever it runs.
    public static let questionDays = 14

    public init(id: UUID = UUID(), template: Journey, weekdays: Set<Int>, questionLead: Int = RegularTrip.defaultQuestionLead,
                delayThreshold: Int = RegularTrip.defaultDelayThreshold, pausedUntil: Date? = nil, createdAt: Date = .now) {
        self.id = id
        self.template = RegularTrip.cleaned(template)
        self.weekdays = weekdays
        self.questionLead = questionLead
        self.delayThreshold = delayThreshold
        self.pausedUntil = pausedUntil
        self.createdAt = createdAt
    }

    /// Set up from `journey`: on its own weekday, or Monday to Friday when it runs on a working day.
    public init(journey: Journey) {
        let weekday = journey.departure.map { Self.weekday(of: $0.planned) } ?? 1
        self.init(template: journey, weekdays: weekday <= 5 ? [1, 2, 3, 4, 5] : [weekday])
    }

    // MARK: Days

    /// German time, which the timetable is in; weeks start on Monday.
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// ISO weekday of `date` in German time: 1 = Monday … 7 = Sunday.
    public static func weekday(of date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// "2026-10-19" for the (German) day of `date`.
    public static func dayKey(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of the day `key` ("2026-10-19") names, in German time.
    public static func day(forKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public func isPaused(on day: Date) -> Bool {
        guard let pausedUntil else { return false }
        return Self.calendar.startOfDay(for: day) <= Self.calendar.startOfDay(for: pausedUntil)
    }

    /// Whether the user rides on the day of `day` (a chosen weekday and not paused).
    public func isTravelDay(_ day: Date) -> Bool {
        weekdays.contains(Self.weekday(of: day)) && !isPaused(on: day)
    }

    /// The first departure on the day of `day`, at the template's (German) time of day.
    public func departure(on day: Date) -> Date? {
        template.departure.map { moving($0.planned, to: day) }
    }

    /// `date` (a time of the template's journey) on the day of `day`: same time of day, same number of days
    /// after the journey's first departure (a ride past midnight). Keeps the wall-clock time across a DST change.
    func moving(_ date: Date, to day: Date) -> Date {
        let calendar = Self.calendar
        guard let start = template.departure?.planned else { return date }
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: date)).day ?? 0
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let target = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: day)) else { return date }
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: target) ?? date
    }

    // MARK: Questions

    /// One "Fährst du heute?" question: for the travel day `dayKey`, shown at `date`.
    public struct Question: Sendable, Hashable {
        public var tripID: UUID
        public var dayKey: String
        public var date: Date
        public var departure: Date

        /// The notification's identifier: one per trip and day, so scheduling again replaces it.
        public var notificationID: String { "\(RegularTrip.questionPrefix)\(tripID.uuidString)|\(dayKey)" }
    }

    /// Prefix of every question's notification identifier, to find and replace them all.
    public static let questionPrefix = "commute-question|"

    /// The questions still to come within `days` days from `now`, skipping the days in `answered`
    /// (already saved, e.g. on another device). A question whose time has passed isn't asked any more.
    public func questions(from now: Date, days: Int = RegularTrip.questionDays, answered: Set<String> = []) -> [Question] {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset -> Question? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), isTravelDay(day),
                  !answered.contains(Self.dayKey(of: day)), let departure = departure(on: day) else { return nil }
            let date = departure.addingTimeInterval(-Double(questionLead * 60))
            guard date > now else { return nil }
            return Question(tripID: id, dayKey: Self.dayKey(of: day), date: date, departure: departure)
        }
    }

    /// The trip and day a question's notification identifier names.
    public static func question(fromNotificationID identifier: String) -> (tripID: UUID, dayKey: String)? {
        guard identifier.hasPrefix(questionPrefix) else { return nil }
        let parts = identifier.dropFirst(questionPrefix.count).split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), day(forKey: String(parts[1])) != nil else { return nil }
        return (id, String(parts[1]))
    }

    /// The saved journey's ID for the day `dayKey`: the same on every device, so two devices answering
    /// yes save one journey, not two.
    public func journeyID(forDay dayKey: String) -> UUID {
        var bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        for (index, byte) in dayKey.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        // Version 4 / RFC 4122 variant bits, so it reads as an ordinary UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Text

    /// "RE 3 7:42 Eberswalde Hbf → Berlin Gesundbrunnen".
    public var summary: String {
        let trains = template.transitLegs.compactMap { $0.line?.displayName }.joined(separator: ", ")
        let time = template.departure.map { Self.timeString($0.planned) } ?? ""
        return [trains, time, route].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Eberswalde Hbf → Berlin Gesundbrunnen".
    public var route: String {
        [template.legs.first?.origin.displayName, template.legs.last?.destination.displayName]
            .compactMap { $0 }.joined(separator: " → ")
    }

    /// "Mo–Fr", "Mo, Mi, Fr", "Sa, So", "täglich".
    public var weekdaysDescription: String {
        let days = weekdays.sorted()
        if days == Array(1...7) { return "täglich" }
        if days.count >= 3, days.last! - days.first! == days.count - 1 {
            return "\(Self.weekdayNames[days.first! - 1])–\(Self.weekdayNames[days.last! - 1])"
        }
        return days.map { Self.weekdayNames[$0 - 1] }.joined(separator: ", ")
    }

    public static let weekdayNames = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    static func timeString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The question's text: "RE 3 um 7:42 ab Eberswalde Hbf nach Berlin Gesundbrunnen".
    public func questionBody(departure: Date) -> String {
        let trains = template.transitLegs.first?.line?.displayName ?? "Zug"
        let origin = template.legs.first?.origin.displayName ?? ""
        let destination = template.legs.last?.destination.displayName ?? ""
        return "\(trains) um \(Self.timeString(departure)) ab \(origin) nach \(destination)"
    }

    // MARK: Template

    /// Whether `journey` rides the same trains between the same stations as this trip's template, at the
    /// same time of day (any day): the journey a trip was set up from, or one of its days.
    public func matches(_ journey: Journey) -> Bool {
        let mine = template.transitLegs, theirs = journey.transitLegs
        guard mine.count == theirs.count, !mine.isEmpty else { return false }
        return zip(mine, theirs).allSatisfy { a, b in
            a.origin.isSamePlace(as: b.origin) && a.destination.isSamePlace(as: b.destination)
                && Self.timeString(a.departure.planned) == Self.timeString(b.departure.planned)
                && RegularTripPlanner.isSameTrain(a.line, b.line)
        }
    }

    /// The template without what belongs to the day it was saved on: live times, platform changes,
    /// cancellations, messages and the track's geometry (kept small, it syncs with the list).
    static func cleaned(_ journey: Journey) -> Journey {
        var journey = journey.droppingActualTimes()
        for index in journey.legs.indices {
            journey.legs[index].geometry = nil
            journey.legs[index].cancelled = false
            journey.legs[index].messages = []
            journey.legs[index].departurePlatform?.actual = nil
            journey.legs[index].arrivalPlatform?.actual = nil
            for stop in journey.legs[index].stopovers.indices {
                journey.legs[index].stopovers[stop].arrivalPlatform?.actual = nil
                journey.legs[index].stopovers[stop].departurePlatform?.actual = nil
                journey.legs[index].stopovers[stop].arrivalCancelled = false
                journey.legs[index].stopovers[stop].departureCancelled = false
            }
        }
        return journey
    }

    /// The template moved to the day of `day`, as planned: the stand-in for a train that can't be looked
    /// up (offline, no board), which DB's live data can still fill in by name and station.
    public func plannedJourney(on day: Date) -> Journey {
        var journey = template
        for index in journey.legs.indices {
            journey.legs[index] = plannedLeg(journey.legs[index], on: day)
        }
        return journey
    }

    func plannedLeg(_ leg: Leg, on day: Date) -> Leg {
        var leg = leg
        leg.departure = TimeInfo(planned: moving(leg.departure.planned, to: day), actual: nil)
        leg.arrival = TimeInfo(planned: moving(leg.arrival.planned, to: day), actual: nil)
        // The template day's trip ID names that day's run only.
        if !leg.isWalking { leg.tripId = nil }
        for index in leg.stopovers.indices {
            if let arrival = leg.stopovers[index].arrival {
                leg.stopovers[index].arrival = TimeInfo(planned: moving(arrival.planned, to: day), actual: nil)
            }
            if let departure = leg.stopovers[index].departure {
                leg.stopovers[index].departure = TimeInfo(planned: moving(departure.planned, to: day), actual: nil)
            }
        }
        return leg
    }
}

/// What ties a saved journey to the regular trip it was made from (#397), so it only reports problems.
public struct CommuteDay: Codable, Sendable, Hashable {
    public var tripID: UUID
    /// The travel day, "2026-10-19".
    public var dayKey: String
    /// Delays from this many minutes on are reported.
    public var delayThreshold: Int

    public init(tripID: UUID, dayKey: String, delayThreshold: Int) {
        self.tripID = tripID
        self.dayKey = dayKey
        self.delayThreshold = delayThreshold
    }
}
