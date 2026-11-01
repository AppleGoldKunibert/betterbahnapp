import BetterBahnKit
import MapKit
import SwiftUI
import UserNotifications

extension AppModel {
    /// How often the check-ins of the people the user follows are reloaded while they're on screen.
    static let followedCheckinsInterval: Duration = .seconds(120)

    /// Keeps `followedCheckins` fresh for as long as the calling task runs (the Verbindungen tab).
    /// Coming back to the tab within the interval doesn't load again.
    func keepFollowedCheckinsFresh() async {
        while !Task.isCancelled {
            let due = followedCheckinsLoadedAt.map { Date.now.timeIntervalSince($0) >= 110 } ?? true
            await loadFollowedCheckins(reload: due)
            try? await Task.sleep(for: Self.followedCheckinsInterval)
        }
    }

    /// The train of someone's check-in in the timetable. The lookup runs on its own, so folding the card away
    /// (which cancels whoever waits for it) doesn't stop it: it still ends in `followedTrains`, and opening
    /// the card again joins one that is still running instead of starting over.
    func followedTrain(for status: TraewellingStatus) async throws -> Leg? {
        if let known = followedTrains[status.id] { return known }
        let load: Task<Leg?, Error>
        if let running = followedTrainLoads[status.id] {
            load = running
        } else {
            let lookup = provider
            load = Task { try await lookup.leg(forCheckin: status) }
            followedTrainLoads[status.id] = load
            Task { [weak self] in
                let result = await load.result
                self?.followedTrainLoads[status.id] = nil
                if case .success(let leg?) = result { self?.followedTrains[status.id] = leg }
            }
        }
        return try await load.value
    }

    /// Loads the check-ins of the people the user follows, or clears them without Träwelling (all that
    /// happens without `reload`).
    func loadFollowedCheckins(reload: Bool = true) async {
        guard settings.traewellingEnabled, await traewelling.isLoggedIn else {
            followedCheckins = nil
            followedCheckinsLoadedAt = nil
            return
        }
        guard reload, let fresh = try? await traewelling.followedCheckins() else { return }
        followedCheckins = fresh
        followedCheckinsLoadedAt = .now
        let current = Set(fresh.statuses.map(\.id))
        followedTracks = followedTracks.filter { current.contains($0.key) }
        followedTrains = followedTrains.filter { current.contains($0.key) }
        followedEmojis = followedEmojis.filter { current.contains($0.key) }
        await prepareEmojis(for: fresh.statuses)
    }

    /// Shows a followed check-in whose notification was tapped: loads the list first if it isn't in it yet.
    /// Nothing opens when the ride has ended meanwhile.
    func openFollowedCheckin(id: Int) async {
        followedCheckinToOpen = id
        guard followedCheckins?.statuses.contains(where: { $0.id == id }) != true else { return }
        await loadFollowedCheckins()
        if followedCheckins?.statuses.contains(where: { $0.id == id }) != true, followedCheckinToOpen == id {
            followedCheckinToOpen = nil
        }
    }

    // MARK: Notifications (#266)

    /// Whether this build's device token belongs to APNs' sandbox (development builds from Xcode).
    static var pushUsesSandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// What the push Worker should notify about, from the settings.
    var checkinPushKinds: Set<CheckinPushKind> {
        var kinds: Set<CheckinPushKind> = []
        if settings.notifyFollowedCheckins { kinds.insert(.followed) }
        if settings.notifyCheckinLikes { kinds.insert(.likes) }
        if settings.notifyCheckinCompanions { kinds.insert(.companions) }
        return kinds
    }

    func isCheckinPushOn(_ kind: CheckinPushKind) -> Bool {
        checkinPushKinds.contains(kind)
    }

    /// Whether turning `kind` on signs in with Träwelling again: likes and fellow travellers with a login
    /// handed over from before #452, which can't read Träwelling's notifications.
    func checkinPushNeedsLogin(for kind: CheckinPushKind) async -> Bool {
        FollowedCheckinPush.step(for: checkinPushKinds.union([kind]), subscription: followedCheckinPush,
                                 loginReadsNotifications: await traewelling.readsNotifications) == .signIn
    }

