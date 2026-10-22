import Foundation

/// The live data of one train run, laid over its stop sequence from every source in one fixed order — the
/// same for the trip view (the whole run) and for a saved journey's leg (the part of it between the leg's
/// origin and destination), so the two never tell different stories about one train. Before, each had its
/// own pipeline: ICE 279 Berlin → Frankfurt showed +3 and +18 on the journey card hours before departure,
/// while the run opened from that card had plain times and "0" at every stop.
///
/// The order, with each source's own rules unchanged:
/// 1. Transitous: the stops another feed's copy of the train has (`TwinTrainStops.swift`).
/// 2. DB Timetables: delays, cancellations, notices and missing platforms, as long as DB still lists the train
///    (`TimetablesClient.knowsChanges`); a stop without a change counts as on time only within 2 hours of
///    departure (`infersOnTime`).
/// 3. bahn.de's journey details: Zusatzhalte, live times (not over a delay DB Timetables set, bahn.expert as
///    the referee where the two differ), platforms, sleeping cars. Asked for a run underway or departing
///    within 12 hours (`isRunningSoon`), and hourly for one up to a week ahead that lacks a platform
///    (`needsPlatforms`); only platforms for other railways' night trains (`BahnDeClient.takesOnlyPlatforms`).
/// 4. bahn.expert: the platforms bahn.de lacks (SBB's and ÖBB's stations).
/// 5. The Czech timetable's platforms.
///
/// A `baseline` — the run as last seen: the trip remembered by `AppModel.liveTrips`, the saved leg — fills what
/// the fresh answers lack (a live time, a platform, a Zusatzhalt, the night-train mark), matched by station and
/// planned time, so a stop of another lap takes nothing. It never overrides fresh data (`keepingKnown`).
///
/// The screen gets the first paint from what is quick: `progress` is called with the timetable when DB
/// Timetables takes longer than `LoadingDeadline.liveData`, and with each source's result as it comes; the
/// returned run is final. Each version handed out carries the baseline, so nothing seen before goes missing
/// even for a moment.
public struct LiveRun: Sendable {
    let provider: CombinedProvider
    let timetables: TimetablesClient?

    public init(provider: CombinedProvider, timetables: TimetablesClient? = nil) {
        self.provider = provider
        self.timetables = timetables
    }

    public typealias Progress = @MainActor @Sendable (Trip) -> Void

