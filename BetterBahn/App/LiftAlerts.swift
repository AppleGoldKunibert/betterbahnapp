import BetterBahnKit
import Foundation
import UserNotifications

/// Lifts out of order at stations and on journeys (#486), from DB's FaSta API through our server. The app
/// always loads the whole list, so it never says which station the user looks at.
extension AppModel {
    /// Every lift out of order now (the Kit keeps it 5 minutes); empty when DB can't be asked.
    func brokenLifts() async -> [BrokenLift] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugBrokenLifts") { return await Self.debugBrokenLifts() }
        #endif
        return await FacilityClient().brokenLifts() ?? []
    }

    /// The lifts out of order at `station`. The offline platform list loads off the main thread.
    func liftAlerts(at station: Station) async -> [LiftAlert] {
        let lifts = await brokenLifts()
        guard !lifts.isEmpty else { return [] }
        return await Task.detached { LiftCheck.alerts(at: station, among: lifts) }.value
    }

    /// The lifts out of order where `journey` needs one: start, transfers to another platform, destination.
    func liftAlerts(for journey: Journey) async -> [JourneyLiftAlert] {
        let lifts = await brokenLifts()
        guard !lifts.isEmpty else { return [] }
        return await Task.detached { journey.liftAlerts(among: lifts) }.value
    }

    #if DEBUG
    /// With `-debugBrokenLifts YES`: the first lift on a platform at Frankfurt (Main) Hbf, Hannover Hbf and
    /// Köln Hbf is out of order, since the Simulator gets no App Attest token for the real list.
    private static func debugBrokenLifts() async -> [BrokenLift] {
        await Task.detached {
            ["8000105", "8000152", "8000207"].enumerated().compactMap { index, eva -> BrokenLift? in
                guard let platforms = StationPlatforms.at(eva: eva),
                      let entry = platforms.tracks.sorted(by: { $0.key < $1.key })
                          .first(where: { $0.value.accesses.contains { $0.kind == .lift } }),
                      let lift = entry.value.accesses.first(where: { $0.kind == .lift }) else { return nil }
                let track = entry.value
                let share = track.length > 0 ? lift.position / track.length : 0
                let point = Coordinate(latitude: track.start.latitude + (track.end.latitude - track.start.latitude) * share,
                                       longitude: track.start.longitude + (track.end.longitude - track.start.longitude) * share)
                return BrokenLift(id: 900_000 + index, description: "zu Gleis \(entry.key)", coordinate: point,
                                  reason: index == 0 ? "under maintenance" : nil)
            }
        }.value
    }
    #endif
}

extension ConnectionNotifier {
    /// A lift the user needs on a saved journey is out of order (#486, Settings → Stufenfrei reisen).
    static func notify(_ alert: JourneyLiftAlert, journey: Journey) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: alert.id + journey.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