    private func setCheckinPushKinds(_ kinds: Set<CheckinPushKind>) {
        settings.notifyFollowedCheckins = kinds.contains(.followed)
        settings.notifyCheckinLikes = kinds.contains(.likes)
        settings.notifyCheckinCompanions = kinds.contains(.companions)
    }

    /// Turns one kind of notification from the push Worker on or off (#266, #447). Turning one on asks for
    /// permission and the device token and, when `checkinPushNeedsLogin`, signs in with Träwelling again
    /// (`authenticate` runs the browser session); the Worker reads with the app's login (#452). Throws when
    /// something is missing; a cancelled login throws too. Offline the change reaches the Worker on the next start.
    func setCheckinPush(_ kind: CheckinPushKind, on: Bool, authenticate: (URL, String) async throws -> URL) async throws {
        var kinds = checkinPushKinds
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        if on, (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) != true {
            throw FollowedCheckinPushError.notificationsDenied
        }
        var step = FollowedCheckinPush.step(for: kinds, subscription: followedCheckinPush,
                                            loginReadsNotifications: await traewelling.readsNotifications)
        if step == .signIn {
            try await signInToTraewellingAgain(authenticate: authenticate)
            step = FollowedCheckinPush.step(for: kinds, subscription: followedCheckinPush,
                                            loginReadsNotifications: await traewelling.readsNotifications)
        }
        switch step {
        case .signOff:
            await disableCheckinPush()
        case .signIn:
            // Träwelling didn't grant reading notifications.
            throw OAuthError.sessionExpired
        case .signUp:
            try await signUpForCheckinPush(kinds: kinds)
        case .update:
            setCheckinPushKinds(kinds)
            followedCheckinPushSentKinds = nil
            await syncFollowedCheckinPush()
        }
    }

    /// Signs in with Träwelling again with the app's current scopes; our server keeps the login, so the
    /// notifications already running carry on.
    private func signInToTraewellingAgain(authenticate: (URL, String) async throws -> URL) async throws {
        let config = traewelling.config
        let pkce = PKCE()
        // A webhook, when the Worker takes one, brings likes and fellow travellers right away.
        let webhook = await FollowedCheckinPush().loginParameters()
        let callback = try await authenticate(config.authorizeURL(pkce: pkce, extra: webhook), config.callbackScheme)
        try await traewelling.completeLogin(callbackURL: callback, pkce: pkce)
    }

    private func signUpForCheckinPush(kinds: Set<CheckinPushKind>) async throws {
        guard let deviceToken = await pushDeviceTokenForFollowedCheckins() else { throw FollowedCheckinPushError.noDeviceToken }
        guard let login = try await traewelling.serverLogin() else { throw OAuthError.notLoggedIn }
        let user = try await traewelling.currentUser()
        // A sign-up left from turning it off offline, or one with a login of its own (before #452), ends
        // first, so its notifications don't come twice.
        if let old = followedCheckinPush { try? await FollowedCheckinPush().unsubscribe(old) }
        followedCheckinPush = try await FollowedCheckinPush().subscribe(
            login: login, deviceToken: deviceToken, sandbox: Self.pushUsesSandbox, userID: user.id, kinds: kinds)
        followedCheckinPushSentToken = deviceToken
        followedCheckinPushSentKinds = kinds
        followedCheckinPushEnded = false
        setCheckinPushKinds(kinds)
    }

    /// Turns all notifications from the push Worker off and signs the device off there. Offline the sign-up
    /// is kept and ended on a later `syncFollowedCheckinPush()`.
    func disableCheckinPush() async {
        setCheckinPushKinds([])
        guard let subscription = followedCheckinPush else { return }
        if (try? await FollowedCheckinPush().unsubscribe(subscription)) != nil, followedCheckinPush == subscription {
            followedCheckinPush = nil
        }
    }

