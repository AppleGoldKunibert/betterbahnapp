import AppIntents
import BetterBahnKit
import CoreSpotlight
import Foundation
import os
import UniformTypeIdentifiers

/// Favourite stations and saved journeys in the iOS search (#387). Each entry (Kit `SpotlightEntry`) is
/// indexed with its App Intents entity, so the same stations and journeys can later serve Shortcuts and
/// Siri too. A tapped result opens its deep link: through the entity's `OpenIntent`, or the
/// `CSSearchableItemActionType` activity in `RootView`.
extension AppModel {
    /// IDs of the entries in the index, so the ones gone since are removed.
    private static let spotlightIDsKey = "spotlightIDs"

    /// Brings the index up to date with the favourites and saved journeys, a moment after the last
    /// change: saved journeys change with every refresh, and iCloud hands over several at once.
    func scheduleSpotlightSync() {
        spotlightSync?.cancel()
        spotlightSync = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await syncSpotlight()
        }
    }

    /// Opens a link from the Spotlight intents: `RootView` handles it like any other deep link.
    func openLink(_ url: URL) {
        linkToOpen = url
    }

    private func syncSpotlight() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let favorites = favoriteStations
        let journeys = savedJourneys.map(\.journey)
        // RIL100 codes take a look through the whole list per station, so not on the main thread.
        let entries = await Task.detached(priority: .utility) {
            SpotlightEntry.entries(favorites: favorites, journeys: journeys)
        }.value
        // A newer change is already waiting, or nothing changed for Spotlight (most refreshes).
        guard !Task.isCancelled, entries != lastSpotlightEntries else { return }
        lastSpotlightEntries = entries
        let previous = UserDefaults.standard.stringArray(forKey: Self.spotlightIDsKey) ?? []
        let removed = SpotlightEntry.removedIDs(previous: previous, current: entries)
        UserDefaults.standard.set(entries.map(\.id), forKey: Self.spotlightIDsKey)
        await Task.detached(priority: .utility) {
            await Self.index(entries, removing: removed)
        }.value
    }

    private nonisolated static func index(_ entries: [SpotlightEntry], removing removed: [String]) async {
        let index = CSSearchableIndex.default()
        let items = entries.map { entry in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = entry.title
            attributes.contentDescription = entry.subtitle
            attributes.keywords = entry.keywords
            let item = CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: entry.kind.rawValue, attributeSet: attributes)
            // Without a date Spotlight drops an item after a month.
            item.expirationDate = entry.expiry ?? .distantFuture
            switch entry.kind {
            case .station:
                if let entity = FavoriteStationEntity(entry: entry) { item.associateAppEntity(entity, priority: 0) }
            case .journey:
                if let entity = SavedJourneyEntity(entry: entry) { item.associateAppEntity(entity, priority: 0) }
            }
            return item
        }
        do {
            if !removed.isEmpty { try await index.deleteSearchableItems(withIdentifiers: removed) }
            try await index.indexSearchableItems(items)
        } catch {
            Logger(subsystem: "BetterBahn", category: "Spotlight").error("Spotlight index failed: \(error.localizedDescription)")
        }
    }
}

// MARK: Entities

/// A favourite station; opens its departure board. Its ID is the station itself
/// (`BoardWidgetLink.encode`), like the board widget's `StationEntity`.
nonisolated struct FavoriteStationEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Bahnhof" }
    static var defaultQuery: FavoriteStationQuery { FavoriteStationQuery() }

    let station: Station

    var id: String { BoardWidgetLink.encode(station) }

    init(station: Station) {
        self.station = station
    }

    init?(entry: SpotlightEntry) {
        guard case .board(let station) = BoardWidgetLink.target(from: entry.url) else { return nil }
        self.station = station
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(station.displayName)", subtitle: station.region.map { LocalizedStringResource("\($0)") })
    }
}

nonisolated struct FavoriteStationQuery: EntityQuery {
    @Dependency private var model: AppModel

    func entities(for identifiers: [String]) async throws -> [FavoriteStationEntity] {
        identifiers.compactMap(BoardWidgetLink.decode).map(FavoriteStationEntity.init)
    }

    func suggestedEntities() async throws -> [FavoriteStationEntity] {
        let model = model
        return await MainActor.run { model.favoriteStations }.map(FavoriteStationEntity.init)
    }
}

/// A saved journey that isn't over yet; opens it. Its ID is the journey's (`Journey.id`), as in
/// the Live Activity's link.
nonisolated struct SavedJourneyEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Reise" }
    static var defaultQuery: SavedJourneyQuery { SavedJourneyQuery() }

    let id: String
    let title: String
    let subtitle: String?

    init?(entry: SpotlightEntry) {
        guard let id = LiveActivityLink.journeyID(from: entry.url) else { return nil }
        self.id = id
        title = entry.title
        subtitle = entry.subtitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { LocalizedStringResource("\($0)") })
    }
}

nonisolated struct SavedJourneyQuery: EntityQuery {
    @Dependency private var model: AppModel

    func entities(for identifiers: [String]) async throws -> [SavedJourneyEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SavedJourneyEntity] {
        let model = model
        let journeys = await MainActor.run { model.savedJourneys.map(\.journey) }
        return journeys.compactMap { SpotlightEntry.journey($0) }.compactMap(SavedJourneyEntity.init)
    }
}

// MARK: Opening

nonisolated struct OpenFavoriteStationIntent: OpenIntent {
    static var title: LocalizedStringResource { "Abfahrten öffnen" }

    @Parameter(title: "Bahnhof") var target: FavoriteStationEntity
    @Dependency private var model: AppModel

    func perform() async throws -> some IntentResult {
        await model.openLink(BoardWidgetLink.url(station: target.station))
        return .result()
    }
}

nonisolated struct OpenSavedJourneyIntent: OpenIntent {
    static var title: LocalizedStringResource { "Reise öffnen" }

    @Parameter(title: "Reise") var target: SavedJourneyEntity
    @Dependency private var model: AppModel

    func perform() async throws -> some IntentResult {
        await model.openLink(LiveActivityLink.url(journeyID: target.id))
        return .result()
    }
}
