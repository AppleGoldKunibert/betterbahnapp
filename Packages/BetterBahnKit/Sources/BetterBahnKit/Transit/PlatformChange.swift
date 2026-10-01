import Foundation

/// A train of a saved journey now uses another platform than at the last refresh — at the start,
/// a transfer or the destination.
public struct PlatformChange: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case departure, arrival
    }

    public var kind: Kind
    public var line: String
    public var station: String
    public var oldPlatform: String
    public var newPlatform: String
    /// Minutes between arriving and the next train's departure, when the change is at a transfer.
    public var transferMinutes: Int?
    /// The leg the change belongs to, so the same platform at another stop isn't mistaken for it.
    public var legID: String

    /// Contains the new platform: each change notifies once, and switching back notifies again.
    public var id: String { "platform|\(kind.rawValue)|\(legID)|\(newPlatform)" }

    /// A transfer this short makes the change urgent.
    public var isTight: Bool { transferMinutes.map { $0 < 5 } ?? false }

    /// "ICE 578: Gleiswechsel"
    public var title: String { "\(line): Gleiswechsel" }

    /// "Abfahrt Frankfurt (Main) Hbf jetzt von Gleis 9 (statt 7)\nUmstieg: 6 Min."
    public var message: String {
        let text = "\(kind == .departure ? "Abfahrt" : "Ankunft") \(station) jetzt \(kind == .departure ? "von" : "auf") Gleis \(newPlatform) (statt \(oldPlatform))"
        return transferMinutes.map { text + "\nUmstieg: \($0) Min." } ?? text
    }
}

public extension PlatformInfo {
    /// The track number without its sector ("7 A–C" → "7"), so a sector change or another way of
    /// writing it isn't a change. `nil` for platforms without a number, e.g. a bus bay "F" some feeds
    /// give trains instead of their track (see #30), which can't be compared.
    static func track(_ platform: String?) -> String? {
        guard let platform else { return nil }
        let digits = platform.trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }

    /// Whether `a` and `b` are really different tracks (both must have a number).
    static func isDifferentTrack(_ a: String?, _ b: String?) -> Bool {
        guard let a = track(a), let b = track(b) else { return false }
        return a != b
    }
}

public extension Journey {
    /// Platforms that changed since `previous` (the same journey at its last refresh) for departures
    /// and arrivals within `window` from `now` — changes days ahead are timetable updates, not news.
    func platformChanges(since previous: Journey, now: Date = .now, window: TimeInterval = 2 * 3600) -> [PlatformChange] {
        let legs = transitLegs, oldLegs = previous.transitLegs
        guard legs.count == oldLegs.count else { return [] }
        let soon = { (time: Date) in time >= now && time <= now.addingTimeInterval(window) }
        var changes: [PlatformChange] = []
        for index in legs.indices {
            let leg = legs[index], old = oldLegs[index]
            guard leg.id == old.id, !leg.cancelled else { continue }
            let line = leg.line?.name ?? "Zug"
            if soon(leg.departure.best),
               let new = leg.departurePlatform?.best, let before = old.departurePlatform?.best,
               PlatformInfo.isDifferentTrack(before, new) {
                let transfer = index > 0 ? Self.minutes(from: legs[index - 1].arrival.best, to: leg.departure.best) : nil
                changes.append(PlatformChange(kind: .departure, line: line, station: leg.origin.displayName,
                                              oldPlatform: before, newPlatform: new, transferMinutes: transfer, legID: leg.id))
            }
            if soon(leg.arrival.best),
               let new = leg.arrivalPlatform?.best, let before = old.arrivalPlatform?.best,
               PlatformInfo.isDifferentTrack(before, new) {
                let transfer = index + 1 < legs.count ? Self.minutes(from: leg.arrival.best, to: legs[index + 1].departure.best) : nil
                changes.append(PlatformChange(kind: .arrival, line: line, station: leg.destination.displayName,
                                              oldPlatform: before, newPlatform: new, transferMinutes: transfer, legID: leg.id))
            }
        }
        return changes
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) / 60).rounded(.down))
    }
}