    /// On every start and after a setting changed: sends the Worker the current device token (it can change)
    /// and kinds, ends a sign-up that is no longer wanted (all off, logged out of Träwelling), notices one
    /// the Worker dropped and moves one with a login of its own (before #452) to the app's login.
    func syncFollowedCheckinPush() async {
        guard let subscription = followedCheckinPush else {
            // Turned on in a build that looked in the background itself: there's no sign-up yet.
            if !checkinPushKinds.isEmpty { setCheckinPushKinds([]) }
            return
        }
        let kinds = checkinPushKinds
        guard !kinds.isEmpty, settings.traewellingEnabled, await traewelling.isLoggedIn else {
            await disableCheckinPush()
            return
        }
        if !subscription.usesAppLogin {
            // Kept while the app's login can't read what the old one could (likes, fellow travellers).
            if FollowedCheckinPush.step(for: kinds, subscription: subscription,
                                        loginReadsNotifications: await traewelling.readsNotifications) == .signUp {
                try? await signUpForCheckinPush(kinds: kinds)
                if followedCheckinPush != subscription { return }
            }
        }
        guard let deviceToken = await pushDeviceTokenForFollowedCheckins(),
              deviceToken != followedCheckinPushSentToken || kinds != followedCheckinPushSentKinds,
              let known = try? await FollowedCheckinPush().update(subscription, deviceToken: deviceToken, sandbox: Self.pushUsesSandbox, kinds: kinds),
              followedCheckinPush == subscription else { return }
        if known {
            followedCheckinPushSentToken = deviceToken
            followedCheckinPushSentKinds = kinds
        } else {
            followedCheckinPush = nil
            followedCheckinPushEnded = true
            setCheckinPushKinds([])
        }
    }

    /// A tapped like on one of the user's own check-ins (#447): "Check-in ansehen" in its saved journey when
    /// it was made in the app, else the check-in on Träwelling.
    func openOwnCheckin(id: Int) async {
        let legIDs = Set(checkinStatusIDs.filter { $0.value == id }.keys)
        if !legIDs.isEmpty, let entry = savedJourneys.first(where: { entry in entry.journey.legs.contains { legIDs.contains($0.id) } }) {
            checkinToShow = id
            journeyToOpen = entry
        } else {
            await openTraewellingStatus(id: id)
        }
    }

    /// A tapped fellow traveller (#447): their check-in in the list of followed ones, else on Träwelling.
    func openCompanionCheckin(id: Int) async {
        await openFollowedCheckin(id: id)
        if followedCheckins?.statuses.contains(where: { $0.id == id }) != true {
            await openTraewellingStatus(id: id)
        }
    }

    private func openTraewellingStatus(id: Int) async {
        _ = await UIApplication.shared.open(traewelling.config.baseURL.appending(path: "status/\(id)"))
    }

    /// The APNs device token: asks iOS to register (again) and waits up to 20 seconds for its answer
    /// (`AppDelegate` → `didRegisterForPush`).
    func pushDeviceTokenForFollowedCheckins() async -> String? {
        if let pushDeviceToken { return pushDeviceToken }
        let first = pushDeviceTokenWaiters.isEmpty
        return await withCheckedContinuation { continuation in
            pushDeviceTokenWaiters.append(continuation)
            guard first else { return }
            UIApplication.shared.registerForRemoteNotifications()
            Task {
                try? await Task.sleep(for: .seconds(20))
                self.didRegisterForPush(deviceToken: nil)
            }
        }
    }

    /// iOS's answer to `registerForRemoteNotifications()`: the device token, or nil when it failed.
    func didRegisterForPush(deviceToken: String?) {
        if let deviceToken { pushDeviceToken = deviceToken }
        let waiters = pushDeviceTokenWaiters
        pushDeviceTokenWaiters = []
        for waiter in waiters { waiter.resume(returning: deviceToken ?? pushDeviceToken) }
    }