    /// `trip` with its live data (see above).
    /// - Parameters:
    ///   - trip: the run's stops as its feed has them, with whatever a caller already knows laid over.
    ///   - baseline: the run as last seen, filling what the fresh answers lack.
    ///   - wholeRun: the whole run of the train (a trip view), which also gets the run beyond a border and the
    ///     Czech stops' live times (`CombinedProvider.completing`); false for the part of it a leg rides.
    ///   - progress: shown intermediate versions (see above); nil when only the final result matters.
    public func refresh(_ trip: Trip, baseline: Trip? = nil, wholeRun: Bool, now: Date = .now,
                        progress: Progress? = nil) async -> Trip {
        let baseline = baseline.map { Self.droppingInferredOnTime($0, now: now) }
        func paint(_ run: Trip) async {
            guard let progress else { return }
            await progress(Self.keepingKnown(from: baseline, in: run))
        }

        // 1 + 2. What is quick: the stops another feed has and DB's delays, within one deadline; the screen shows
        // the timetable meanwhile if DB is slow, so a run never jumps from the timetable to its delays a second later.
        let timetable = trip
        let quick: @Sendable () async -> (Trip, Bool) = { await liveFromFeeds(timetable, now: now) }
        let (fromFeeds, timetablesAsked): (Trip, Bool)
        if let progress {
            let shown = Self.keepingKnown(from: baseline, in: timetable)
            (fromFeeds, timetablesAsked) = await LoadingDeadline.run(quick, showingAfter: LoadingDeadline.liveData) { progress(shown) }
        } else {
            (fromFeeds, timetablesAsked) = await quick()
        }
        var run = fromFeeds
        await paint(run)

        // The run beyond a border and the Czech stops' platforms and live times take a few requests: after the first paint.
        if wholeRun {
            let completed = await provider.completing(run)
            if completed != run {
                run = completed
                await paint(run)
            }
        }

        // 3. bahn.de. Neither Transitous nor DB Timetables above ever *inserts* a stop — only bahn.de's journey
        // details report a Zusatzhalt (an unscheduled stop the train additionally picked up today) at all. They
        // also carry the platforms Transitous lacks at some stations (e.g. Hamburg Hbf), days before DB Timetables
        // knows them. Asked for runs underway or departing within 12 hours, and hourly for runs up to a week
        // ahead that miss a platform, so many saved journeys don't flood bahn.de. A Nightjet or the like only
        // gets its platforms from bahn.de, which lists them on its board too: no stops inserted, no times, as
        // they are not DB's trains.
        let platformsOnly = BahnDeClient.takesOnlyPlatforms(run.line)
        if let bahnDe = provider.bahnDe, let span = Self.span(of: run) {
            let runningSoon = Self.isRunningSoon(span, now: now) && !platformsOnly
            if runningSoon || Self.needsPlatforms(span, now: now),
               let course = try? await bahnDe.journeyCourse(for: span, maxAge: runningSoon ? BahnDeClient.journeyStopsMaxAge : 3600,
                                                            includingOtherRailways: platformsOnly) {
                if runningSoon {
                    run.stopovers = BahnDeClient.inserting(course.stops, into: run.stopovers)
                    // DB's own live times beat Transitous' and fill stops DB Timetables missed. Where bahn.de and
                    // DB Timetables disagree, bahn.expert is asked which is right; shown once it answers.
                    if progress != nil {
                        var immediate = run
                        immediate.stopovers = BahnDeClient.applyingLiveTimes(from: course.stops, to: run.stopovers, keepingDelays: timetablesAsked)
                        await paint(immediate)
                    }
                    run.stopovers = await BahnDeClient.applyingLiveTimes(from: course.stops, to: run.stopovers, line: run.line,
                                                                         keepingDelays: timetablesAsked, referee: provider.bahnExpert)
                    // bahn.de lists sleeping or couchette cars: a night train, also one the feeds don't mark (#241).
                    if course.hasSleepingCars, run.line?.isNightTrain == false { run.line?.nightRail = true }
                }
                run.stopovers = BahnDeClient.fillingMissingPlatforms(in: run.stopovers, from: course.stops, overwriting: platformsOnly)
                await paint(run)
            }
        }

        // 4. What bahn.de lacks, mostly at the stations of other railways (the SBB's and ÖBB's): bahn.expert lists
        // the platforms of the whole run, also for a Nightjet.
        if let bahnExpert = provider.bahnExpert, let span = Self.span(of: run), Self.needsPlatforms(span, now: now) {
            run.stopovers = await bahnExpert.fillingMissingPlatforms(in: run.stopovers, line: run.line)
        }

        // 5. International trains from DB's feed have no platforms in Czechia; the Czech timetable has them.
        if let transitous = provider.primary as? TransitousProvider {
            run = await transitous.fillingCzechPlatforms(in: run)
        }
        return Self.keepingKnown(from: baseline, in: run)
    }

    /// Steps 1 and 2: the stops another feed has, then DB Timetables' live data. Also whether DB Timetables was
    /// asked, for `BahnDeClient.applyingLiveTimes(keepingDelays:)`.
    private func liveFromFeeds(_ trip: Trip, now: Date) async -> (Trip, Bool) {
        var run = trip
        // Stops the run's own feed leaves out (ÖBB's RJ 177 has none between Südkreuz and Děčín), before DB's live
        // data and bahn.de's Zusatzhalte are laid over them.
        if let transitous = provider.primary as? TransitousProvider {
            run = await transitous.fillingMissingStops(in: run)
        }
        guard let timetables, timetables.canLookUp(run.line),
              let last = run.stopovers.last.flatMap({ $0.arrival?.planned ?? $0.departure?.planned }),
              TimetablesClient.knowsChanges(until: last, now: now) else { return (run, false) }
        // DB Timetables wins wherever it knows the stop; its delays stay where bahn.de's forecast differs.
        return (await timetables.liveTrip(run, now: now), true)
    }

    // MARK: Rules

    /// The run as one leg from its first departure to its last arrival, for the lookups that take a leg (bahn.de's
    /// journey details, another feed's copy of the train) and the rules below. Nil for a run without both.
    static func span(of trip: Trip) -> Leg? {
        guard let start = trip.stopovers.firstIndex(where: { $0.departure != nil }),
              let end = trip.stopovers.lastIndex(where: { $0.arrival != nil }), start < end else { return nil }
        return trip.leg(fromIndex: start, toIndex: end)
    }

    /// A leg (or run) departing within the next 12 hours or still underway — the only ones a Zusatzhalt lookup
    /// is worth a bahn.de request for.
    static func isRunningSoon(_ leg: Leg, now: Date = .now) -> Bool {
        leg.departure.planned <= now.addingTimeInterval(12 * 3600) && leg.arrival.best >= now.addingTimeInterval(-3600)
    }

