import BetterBahnKit
import CoreLocation
import EventKit
import Foundation

/// Calendar events for saved journeys (#382). Which event belongs to which journey is kept per device
/// (`CalendarEventLog`), like the calendar access. With `CalendarAccessMode.full` the events follow
/// the journey's latest data and go when it's deleted; with `.addOnly` they're written once. The IDs
/// are kept either way, so switching to full access later keeps the earlier events current too.
extension AppModel {
    nonisolated enum CalendarError: Error {
        case noAccess, notSaved
    }

    func isInCalendar(_ entry: SavedJourney) -> Bool {
        calendarEventIDs[entry.id] != nil
    }

    /// Adds the journey's event, after asking iOS for the access `settings.calendarAccess` needs.
    func addToCalendar(_ entry: SavedJourney) async throws {
        let mode = settings.calendarAccess ?? .full
        guard let store = await requestCalendarAccess(mode) else { throw CalendarError.noAccess }
        // Asking may have taken a while: take the journey's latest data.
        guard let entry = savedJourneys.first(where: { $0.id == entry.id }) else { throw CalendarError.notSaved }
        try insertEvent(for: entry, in: store)
    }

    private func insertEvent(for entry: SavedJourney, in store: EKEventStore) throws {
        guard let content = calendarEvent(for: entry) else { throw CalendarError.notSaved }
        let event = EKEvent(eventStore: store)
        event.calendar = targetCalendar(in: store)
        Self.fill(event, with: content)
        try store.save(event, span: .thisEvent)
        if let id = event.eventIdentifier { calendarEventIDs[entry.id] = id }
        // Added once, by hand or by itself: auto-add doesn't bring it back after it's deleted in the calendar.
        CalendarAutoAddLog.insert(entry.id)
    }

    /// Asks iOS for the access `mode` needs (full access also covers adding). Nil when it's refused.
    func requestCalendarAccess(_ mode: CalendarAccessMode) async -> EKEventStore? {
        let status = EKEventStore.authorizationStatus(for: .event)
        let granted: Bool
        switch (mode, status) {
        case (_, .fullAccess), (.addOnly, .writeOnly): granted = true
        case (_, .notDetermined), (.full, .writeOnly):
            // A fresh store each time: one made before access was granted doesn't see it.
            let store = EKEventStore()
            switch mode {
            case .full: granted = (try? await store.requestFullAccessToEvents()) ?? false
            case .addOnly: granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
            }
            if granted {
                calendarStore = nil
                calendarAccessChanges += 1
            }
        default: granted = false
        }
        guard granted else { return nil }
        if let calendarStore { return calendarStore }
        let store = EKEventStore()
        calendarStore = store
        return store
    }

    /// The calendars new events can go to, for the setting; empty without full access, which reading them needs.
    func writableCalendars() -> [EKCalendar] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = calendarStore ?? EKEventStore()
        calendarStore = store
        return store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `settings.calendarID`'s calendar, else (also with add-only access, which can't look it up) the default one.
    private func targetCalendar(in store: EKEventStore) -> EKCalendar? {
        if let id = settings.calendarID, let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications {
            return calendar
        }
        return store.defaultCalendarForNewEvents
    }

    /// Coalesces the many changes to `savedJourneys` (every refresh) into one sync.
    func scheduleCalendarSync(after delay: Duration = .seconds(2)) {
        guard settings.calendarAutoAdd != .off || (settings.calendarAccess == .full && !calendarEventIDs.isEmpty) else { return }
        calendarSync?.cancel()
        calendarSync = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            syncCalendarEvents()
        }
    }

    /// Adds the events `settings.calendarAutoAdd` asks for, then (with full access) brings the events up to date
    /// with the saved journeys, removes those of deleted journeys and forgets those deleted in the calendar.
    private func syncCalendarEvents() {
        addDueCalendarEvents()
        guard settings.calendarAccess == .full, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let store = calendarStore ?? EKEventStore()
        calendarStore = store
        var ids = calendarEventIDs
        for (journeyID, eventID) in calendarEventIDs {
            guard let event = store.event(withIdentifier: eventID) else {
                ids[journeyID] = nil
                continue
            }
            guard let entry = savedJourneys.first(where: { $0.id == journeyID }) else {
                try? store.remove(event, span: .thisEvent, commit: false)
                ids[journeyID] = nil
                continue
            }
            guard let content = calendarEvent(for: entry), Self.fill(event, with: content) else { continue }
            try? store.save(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
        if ids != calendarEventIDs { calendarEventIDs = ids }
    }

    /// Adds the events of journeys due by `settings.calendarAutoAdd`, once each. Never asks for access: that
    /// happens when the setting is switched on.
    private func addDueCalendarEvents(now: Date = .now) {
        guard settings.calendarAutoAdd != .off, let mode = settings.calendarAccess else { return }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || (mode == .addOnly && status == .writeOnly) else { return }
        let added = CalendarAutoAddLog.load()
        let due = savedJourneys.filter { entry in
            calendarEventIDs[entry.id] == nil && !added.contains(entry.id) && settings.calendarAutoAdd.isDue(entry.journey, now: now)
        }
        guard !due.isEmpty else { return }
        let store = calendarStore ?? EKEventStore()
        calendarStore = store
        for entry in due { try? insertEvent(for: entry, in: store) }
        CalendarAutoAddLog.keep(only: Set(savedJourneys.map(\.id)))
    }

    private func calendarEvent(for entry: SavedJourney) -> JourneyCalendarEvent? {
        JourneyCalendarEvent(journey: entry.journey, reservations: reservations(for: entry),
                             link: LiveActivityLink.url(journeyID: entry.id.uuidString))
    }

    /// Writes `content` into `event`; false when it already said that.
    @discardableResult
    private static func fill(_ event: EKEvent, with content: JourneyCalendarEvent) -> Bool {
        let coordinate = content.coordinate
        guard event.title != content.title || event.startDate != content.start || event.endDate != content.end
                || event.notes != content.notes || event.url != content.url
                || event.structuredLocation?.title != content.location
                || event.structuredLocation?.geoLocation?.coordinate.latitude != coordinate?.latitude
                || event.structuredLocation?.geoLocation?.coordinate.longitude != coordinate?.longitude else { return false }
        event.title = content.title
        event.startDate = content.start
        event.endDate = content.end
        event.notes = content.notes
        event.url = content.url
        let location = EKStructuredLocation(title: content.location)
        if let coordinate {
            location.geoLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        event.structuredLocation = location
        return true
    }
}

/// The calendar event of each saved journey, by journey ID. Per device: events are written by this
/// device's calendar access.
enum CalendarEventLog {
    static let key = "calendarEventIDs"

    static func load() -> [UUID: String] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    static func save(_ ids: [UUID: String]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, $1) }), forKey: key)
    }
}

/// Journeys whose event was added once (by hand or automatically), so auto-add skips them. Per device.
enum CalendarAutoAddLog {
    static let key = "calendarAutoAdded"

    static func load() -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init))
    }

    static func insert(_ id: UUID) {
        save(load().union([id]))
    }

    /// Forgets deleted journeys.
    static func keep(only ids: Set<UUID>) {
        save(load().intersection(ids))
    }

    private static func save(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }
}