    /// The custom emojis for someone else's check-in text: those of the Mastodon instance connected to
    /// their account, else (none connected, or it can't be reached) zug.network's, like for the user's own.
    func emojis(forTextOf status: TraewellingStatus) async -> [CustomEmoji] {
        if let server = status.user?.mastodonServer, server != CustomEmojiText.defaultInstance,
           let theirs = try? await customEmojis.emojis(instance: server) {
            return theirs
        }
        return (try? await customEmojis.emojis(instance: CustomEmojiText.defaultInstance)) ?? []
    }

    /// Loads the emojis of the check-in texts and their pictures ahead, so a text shows them as soon as
    /// it is opened instead of its `:shortcodes:` first.
    private func prepareEmojis(for statuses: [TraewellingStatus]) async {
        for status in statuses where followedEmojis[status.id] == nil {
            guard let body = status.body, body.contains(":") else { continue }
            let emojis = await emojis(forTextOf: status)
            followedEmojis[status.id] = emojis
            CustomEmojiImages.shared.load(CustomEmojiText.segments(of: body, emojis: emojis).compactMap { segment -> URL? in
                if case .emoji(let emoji) = segment { emoji.url } else { nil }
            })
        }
    }

    /// A Träwelling status tag's name: the quick tag's for a known key, else the key itself.
    func statusTagLabel(_ key: String) -> String {
        quickTag(for: key)?.label ?? (key.hasPrefix("trwl:") ? String(key.dropFirst(5)) : key)
    }

    func statusTagIcon(_ key: String) -> String {
        quickTag(for: key)?.systemImage ?? "tag.fill"
    }

    private func quickTag(for key: String) -> QuickTag? {
        (settings.quickTags + QuickTag.defaults).first { $0.key == key }
    }
}

/// Turning on the notifications about followed check-ins failed before Träwelling was asked.
enum FollowedCheckinPushError: LocalizedError {
    case notificationsDenied, noDeviceToken

    var errorDescription: String? {
        switch self {
        case .notificationsDenied: String(localized: "Mitteilungen sind für BetterBahn aus. Erlaube sie in den iOS-Einstellungen.")
        case .noDeviceToken: String(localized: "iOS hat keine Mitteilungen eingerichtet. Bitte versuch es später noch mal.")
        }
    }
}

/// The notifications sent by the push Worker (`Cloudflare/checkin-push`) about a new check-in of someone the
/// user follows (#266), a like on the user's own check-in or someone on the same train (#447); tapping one
/// opens the check-in.
enum FollowedCheckinNotifier {
    nonisolated static let statusIDKey = "followedStatusID"
    nonisolated static let ownStatusIDKey = "ownStatusID"
    nonisolated static let companionStatusIDKey = "companionStatusID"

    /// The followed check-in a tapped notification is about, if it is one of these.
    nonisolated static func statusID(in userInfo: [AnyHashable: Any]) -> Int? {
        userInfo[statusIDKey] as? Int
    }

    /// The user's own check-in that was liked.
    nonisolated static func ownStatusID(in userInfo: [AnyHashable: Any]) -> Int? {
        userInfo[ownStatusIDKey] as? Int
    }

    /// The check-in of someone who joined the user's train.
    nonisolated static func companionStatusID(in userInfo: [AnyHashable: Any]) -> Int? {
        userInfo[companionStatusIDKey] as? Int
    }
}