    /// A leg (or run) within the next week missing a platform somewhere, which bahn.de may know.
    static func needsPlatforms(_ leg: Leg, now: Date = .now) -> Bool {
        !leg.isWalking && leg.departure.planned <= now.addingTimeInterval(7 * 24 * 3600) && leg.arrival.best >= now
            && (BahnDeClient.takesOnlyPlatforms(leg.line)
                || (BahnDeClient.trainReference(for: leg.line) != nil && BahnDeClient.lacksPlatforms(leg)))
    }

    // MARK: Baseline

    /// `run` with what `baseline` (the same run as last seen) knows where `run` has nothing: a stop's live time
    /// or platform, matched by station and planned time (`isSameVisit`), the Zusatzhalte bahn.de no longer
    /// reports, and the night-train mark. Fresh data in `run` always stays.
    public static func keepingKnown(from baseline: Trip?, in run: Trip) -> Trip {
        guard let baseline else { return run }
        var run = run
        for index in run.stopovers.indices {
            let stop = run.stopovers[index]
            guard let known = baseline.stopovers.first(where: { isSameVisit($0, stop) }) else { continue }
            if stop.arrival?.actual == nil, let arrival = known.arrival, arrival.planned == stop.arrival?.planned {
                run.stopovers[index].arrival?.actual = arrival.actual
            }
            if stop.departure?.actual == nil, let departure = known.departure, departure.planned == stop.departure?.planned {
                run.stopovers[index].departure?.actual = departure.actual
            }
            if stop.arrivalPlatform?.best == nil, known.arrivalPlatform?.best != nil { run.stopovers[index].arrivalPlatform = known.arrivalPlatform }
            if stop.departurePlatform?.best == nil, known.departurePlatform?.best != nil {
                run.stopovers[index].departurePlatform = known.departurePlatform
            }
        }
        // A Zusatzhalt before the run's first or after its last regular stop was never part of it.
        run.stopovers = BahnDeClient.droppingOutlyingZusatzhalte(from: run.keepingAdditionalStops(of: baseline.stopovers).stopovers)
        if baseline.line?.nightRail == true, run.line != nil { run.line?.nightRail = true }
        return run
    }

    /// The same visit of a station in two versions of a run: the same place at the same planned time(s). A
    /// ring line (S41/S42) passes the same station every lap, and a stop of another lap must take nothing.
    static func isSameVisit(_ a: Stopover, _ b: Stopover) -> Bool {
        guard a.station.isSamePlace(as: b.station) else { return false }
        let pairs = [(a.arrival?.planned, b.arrival?.planned), (a.departure?.planned, b.departure?.planned)]
            .compactMap { pair -> (Date, Date)? in
                guard let x = pair.0, let y = pair.1 else { return nil }
                return (x, y)
            }
        return !pairs.isEmpty && pairs.allSatisfy { $0.0 == $0.1 }
    }

    /// A baseline saved before `TimetablesClient.infersOnTime` existed, or long before the train runs, carries DB's
    /// made-up "on time" (actual == planned) for a run hours ahead. Dropped while the train is still that far off,
    /// so it can't fill a gap; a real live time comes back from the sources (see `JourneyRefresher.droppingInferredOnTime`).
    static func droppingInferredOnTime(_ trip: Trip, now: Date) -> Trip {
        guard let start = trip.stopovers.first.flatMap({ $0.departure?.planned ?? $0.arrival?.planned }),
              !TimetablesClient.infersOnTime(departing: start, now: now) else { return trip }
        var trip = trip
        for index in trip.stopovers.indices {
            if trip.stopovers[index].arrival?.actual == trip.stopovers[index].arrival?.planned { trip.stopovers[index].arrival?.actual = nil }
            if trip.stopovers[index].departure?.actual == trip.stopovers[index].departure?.planned { trip.stopovers[index].departure?.actual = nil }
        }
        return trip
    }
}

public extension Trip {
    /// This run with the Zusatzhalte `stops` (an earlier version of it) has that it lacks — bahn.de only reports
    /// them while the train runs — each put in by its planned time, unless the run already calls there.
    func keepingAdditionalStops(of stops: [Stopover]) -> Trip {
        func time(_ stop: Stopover) -> Date? { stop.arrival?.planned ?? stop.departure?.planned }
        var trip = self
        for extra in stops where extra.isAdditional {
            guard let at = time(extra), !trip.stopovers.contains(where: { $0.station.isSamePlace(as: extra.station) }) else { continue }
            let index = trip.stopovers.firstIndex { stop in time(stop).map { $0 > at } ?? false } ?? trip.stopovers.endIndex
            trip.stopovers.insert(extra, at: index)
        }
        return trip
    }
}
