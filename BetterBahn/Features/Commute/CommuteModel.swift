import BetterBahnKit
import Foundation
import UserNotifications

/// "Fährst du heute?" for a regular trip's travel day (#397).
struct CommuteQuestion: Hashable, Sendable {
    var tripID: UUID
    var dayKey: String
}

extension AppModel {
    // MARK: Regular trips (#397)

    /// The regular trip `journey` was saved from, or one riding the same trains at the same time.
    func regularTrip(for journey: Journey) -> RegularTrip? {
        if let id = savedEntry(for: journey)?.commute?.tripID, let trip = regularTrips.first(where: { $0.id == id }) {
            return trip
        }
        return regularTrips.first { $0.matches(journey) }
    }

    /// Adds or updates `trip` and asks for permission to send its questions.
    func saveRegularTrip(_ trip: RegularTrip) {
        Task { await ConnectionNotifier.requestAuthorization() }
        if let index = regularTrips.firstIndex(where: { $0.id == trip.id }) {
            regularTrips[index] = trip
        } else {
            regularTrips.append(trip)
        }
    }

    func removeRegularTrip(_ trip: RegularTrip) {
        regularTrips.removeAll { $0.id == trip.id }
    }

    /// Schedules the questions of the next days again (iOS keeps 64 at most, so not further ahead), leaving out
    /// days already saved, e.g. answered on another device. Called on every start and whenever the trips or
    /// the days saved from them change.
    func scheduleCommuteQuestions() {
        let questions = regularTrips.flatMap { trip in
            let answered = Set(savedJourneys.compactMap { $0.commute?.tripID == trip.id ? $0.commute?.dayKey : nil })
            return trip.questions(from: .now, answered: answered).map { (trip, $0) }
        }
        .sorted { $0.1.date < $1.1.date }
        .prefix(CommuteNotifier.maxQuestions)
        let requests = questions.map { trip, question in CommuteNotifier.request(for: question, of: trip) }
        let previous = commuteQuestionsTask
        commuteQuestionsTask = Task {
            await previous?.value
            await CommuteNotifier.replaceQuestions(with: requests)
        }
    }

    /// The answer to a question's notification: "Ja" saves the day's journey right there, a tap on the
    /// notification asks again in the app (`commuteQuestionToAsk`), "Heute nicht" does nothing. Tapping the
    /// offer to try again (`retry`) loads the journey and opens it.
    func answerCommuteQuestion(_ question: CommuteQuestion, action: String, retry: Bool) async {
        let saved = savedJourneys.contains { $0.commute?.tripID == question.tripID && $0.commute?.dayKey == question.dayKey }
        switch action {
        case CommuteNotifier.yesAction:
            await confirmCommute(question, open: false)
        case CommuteNotifier.noAction, UNNotificationDismissActionIdentifier:
            break
        default:
            if retry || saved {
                await confirmCommute(question, open: true)
            } else {
                commuteQuestionToAsk = question
            }
        }
    }

    /// Saves the day's journey of the question's regular trip as a normal saved journey (once, also when two
    /// devices say yes), hands it to the push Worker and loads its live data. When its trains can't be loaded
    /// (offline), a notification offers to try again. `open` shows the journey.
    func confirmCommute(_ question: CommuteQuestion, open: Bool) async {
        guard let trip = regularTrips.first(where: { $0.id == question.tripID }),
              let day = RegularTrip.day(forKey: question.dayKey) else { return }
        let id = trip.journeyID(forDay: question.dayKey)
        if let existing = savedJourneys.first(where: { $0.id == id }) {
            if open { journeyToOpen = existing }
            return
        }
        let journey: Journey
        do {
            journey = try await RegularTripPlanner(provider: provider).journey(for: trip, on: day)
        } catch {
            await CommuteNotifier.notifyLoadingFailed(question, of: trip)
            return
        }
        guard !savedJourneys.contains(where: { $0.id == id }) else { return }
        var entry = SavedJourney(id: id, journey: journey)
        entry.commute = CommuteDay(tripID: trip.id, dayKey: question.dayKey, delayThreshold: trip.delayThreshold)
        var updated = savedJourneys
        updated.append(entry)
        updated.sort { ($0.journey.departure?.planned ?? .distantPast) < ($1.journey.departure?.planned ?? .distantPast) }
        savedJourneys = updated
        if open { journeyToOpen = entry }
        // First the Worker, so the refresh below knows whether to report problems itself.
        await syncCommutePush()
        await refresh(entry, using: journeyRefresher)
    }

    /// Called when the saved journeys changed: days saved from a regular trip take their questions away
    /// (also when saved on another device), and a changed day goes to the push Worker again.
    func commuteJourneysChanged(from old: [SavedJourney]) {
        func days(_ list: [SavedJourney]) -> Set<String> {
            Set(list.compactMap { entry in entry.commute.map { "\($0.tripID)|\($0.dayKey)" } })
        }
        func trains(_ list: [SavedJourney]) -> [String] {
            list.filter { $0.commute != nil }.map { entry in
                entry.id.uuidString + entry.journey.transitLegs.map { "\($0.line?.name ?? "")\($0.origin.id)\($0.departure.planned)\($0.destination.id)" }.joined()
            }
        }
        if days(old) != days(savedJourneys) { scheduleCommuteQuestions() }
        if trains(old) != trains(savedJourneys) {
            let previous = commutePushTask
            commutePushTask = Task {
                await previous?.value
                await syncCommutePush()
            }
        }
    }

