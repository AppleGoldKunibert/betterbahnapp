import BetterBahnKit
import Foundation
import UserNotifications

/// Exit reminders (#313): a notification shortly before arriving where the user gets off, moved with
/// every refresh and shown only once per stop. While the journey's Live Activity runs, a refresh
/// shortly before that time alerts through the activity instead.
extension AppModel {
    /// Identifiers of exit reminder notifications start with this (see `AppDelegate`'s `willPresent`).
    nonisolated static let exitReminderPrefix = "exit|"

    /// Reminders are planned this far ahead; later journeys get theirs at a later refresh.
    private static let exitReminderHorizon: TimeInterval = 24 * 3600

    /// Coalesces the many changes to `savedJourneys` (refreshes, edits) into one sync. Syncs run one
    /// after another, so two never schedule (or alert) the same reminder.
    @discardableResult
    func scheduleExitReminderSync(after delay: Duration = .seconds(1)) -> Task<Void, Never> {
        // A waiting sync is superseded (its sleep ends now); one already running finishes first.
        let previous = exitReminderSync
        previous?.cancel()
        exitReminderGeneration += 1
        let generation = exitReminderGeneration
        let task = Task {
            await previous?.value
            try? await Task.sleep(for: delay)
            guard generation == exitReminderGeneration else { return }
            await syncExitReminders()
        }
        exitReminderSync = task
        return task
    }

    /// Schedules, moves and removes the exit reminders so they match the saved journeys' latest data.
    private func syncExitReminders(now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        var scheduled = ExitReminderLog.load()
        var wanted: [String: (reminder: ExitReminder, journey: Journey)] = [:]
        if settings.exitReminders {
            for entry in upcomingJourneys where entry.exitRemindersOff != true
                && (entry.journey.departure?.best ?? .distantFuture) < now.addingTimeInterval(Self.exitReminderHorizon) {
                let prefix = Self.exitReminderPrefix + entry.id.uuidString + "|"
                // The log is keyed by notification identifier, the Kit by `ExitReminder.id`.
                let known = Dictionary(entry.journey.transitLegs.compactMap { leg in
                    scheduled[prefix + leg.id].map { ("exit|\(leg.id)", $0) }
                }, uniquingKeysWith: { first, _ in first })
                for reminder in entry.journey.exitReminders(lead: settings.exitReminderLead.interval, now: now,
                                                            scheduled: known, dispositions: transferDispositions) {
                    wanted[prefix + reminder.legID] = (reminder, entry.journey)
                }
            }
        }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.exitReminderPrefix) }
        // Ones due any moment are left alone: they count as shown.
        let stale = pending.filter { wanted[$0] == nil && (scheduled[$0] ?? .distantFuture) > now }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for id in stale { scheduled[id] = nil }
        for (identifier, item) in wanted {
            let reminder = item.reminder
            // The app refreshes the live journey every minute or two: the last refresh before the
            // reminder's time alerts through the Live Activity, and the notification is dropped.
            if liveActivities.activeJourneyID == item.journey.id, settings.liveActivitiesEnabled,
               reminder.fireDate <= min(LiveActivityRefreshSchedule.nextRefresh(for: item.journey, after: now),
                                        now.addingTimeInterval(LiveActivityRefreshSchedule.ridingInterval)),
               await liveActivities.alert(title: reminder.title, body: reminder.body(at: now)) {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                scheduled[identifier] = now
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let delay = max(1, reminder.fireDate.timeIntervalSince(now))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            // The same identifier replaces the pending one, so a moved reminder never comes twice.
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            scheduled[identifier] = now.addingTimeInterval(delay)
        }
        ExitReminderLog.save(scheduled.filter { $0.value > now.addingTimeInterval(-2 * 24 * 3600) })
    }

    func setExitReminders(_ on: Bool, for id: UUID) {
        guard let index = savedJourneys.firstIndex(where: { $0.id == id }) else { return }
        savedJourneys[index].exitRemindersOff = on ? nil : true
    }
}

/// When each exit reminder was scheduled to show, by notification identifier. Per device, like the
/// notifications themselves; a passed date means it was shown and doesn't come again.
private enum ExitReminderLog {
    static let key = "exitReminderDates"

    static func load() -> [String: Date] {
        UserDefaults.standard.dictionary(forKey: key)?.compactMapValues { $0 as? Date } ?? [:]
    }

    static func save(_ dates: [String: Date]) {
        UserDefaults.standard.set(dates, forKey: key)
    }
}