/// Who of the people the user follows on Träwelling is on a train right now (#196): a small button
/// above "Deine Reisen" that lists them, each person once (#267). Someone with several check-ins (19:10–19:20
/// and 19:22–19:30) opens into their check-ins by departure, each open at first (up to 2, else folded); a single one is the card
/// itself. A check-in lists its tags, train, from → to; opening it shows its train, a small map of the ride
/// with the train's live position and speed, a link to the check-in on Träwelling and a like button.
/// Nothing shows while nobody is checked in.
struct FollowedCheckinsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showsList = false
    /// The check-ins shown open.
    @State private var openIDs: Set<Int> = []
    /// The people with several check-ins whose list is unfolded.
    @State private var openPeople: Set<Int> = []
    /// Up to this many check-ins open together with their person; more stay folded.
    private static let unfoldingLimit = 2

    var body: some View {
        if let followed = model.followedCheckins {
            // A ride that ended since the last refresh is gone right away.
            let people = TraewellingClient.grouped(followed.statuses.filter { ($0.checkin.end ?? .distantPast) > .now })
            if !people.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    toggleButton(people)
                    if showsList {
                        ForEach(people) { person in
                            personRow(person, likesEnabled: followed.likesEnabled)
                                .transition(.fold)
                        }
                    }
                }
                // A tapped notification's check-in (#266), as soon as the list has it.
                .onChange(of: model.followedCheckinToOpen, initial: true) { openRequested(in: people) }
                .onChange(of: people.flatMap(\.statuses).map(\.id)) { openRequested(in: people) }
            }
        }
    }

    @ViewBuilder
    private func personRow(_ person: FollowedPerson, likesEnabled: Bool) -> some View {
        if person.statuses.count == 1, let status = person.statuses.first {
            checkinCard(status, likesEnabled: likesEnabled, showsPerson: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                FollowedPersonHeader(person: person, isOpen: openPeople.contains(person.id)) {
                    withAnimation(.snappy) {
                        if openPeople.remove(person.id) == nil {
                            openPeople.insert(person.id)
                            // Their check-ins unfold with them, unless there are so many that the list would get long.
                            if person.statuses.count <= Self.unfoldingLimit { openIDs.formUnion(person.statuses.map(\.id)) }
                        }
                    }
                }
                if openPeople.contains(person.id) {
                    ForEach(person.statuses, id: \.id) { status in
                        checkinCard(status, likesEnabled: likesEnabled, showsPerson: false)
                            .padding(.leading, 16)
                            .transition(.fold)
                    }
                }
            }
        }
    }

    private func checkinCard(_ status: TraewellingStatus, likesEnabled: Bool, showsPerson: Bool) -> some View {
        FollowedCheckinCard(status: status, likesEnabled: likesEnabled, showsPerson: showsPerson,
                            isOpen: openIDs.contains(status.id)) {
            withAnimation(.snappy) {
                if openIDs.remove(status.id) == nil { openIDs.insert(status.id) }
            }
        }
    }

    private func openRequested(in people: [FollowedPerson]) {
        guard let id = model.followedCheckinToOpen,
              let person = people.first(where: { $0.statuses.contains { $0.id == id } }) else { return }
        model.followedCheckinToOpen = nil
        withAnimation(.snappy) {
            showsList = true
            // Someone with several check-ins unfolds, else the card would stay hidden in their list.
            if person.statuses.count > 1 { openPeople.insert(person.id) }
            openIDs.insert(id)
        }
    }

    private func toggleButton(_ people: [FollowedPerson]) -> some View {
        let title = people.count == 1
            ? String(localized: "\(people[0].user.displayName) ist eingecheckt")
            : String(localized: "\(people.count) Leute sind eingecheckt")
        return Button {
            withAnimation(.snappy) { showsList.toggle() }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(people.prefix(3)) { person in
                        TraewellingAvatar(url: person.user.profilePicture, size: 22)
                            .overlay { Circle().stroke(Color.card, lineWidth: 1.5) }
                    }
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(showsList ? 180 : 0))
            }
            // The text's own color, never the accent the glass button would tint it with (#504).
            .foregroundStyle(.primary)
        }
        .pageButtonStyle()
        .accessibilityHint(showsList ? "Blendet die Check-ins aus" : "Zeigt, wer gerade eingecheckt ist")
    }
}

/// A person with several check-ins: their name once, unfolding into the check-ins.
private struct FollowedPersonHeader: View {
    let person: FollowedPerson
    let isOpen: Bool
    let toggle: () -> Void
    @Environment(\.appDesign) private var design