    /// Hands the push Worker today's journeys of regular trips (those leaving within 24 hours and not over),
    /// so their problems arrive in time even while the app doesn't run, and learns which ones it looks after.
    /// Nothing is sent while there are none and none were sent before, nor when the list didn't change.
    func syncCommutePush() async {
        let entries = settings.connectionWarnings ? savedJourneys.filter { entry in
            entry.commute != nil && !entry.isFinished
                && (entry.journey.departure?.planned ?? .distantFuture) < Date.now.addingTimeInterval(24 * 3600)
        } : []
        guard !entries.isEmpty || commutePushSent != nil else { return }
        var watches: [CommuteWatch] = []
        for entry in entries {
            if let watch = await CommuteWatch.make(journeyID: entry.id, journey: entry.journey,
                                                   threshold: entry.commute?.delayThreshold ?? RegularTrip.defaultDelayThreshold,
                                                   eva: { station in await self.evaNumber(of: station) }) {
                watches.append(watch)
            }
        }
        guard let deviceToken = await pushDeviceTokenForFollowedCheckins() else {
            commutePushWatched = []
            return
        }
        let registration = commutePushRegistration ?? CommutePushRegistration.make()
        commutePushRegistration = registration
        let sent = try? JSONEncoder().encode(CommutePushSent(deviceToken: deviceToken, watches: watches))
        guard sent != commutePushSent else { return }
        do {
            commutePushWatched = try await CommutePush().update(registration, deviceToken: deviceToken,
                                                                sandbox: Self.pushUsesSandbox, watches: watches)
            commutePushSent = watches.isEmpty ? nil : sent
        } catch {
            // Unreachable: the app reports everything itself and tries again next time.
            commutePushWatched = []
            commutePushSent = Data()
        }
    }

    private func evaNumber(of station: Station) async -> String? {
        if let eva = station.evaNumber { return eva }
        return try? await provider.bahnDe?.evaNumber(for: station)
    }

    /// The saved journey a notification from the push Worker is about: opens it.
    func openCommuteJourney(id: String) {
        guard let entry = savedJourneys.first(where: { $0.id.uuidString == id }) else { return }
        journeyToOpen = entry
    }
}

/// What the push Worker was last sent, to skip sending it again.
private struct CommutePushSent: Encodable {
    var deviceToken: String
    var watches: [CommuteWatch]
}

/// The notifications of regular trips (#397): the questions ("Fährst du heute?") with their answers, and
/// the one offering to try again when the day's trains couldn't be loaded.
enum CommuteNotifier {
    static let category = "commute-question"
    static let yesAction = "commute-yes"
    static let noAction = "commute-no"
    nonisolated static let tripKey = "commuteTripID"
    nonisolated static let dayKey = "commuteDay"
    nonisolated static let retryKey = "commuteRetry"
    /// iOS keeps 64 pending notifications per app; the questions leave room for others.
    static let maxQuestions = 40

    /// The category with "Ja, ich fahre" and "Heute nicht", registered at launch.
    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: yesAction, title: "Ja, ich fahre", options: []),
            UNNotificationAction(identifier: noAction, title: "Heute nicht", options: []),
        ], intentIdentifiers: [], options: [])
    }

    static func request(for question: RegularTrip.Question, of trip: RegularTrip) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Fährst du heute?"
        content.body = trip.questionBody(departure: question.departure)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = category
        content.userInfo = [tripKey: question.tripID.uuidString, dayKey: question.dayKey]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, question.date.timeIntervalSinceNow), repeats: false)
        return UNNotificationRequest(identifier: question.notificationID, content: content, trigger: trigger)
    }

    static func replaceQuestions(with requests: [UNNotificationRequest]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier).filter { $0.hasPrefix(RegularTrip.questionPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for request in requests { try? await center.add(request) }
    }

    /// Tapping it tries again and opens the journey.
    static func notifyLoadingFailed(_ question: CommuteQuestion, of trip: RegularTrip) async {
        let content = UNMutableNotificationContent()
        content.title = "Fahrt nicht geladen"
        content.body = "\(trip.summary) konnte gerade nicht geladen werden. Tippe hier, um es noch mal zu versuchen."
        content.sound = .default
        content.userInfo = [tripKey: question.tripID.uuidString, dayKey: question.dayKey, retryKey: true]
        let request = UNNotificationRequest(identifier: "commute-failed|\(question.tripID)|\(question.dayKey)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The question a notification is about (a question or the offer to try again).
    nonisolated static func question(in userInfo: [AnyHashable: Any]) -> CommuteQuestion? {
        guard let trip = (userInfo[tripKey] as? String).flatMap(UUID.init), let day = userInfo[dayKey] as? String else { return nil }
        return CommuteQuestion(tripID: trip, dayKey: day)
    }

    /// Whether the notification offers to try loading the day's journey again.
    nonisolated static func isRetry(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[retryKey] as? Bool ?? false
    }

    /// The saved journey a push from the Worker is about.
    nonisolated static func journeyID(in userInfo: [AnyHashable: Any]) -> String? {
        userInfo[CommutePush.journeyIDKey] as? String
    }
}
