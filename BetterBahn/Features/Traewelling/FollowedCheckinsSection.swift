import BetterBahnKit
import MapKit
import SwiftUI

extension AppModel {
    /// How often the check-ins of the people the user follows are reloaded while they're on screen.
    static let followedCheckinsInterval: Duration = .seconds(120)

    /// Keeps `followedCheckins` fresh for as long as the calling task runs (the Verbindungen tab).
    /// Coming back to the tab within the interval doesn't load again.
    func keepFollowedCheckinsFresh() async {
        while !Task.isCancelled {
            if settings.traewellingEnabled, await traewelling.isLoggedIn {
                let due = followedCheckinsLoadedAt.map { Date.now.timeIntervalSince($0) >= 110 } ?? true
                if due, let fresh = try? await traewelling.followedCheckins() {
                    followedCheckins = fresh
                    followedCheckinsLoadedAt = .now
                    let current = Set(fresh.statuses.map(\.id))
                    followedTracks = followedTracks.filter { current.contains($0.key) }
                    followedTrains = followedTrains.filter { current.contains($0.key) }
                    followedEmojis = followedEmojis.filter { current.contains($0.key) }
                    await prepareEmojis(for: fresh.statuses)
                }
            } else {
                followedCheckins = nil
                followedCheckinsLoadedAt = nil
            }
            try? await Task.sleep(for: Self.followedCheckinsInterval)
        }
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

/// Who of the people the user follows on Träwelling is on a train right now (#196): a small button
/// above "Deine Reisen" that lists their check-ins (tags, train, from → to). Opening one shows its
/// train, a small map of the ride with the train's live position and speed, a link to the check-in on
/// Träwelling and a like button. Nothing shows while nobody is checked in.
struct FollowedCheckinsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showsList = false
    @State private var openID: Int?

    var body: some View {
        if let followed = model.followedCheckins {
            // A ride that ended since the last refresh is gone right away.
            let statuses = followed.statuses.filter { ($0.checkin.end ?? .distantPast) > .now }
            if !statuses.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    toggleButton(statuses)
                    if showsList {
                        ForEach(statuses, id: \.id) { status in
                            FollowedCheckinCard(status: status, likesEnabled: followed.likesEnabled,
                                                isOpen: openID == status.id) {
                                withAnimation(.snappy) { openID = openID == status.id ? nil : status.id }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
    }

    private func toggleButton(_ statuses: [TraewellingStatus]) -> some View {
        let users = statuses.compactMap(\.user)
        let title = statuses.count == 1
            ? "\(users.first?.displayName ?? "Jemand") ist eingecheckt"
            : "\(statuses.count) Leute sind eingecheckt"
        return Button {
            withAnimation(.snappy) { showsList.toggle() }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(users.prefix(3), id: \.id) { user in
                        TraewellingAvatar(url: user.profilePicture, size: 22)
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
        }
        .buttonStyle(.glass)
        .accessibilityHint(showsList ? "Blendet die Check-ins aus" : "Zeigt, wer gerade eingecheckt ist")
    }
}

/// One followed user's running check-in: the preview, and when opened its train, map, link and like.
private struct FollowedCheckinCard: View {
    let status: TraewellingStatus
    let likesEnabled: Bool
    let isOpen: Bool
    let toggle: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The train in the timetable data (Transitous), once found.
    @State private var trainLeg: Leg?
    @State private var isSearchingTrain = false
    @State private var searchedTrain = false
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
    private var train: Leg? { trainLeg ?? model.followedTrains[status.id] ?? nil }
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
                TraewellingAvatar(url: status.user?.profilePicture, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(status.user?.displayName ?? "Träwelling-Nutzer")
                            .font(.subheadline.weight(.semibold))
                        if let username = status.user?.username {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
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
                                .foregroundStyle(Color.brand)
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
                                     systemImage: model.statusTagIcon(tag.key), tint: .brand)
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
            HStack(spacing: 8) {
                if !checkin.isManualTrip { trainButton }
                Button {
                    openURL(model.traewelling.config.baseURL.appending(path: "status/\(status.id)"))
                } label: {
                    Label("Träwelling", systemImage: "safari")
                }
                if likesEnabled, status.isLikable != false { likeButton }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.glass)
            .controlSize(.small)
            if trainSearched, train == nil, !checkin.isManualTrip {
                Text("Den Zug gibt es in den Fahrplandaten nicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error { ErrorBanner(error: error) }
        }
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
            Label(count > 0 ? "\(count)" : "Gefällt mir", systemImage: isLiked ? "heart.fill" : "heart")
                .monospacedDigit()
        }
        .tint(isLiked ? .pink : nil)
        .disabled(isLiking)
        .accessibilityLabel(isLiked ? "Gefällt mir nicht mehr" : "Gefällt mir")
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
        defer { isSearchingTrain = false }
        do {
            let found = try await model.provider.leg(forCheckin: status)
            model.followedTrains[status.id] = .some(found)
            trainLeg = found
        } catch {}
        searchedTrain = true
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

    private var color: Color { route.line?.product.color ?? .brand }

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
                    Annotation(route.line?.name ?? "Zug", coordinate: position.coordinate.clCoordinate, anchor: .center) {
                        Image(systemName: route.line?.product.symbolName ?? "tram.fill")
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
