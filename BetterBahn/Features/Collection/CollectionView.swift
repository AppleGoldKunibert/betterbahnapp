import BetterBahnKit
import SwiftUI

/// The collection ("Sammlung", #384): special liveries, series, named trainsets and big stations, each
/// with its progress; opened from the Verbindungen tab next to "Vergangene Fahrten". Computed on the
/// device from Kit `TravelCollection`.
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    @State private var collection: TravelCollection?
    /// Collected since the last visit; kept for this visit, so the "Neu" badges stay while looking.
    @State private var newIDs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let collection {
                    ForEach(collection.groups) { group in
                        NavigationLink {
                            CollectionCategoryView(group: group, newIDs: newIDs)
                        } label: {
                            CollectionGroupCard(group: group, newCount: group.items.count(where: { newIDs.contains($0.id) }))
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink {
                        TzListView(collection: collection)
                    } label: {
                        TzListCard()
                    }
                    .buttonStyle(.plain)
                    Text("Zählt deine gespeicherten Reisen und Träwelling-Check-ins. Züge zählen, wenn wir die Wagenreihung kennen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    ProgressView().padding(.top, 60)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .tabBarSafePadding()
        .background { AppBackground() }
        .navigationTitle("Sammlung")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard collection == nil else { return }
            let loaded = await model.travelCollection()
            newIDs = model.newCollectionIDs(in: loaded)
            model.markCollectionSeen(loaded)
            collection = loaded
        }
    }
}

extension TravelCollection.Category {
    var systemImage: String {
        switch self {
        case .liveries: "paintpalette.fill"
        case .series: "train.side.front.car"
        case .trainsets: "number"
        case .stations: "building.columns.fill"
        }
    }

    /// When an item of this category counts, shown for one not collected yet.
    var hint: String {
        switch self {
        case .liveries, .series, .trainsets: String(localized: "Zählt, sobald du in einer gespeicherten Reise mit diesem Zug gefahren bist.")
        case .stations: String(localized: "Zählt, wenn du hier ein-, aus- oder umsteigst.")
        }
    }
}

private struct CollectionGroupCard: View {
    let group: TravelCollection.Group
    let newCount: Int

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: group.category.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.brand.gradient, in: .rect(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.category.title).font(.headline)
                        Text("\(group.collected) von \(group.total) gesammelt")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if newCount > 0 { NewBadge(text: "\(newCount) neu") }
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                ProgressView(value: Double(group.collected), total: Double(max(group.total, 1)))
                    .tint(.brand)
            }
        }
        .contentShape(.rect)
    }
}

/// The entry to the list of every ICE and IC trainset and where it runs (#502).
private struct TzListCard: View {
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "list.number")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.brand.gradient, in: .rect(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alle Triebzüge").font(.headline)
                    Text("Welcher Tz fährt heute auf welchem Zug?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }
}

private struct NewBadge: View {
    var text: LocalizedStringKey = "Neu"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.brand, in: .capsule)
    }
}

