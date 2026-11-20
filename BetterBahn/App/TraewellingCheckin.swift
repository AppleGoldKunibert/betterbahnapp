import BetterBahnKit
import Foundation

/// Checking in on Träwelling, shared by the check-in form (`CheckinSheet`), the group check-in (#574) and a
/// reminder's "Einchecken" button (#580).
extension AppModel {
    /// A check-in made: the result and the leg actually checked in (another train name than asked for when
    /// Träwelling knows the train under that one).
    struct MadeCheckin {
        var result: CheckinResult
        var leg: Leg
    }

    /// Checks in `draft.leg`, falling back to other ways Träwelling may know the train when its own timetable
    /// doesn't have it. `nil` if none works, so a manual trip can be offered. Remembers the check-in for `shownLeg`
    /// (the leg as the journey shows it, not a picked coupled train) and adds `tags`.
    func checkin(_ draft: CheckinDraft, shownLeg: Leg, tags: [StatusTag] = []) async throws -> MadeCheckin? {
        guard let made = try await checkinFindingTrain(draft) else { return nil }
        await finishCheckin(made, shownLeg: shownLeg, tags: tags)
        return made
    }

    /// Checks in `draft.leg` as a manual trip, after the search for the train already failed.
    func checkinAsManualTrip(_ draft: CheckinDraft, shownLeg: Leg, tags: [StatusTag] = []) async throws -> MadeCheckin {
        let made = MadeCheckin(result: try await traewelling.checkinAsManualTrip(draft), leg: draft.leg)
        await finishCheckin(made, shownLeg: shownLeg, tags: tags)
        return made
    }

    private func checkinFindingTrain(_ draft: CheckinDraft) async throws -> MadeCheckin? {
        let leg = draft.leg
        do {
            return MadeCheckin(result: try await traewelling.checkin(draft), leg: leg)
        } catch TraewellingError.tripNotFound {}
        // Some international trains are listed under two names by separate feeds (e.g. an
        // ÖBB "RJ 177" that Deutsche Bahn's own live feed calls "ICE 177") — try the other
        // name Transitous knows about before asking to create a manual entry.
        if let alternate = await provider.alternateLineName(for: leg), alternate != leg.line?.name {
            var altDraft = draft
            altDraft.leg.line?.name = alternate
            if let result = try await checkinFallback({ try await self.traewelling.checkin(altDraft) }) {
                return MadeCheckin(result: result, leg: altDraft.leg)
            }
        }
        // `leg.origin` may be a Zusatzhalt (an unscheduled stop, e.g. after a diversion) —
        // Träwelling's own timetable never has those, which is exactly why the checkin above
        // just failed. Bridge the gap with a short manual trip instead of asking the user to
        // manually enter the whole rest of the journey.
        if let result = try await checkinFallback({ try await self.zusatzhaltCheckin(draft) }) ?? nil {
            return MadeCheckin(result: result, leg: leg)
        }
        return nil
    }

    /// A fallback attempt's result, `nil` if it failed. A collision still reaches the user, who can
    /// check in anyway; it would happen the same way with a manual trip.
    private func checkinFallback<T>(_ attempt: () async throws -> T) async throws -> T? {
        do {
            return try await attempt()
        } catch TraewellingError.collision {
            throw TraewellingError.collision
        } catch {
            return nil
        }
    }

    /// If the leg boards at a Zusatzhalt bahn.de's journey details know about, checks in the hop up
    /// to the next regular stop as a short manual trip and then checks in normally from there. `nil`
    /// if bahn.de doesn't know this train, or `leg.origin` isn't actually a Zusatzhalt (some other
    /// reason Träwelling didn't recognise the departure).
    private func zusatzhaltCheckin(_ draft: CheckinDraft) async throws -> CheckinResult? {
        guard let bahnDe = provider.bahnDe,
              let stops = try await bahnDe.journeyStops(for: draft.leg),
              let (zusatzhalt, nextRegular) = BahnDeClient.nextRegularStop(after: draft.leg.origin, in: stops)
        else { return nil }
        return try await traewelling.checkin(draft, fromZusatzhalt: zusatzhalt, toNextRegularStop: nextRegular)
    }

    private func finishCheckin(_ made: MadeCheckin, shownLeg: Leg, tags: [StatusTag]) async {
        let checkin = made.result
        // Remembered for the leg as shown in the journey (not a picked coupled train), so its "Mehr" finds it.
        if let statusId = checkin.statusId { rememberCheckin(statusId: statusId, leg: shownLeg) }
        if checkin.isManualTrip, let statusId = checkin.statusId {
            trackManualCheckin(statusId: statusId, leg: made.leg)
        }
        if let hop = checkin.zusatzhaltHop {
            trackManualCheckin(statusId: hop.statusId, leg: hop.leg)
        }
        // A train Träwelling splits into several trips (e.g. at a border) gets one status per part,
        // and tags like the seat apply to all of them. Best-effort: the check-in itself already
        // succeeded, so a single failed tag shouldn't surface as an error.
        for statusId in [checkin.statusId].compactMap(\.self) + checkin.connectingStatusIds {
            for tag in tags {
                _ = try? await traewelling.addTag(statusId: statusId, key: tag.key, value: tag.value,
                                                  visibility: tag.visibility ?? .publicVisible)
            }
        }
    }

    /// The tags picked in a check-in form, with their values: a quick tag's own value, else the one typed in.
    func checkinTags(active: Set<String>, values: [String: String], visibility: TraewellingVisibility) -> [StatusTag] {
        settings.quickTags.compactMap { tag in
            guard active.contains(tag.id) else { return nil }
            let value = tag.value ?? values[tag.id]?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? nil : StatusTag(key: tag.key, value: value, visibility: visibility)
        }
    }
}