    var body: some View {
        Card {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    TraewellingAvatar(url: person.user.profilePicture, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(person.user.displayName)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(design == .fahrkarte ? .rounded : nil)
                            Text("@\(person.user.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Text("\(person.statuses.count) Check-ins")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One followed user's running check-in: the preview, and when opened its train, map, link and like.
private struct FollowedCheckinCard: View {
    let status: TraewellingStatus
    let likesEnabled: Bool
    /// Whether the card names the person; inside their own list it doesn't repeat it.
    let showsPerson: Bool
    let isOpen: Bool
    let toggle: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.appDesign) private var design
    /// The train in the timetable data (Transitous), once found.
    @State private var trainLeg: Leg?
    @State private var isSearchingTrain = false
    @State private var searchedTrain = false
    /// The timetable couldn't be asked (no answer, server error), as opposed to not having the train.
    @State private var trainLookupFailed = false
    @State private var showTrain = false
    /// The ride's track from Träwelling once asked for (empty: it has none, or it couldn't be loaded).
    @State private var geometry: [Coordinate]?
    @State private var emojis: [CustomEmoji] = []
    /// The like state after tapping, until the next refresh brings Träwelling's.
    @State private var liked: Bool?
    @State private var likes: Int?
    @State private var isLiking = false
    @State private var error: Error?

    private var checkin: TraewellingStatus.Checkin { status.checkin }
    // What an earlier opening looked up counts at once (`AppModel.followedTracks`/`followedTrains`).
    private var track: [Coordinate]? { geometry ?? model.followedTracks[status.id] }
    private var train: Leg? { trainLeg ?? model.followedTrains[status.id] }
    private var trainSearched: Bool { searchedTrain || model.followedTrains[status.id] != nil }
    private var ride: Leg? { status.journey(geometry: track.flatMap { $0.isEmpty ? nil : $0 })?.legs.first }
    private var origin: String { checkin.origin.station?.name ?? checkin.origin.name ?? "?" }
    private var destination: String { checkin.destination.station?.name ?? checkin.destination.name ?? "?" }

    /// The run number, unless the train's name already has it ("ICE 123", but "RE 1" runs as 4711).
    private var runNumber: String? {
        guard let number = checkin.journeyNumber.map(String.init) else { return nil }
        let name = checkin.lineName ?? ""
        return name.split(separator: " ").contains { $0 == number } ? nil : number
    }

    /// The train's route for the map: the timetable's run with its stops if found, else Träwelling's ride,
    /// along Träwelling's track.
    private var route: LiveTrainRoute? {
        guard var leg = train ?? ride else { return nil }
        if leg.geometry?.isEmpty ?? true, let track, !track.isEmpty { leg.geometry = track }
        return LiveTrainRoute(leg: leg)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: toggle) { preview }
                    .buttonStyle(.plain)
                if isOpen {
                    details.transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showTrain) {
            if let train { LegTripSheet(leg: train) }
        }
        // Each on its own, so the track shows as soon as Träwelling sends it, however long the train search takes.
        .task(id: isOpen) {
            guard isOpen else { return }
            await loadTrack()
        }
        .task(id: isOpen) {
            guard isOpen else { return }
            await findTrain()
        }
        // A train not found is looked for again the next time the card opens.
        .onChange(of: isOpen) {
            if !isOpen, train == nil {
                searchedTrain = false
                trainLookupFailed = false
            }
        }
        .task(id: isOpen) {
            guard isOpen, emojis.isEmpty, model.followedEmojis[status.id] == nil,
                  status.body?.contains(":") ?? false else { return }
            emojis = await model.emojis(forTextOf: status)
        }
        .onChange(of: status.liked) {
            liked = nil
            likes = nil
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if showsPerson { TraewellingAvatar(url: status.user?.profilePicture, size: 36) }
                VStack(alignment: .leading, spacing: 5) {
                    if showsPerson {
                        HStack(spacing: 4) {
                            Text(status.user?.displayName ?? String(localized: "Träwelling-Nutzer"))
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(design == .fahrkarte ? .rounded : nil)
                            if let username = status.user?.username {
                                Text("@\(username)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let line = ride?.line { LineBadge(line: line, size: .small) }
                        if let runNumber {
                            Text("Zug \(runNumber)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        // Checked in, but the train hasn't left yet.
                        if let start = checkin.start, start > .now {
                            Text("fährt \(start.timeString) ab")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.brandReadable)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(origin) → \(destination)")
                            .font(.caption)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if let start = checkin.start, let end = checkin.end {
                            Text("\(start.timeString)–\(end.timeString)")
                                .font(.caption)
                                .fontDesign(design == .fahrkarte ? .rounded : nil)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .padding(.top, 4)
            }
            if !status.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(status.tags, id: \.key) { tag in
                            InfoChip(text: "\(model.statusTagLabel(tag.key)): \(tag.value)",
                                     systemImage: model.statusTagIcon(tag.key), tint: .brandReadable)
                        }
                    }
                }
            }
        }
        .contentShape(.rect)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let body = status.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                EmojiText(text: body, emojis: emojis.isEmpty ? model.followedEmojis[status.id] ?? [] : emojis)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            if let route {
                // No line until the track is known: drawn from start to end first, it would jump.
                FollowedRideMap(route: route, showsPath: track != nil)
            }
            // One line: if all buttons don't fit (small iPhone, large text), Träwelling shows only its icon.
            ViewThatFits(in: .horizontal) {
                actionButtons(compact: false)
                actionButtons(compact: true)
            }
            if trainSearched, train == nil, !checkin.isManualTrip {
                Text("Den Zug gibt es in den Fahrplandaten nicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if trainLookupFailed, !isSearchingTrain {
                HStack(spacing: 8) {
                    Text("Der Zug konnte nicht geladen werden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Erneut versuchen") { Task { await findTrain() } }
                        .font(.caption.weight(.semibold))
                }
            }
            if let error { ErrorBanner(error: error) }
        }
    }

    private func actionButtons(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if !checkin.isManualTrip { trainButton }
            Button {
                openURL(model.traewelling.config.baseURL.appending(path: "status/\(status.id)"))
            } label: {
                if compact {
                    Label("Träwelling", systemImage: "safari").labelStyle(.iconOnly)
                } else {
                    Label("Träwelling", systemImage: "safari")
                }
            }
            if likesEnabled, status.isLikable != false { likeButton }
        }
        .lineLimit(1)
        .font(.subheadline.weight(.medium))
        .compactActionStyle()
        .controlSize(.small)
    }

    private var trainButton: some View {
        Button {
            showTrain = true
        } label: {
            if isSearchingTrain {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Zug")
                }
            } else {
                Label("Zug", systemImage: "train.side.front.car")
            }
        }
        .disabled(train == nil)
    }

    private var likeButton: some View {
        let isLiked = liked ?? status.liked ?? false
        let count = likes ?? status.likes ?? 0
        return Button {
            Task { await toggleLike() }
        } label: {
            Label {
                Text("\(count)").monospacedDigit()
            } icon: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    // Pink once liked, else the button's own color.
                    .foregroundStyle(isLiked ? AnyShapeStyle(Color.pink) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            }
        }
        .tint(isLiked ? .pink : nil)
        .disabled(isLiking)
        .accessibilityLabel(isLiked ? "Gefällt mir nicht mehr" : "Gefällt mir")
        .accessibilityValue("\(count)")
    }

    /// Träwelling's track of the ride. Only an answer is remembered; a failed request is asked again next time.
    private func loadTrack() async {
        let id = status.id
        guard model.followedTracks[id] == nil else { return }
        if let lines = try? await model.traewelling.polylines(statusIDs: [id]) {
            let line = lines[id].flatMap { $0.count > 1 ? $0 : nil } ?? []
            model.followedTracks[id] = line
            geometry = line
        } else {
            geometry = []
        }
    }

    /// The train in the timetable data; like the track, remembered once the search got an answer.
    private func findTrain() async {
        guard !checkin.isManualTrip, !trainSearched else { return }
        isSearchingTrain = true
        trainLookupFailed = false
        defer { isSearchingTrain = false }
        do {
            let found = try await model.followedTrain(for: status)
            trainLeg = found
            searchedTrain = true
        } catch {
            // Folding the card away cancels the lookup: that says nothing about the train, so it isn't
            // taken for one the timetable doesn't have. Other errors are shown, with a way to retry.
            if !Task.isCancelled { trainLookupFailed = true }
        }
    }

    private func toggleLike() async {
        let wasLiked = liked ?? status.liked ?? false
        let before = likes ?? status.likes ?? 0
        liked = !wasLiked
        likes = max(0, before + (wasLiked ? -1 : 1))
        isLiking = true
        error = nil
        defer { isLiking = false }
        do {
            let count = wasLiked ? try await model.traewelling.unlike(statusId: status.id)
                                 : try await model.traewelling.like(statusId: status.id)
            if let count { likes = count }
        } catch {
            liked = wasLiked
            likes = before
            self.error = error
        }
    }
}

/// A small map of the ride with the train's live position and speed (bahn.jetzt) while it has one;
/// tapping opens the full live map.
private struct FollowedRideMap: View {
    let route: LiveTrainRoute
    var showsPath = true

    @Environment(AppModel.self) private var model
    @State private var position: TrainPosition?
    @State private var camera: MapCameraPosition = .automatic
    @State private var showMap = false

    private var color: Color { route.line?.color ?? .brand }

    var body: some View {
        Button {
            showMap = true
        } label: {
            Map(position: $camera, interactionModes: []) {
                if showsPath, route.path.count > 1 {
                    MapPolyline(coordinates: route.path.map(\.clCoordinate))
                        .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                ForEach([route.stops.first, route.stops.last].compactMap { $0 }) { stop in
                    if let coordinate = stop.station.coordinate {
                        Annotation(stop.station.displayName, coordinate: coordinate.clCoordinate, anchor: .center) {
                            Circle()
                                .fill(.white)
                                .stroke(color, lineWidth: 2.5)
                                .frame(width: 11, height: 11)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                if let position {
                    Annotation(route.line?.name ?? String(localized: "Zug"), coordinate: position.coordinate.clCoordinate, anchor: .center) {
                        Image(systemName: route.line?.symbolName ?? "tram.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(position.isStale() ? Color.gray : color, in: .circle)
                            .overlay { Circle().stroke(.white, lineWidth: 2) }
                            .shadow(radius: 2)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
            .frame(height: 170)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottomLeading) { liveChip.padding(8) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live-Karte öffnen")
        .sheet(isPresented: $showMap) {
            LiveTrainMapView(route: route)
        }
        .onChange(of: route) { camera = .automatic }
        .task(id: route) {
            position = nil
            guard route.isSupported, route.mayBeRunning() else { return }
            await model.followPosition(of: route) { position = $0 }
        }
    }

    @ViewBuilder private var liveChip: some View {
        if let position {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                if let speed = position.speedKmh {
                    Text("\(Int(speed.rounded())) km/h").monospacedDigit()
                } else {
                    Text("Live")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(position.isStale() ? Color.secondary : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: .capsule)
        }
    }
}

/// A Träwelling user's profile picture, or a person icon while it loads or without one.
struct TraewellingAvatar: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: - Small action buttons

extension View {
    /// The small buttons inside a card (Zug, Träwelling, like). Minimal: a flat, softly filled capsule.
    /// Fahrkarte: Liquid Glass.
    func compactActionStyle() -> some View {
        modifier(CompactActionStyle())
    }
}

private struct CompactActionStyle: ViewModifier {
    @Environment(\.appDesign) private var design

    func body(content: Content) -> some View {
        if design == .fahrkarte {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(CompactFlatButtonStyle())
        }
    }
}

private struct CompactFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactFlatButtonBody(configuration: configuration)
    }
}

private struct CompactFlatButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.07), in: .capsule)
            .contentShape(.capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