/// One category's items as a grid, the ones not collected yet greyed out; collected first.
struct CollectionCategoryView: View {
    let group: TravelCollection.Group
    let newIDs: Set<String>
    @State private var selected: TravelCollection.Item?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(group.collected) von \(group.total) gesammelt")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(group.collected), total: Double(max(group.total, 1)))
                    .tint(.brand)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(sortedItems) { item in
                        Button { selected = item } label: {
                            CollectionTile(item: item, isNew: newIDs.contains(item.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .tabBarSafePadding()
        .background { AppBackground() }
        .navigationTitle(group.category.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { item in
            CollectionItemSheet(item: item)
                .presentationDetents([.medium, .large])
        }
    }

    private var sortedItems: [TravelCollection.Item] {
        group.items.filter(\.isCollected) + group.items.filter { !$0.isCollected }
    }
}

private struct CollectionTile: View {
    let item: TravelCollection.Item
    let isNew: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: item.category.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(item.isCollected ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(item.isCollected ? AnyShapeStyle(Color.brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.15)),
                            in: .rect(cornerRadius: 12, style: .continuous))
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(8)
        .background(Color.card, in: .rect(cornerRadius: 16, style: .continuous))
        .opacity(item.isCollected ? 1 : 0.55)
        .overlay(alignment: .topTrailing) {
            if isNew { NewBadge().offset(x: 4, y: -4) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isCollected ? "Gesammelt" : "Noch nicht gesammelt")
    }
}

/// When and on which rides an item was collected.
private struct CollectionItemSheet: View {
    let item: TravelCollection.Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.title3.weight(.semibold))
                        if let subtitle = item.subtitle {
                            Text(subtitle).foregroundStyle(.secondary)
                        }
                    }
                }
                if let first = item.firstSighting {
                    if let number = item.unitNumber {
                        // A Tz or livery: its trips on top, yours and every one the server saw.
                        Section {
                            NavigationLink {
                                TzRunsView(number: number, title: item.title, subtitle: item.subtitle,
                                           rides: item.sightings, startsWithAll: false)
                            } label: {
                                Label("Fahrten", systemImage: "train.side.front.car")
                            }
                        }
                        Section("Zuerst gesammelt") { SightingRow(sighting: first) }
                    } else {
                        Section("Zuerst gesammelt") { SightingRow(sighting: first) }
                        if item.sightings.count > 1 {
                            Section("Alle \(item.sightings.count) Fahrten") {
                                ForEach(Array(item.sightings.enumerated()), id: \.offset) { SightingRow(sighting: $0.element) }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Noch nicht gesammelt.").font(.headline)
                        Text(item.category.hint).foregroundStyle(.secondary)
                    }
                    if let number = item.unitNumber {
                        Section {
                            NavigationLink {
                                TzRunsView(number: number, title: item.title, subtitle: item.subtitle,
                                           rides: [], startsWithAll: true)
                            } label: {
                                Label("Fahrten", systemImage: "train.side.front.car")
                            }
                        }
                    }
                }
            }
            .navigationTitle(item.category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

struct SightingRow: View {
    let sighting: TravelCollection.Sighting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sighting.date.formatted(date: .long, time: .omitted)).font(.subheadline.weight(.semibold))
            Text([sighting.train, "\(sighting.from) → \(sighting.to)"].compactMap(\.self).joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The entry on the Verbindungen tab, with how many items were collected since the last visit.
struct CollectionButton: View {
    @Environment(AppModel.self) private var model
    @State private var newCount = 0

    var body: some View {
        RouteLink(value: ConnectionsRoute.collection) {
            Label("Sammlung", systemImage: "square.grid.3x3.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if newCount > 0 { NewBadge(text: "\(newCount)").offset(x: 6, y: -10) }
                }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .accessibilityValue(newCount > 0 ? String(localized: "\(newCount) neu gesammelt") : "")
        .task(id: "\(model.savedJourneys.count)|\(model.traewellingTrips.count)") {
            newCount = model.newCollectionIDs(in: await model.travelCollection()).count
        }
    }
}

// MARK: - Data

extension AppModel {
    private static let collectionSeenKey = "collectionSeenIDs"

    /// The collection from every ride the travel map draws; trainsets from the formations remembered for
    /// saved journeys, also where a Träwelling check-in replaced the saved leg.
    func travelCollection() async -> TravelCollection {
        await loadTraewellingTrips()
        let all = TravelMapSelection(range: .all, includeTraewelling: settings.traewellingEnabled)
        let legs = travelledLegs(of: mapJourneys(for: all)).map(\.leg)
        let rides = zip(legs, rememberedFormations(for: legs)).map { leg, formation in
            TravelCollection.Ride(leg: leg, formation: formation)
        }
        return await Task.detached(priority: .userInitiated) { TravelCollection(rides: rides) }.value
    }

    /// Items collected since the collection was last opened. The first time, everything collected so far
    /// becomes the starting point, so it doesn't all show up as new.
    func newCollectionIDs(in collection: TravelCollection) -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: Self.collectionSeenKey)
        if stored == nil { markCollectionSeen(collection) }
        return collection.newIDs(since: stored.map { Set($0) })
    }

    func markCollectionSeen(_ collection: TravelCollection) {
        UserDefaults.standard.set(collection.collectedIDs.sorted(), forKey: Self.collectionSeenKey)
    }
}
