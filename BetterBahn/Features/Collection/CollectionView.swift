import BetterBahnKit
import SwiftUI

/// The collection ("Sammlung", #384): special liveries, series, trainsets and big stations, each
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
                        // Pushed by value like the journeys opened from there: a view-based link mixed with
                        // the stack's path put this page back on top of an opened journey.
                        NavigationLink(value: ConnectionsRoute.collectionCategory(group.category)) {
                            CollectionGroupCard(group: group, newCount: group.items.count(where: { newIDs.contains($0.id) }))
                        }
                        .buttonStyle(.plain)
                    }
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
            model.collectionSnapshot = CollectionSnapshot(collection: loaded, newIDs: newIDs)
            collection = loaded
        }
    }
}

/// The collection with the items new on this visit, kept for its category pages.
struct CollectionSnapshot {
    var collection: TravelCollection
    var newIDs: Set<String>
}

/// A category of the collection opened from `CollectionView`.
struct CollectionCategoryPage: View {
    let category: TravelCollection.Category
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.collectionSnapshot, let group = snapshot.collection.group(category) {
            if category == .trainsets {
                CollectionTrainsetsView(group: group, series: snapshot.collection.trainsetSeries, newIDs: snapshot.newIDs)
            } else {
                CollectionCategoryView(group: group, newIDs: snapshot.newIDs)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { AppBackground() }
                .task { model.collectionSnapshot = CollectionSnapshot(collection: await model.travelCollection(), newIDs: []) }
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
                    Section("Zuerst gesammelt") { SightingRow(sighting: first) }
                    if item.sightings.count > 1 {
                        Section("Alle \(item.sightings.count) Fahrten") {
                            ForEach(Array(item.sightings.enumerated()), id: \.offset) { SightingRow(sighting: $0.element) }
                        }
                    }
                } else {
                    Section {
                        Text("Noch nicht gesammelt.").font(.headline)
                        Text(item.category.hint).foregroundStyle(.secondary)
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

/// The trainsets by series ("ICE 4") and length ("7-teilig") to expand (#521); a Tz expands to the rides
/// with it, and a ride opens its journey.
struct CollectionTrainsetsView: View {
    let group: TravelCollection.Group
    let series: [TravelCollection.TrainsetSeries]
    let newIDs: Set<String>
    /// The order picked per series, Tz number by default.
    @State private var orders: [String: TravelCollection.TrainsetOrder] = [:]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.collected) von \(group.total) gesammelt")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(group.collected), total: Double(max(group.total, 1)))
                        .tint(.brand)
                }
            }
            ForEach(series) { series in
                Section {
                    DisclosureGroup {
                        let order = orders[series.name] ?? .number
                        Picker("Sortieren", selection: orderBinding(series.name)) {
                            ForEach(TravelCollection.TrainsetOrder.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        if series.variants.count == 1, series.variants[0].name == nil {
                            TrainsetRows(items: order.sorted(series.variants[0].items), newIDs: newIDs)
                        } else {
                            ForEach(series.variants) { variant in
                                DisclosureGroup {
                                    TrainsetRows(items: order.sorted(variant.items), newIDs: newIDs)
                                } label: {
                                    TrainsetGroupLabel(title: variant.title, collected: variant.collected, total: variant.total,
                                                       newCount: variant.items.count(where: { newIDs.contains($0.id) }))
                                }
                            }
                        }
                    } label: {
                        TrainsetGroupLabel(title: series.name, collected: series.collected, total: series.total,
                                           newCount: series.items.count(where: { newIDs.contains($0.id) }), isSeries: true)
                    }
                }
            }
            Section {
                Text(TravelCollection.Category.trainsets.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .tabBarSafePadding()
        .background { AppBackground() }
        .navigationTitle(group.category.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func orderBinding(_ series: String) -> Binding<TravelCollection.TrainsetOrder> {
        Binding { orders[series] ?? .number } set: { orders[series] = $0 }
    }
}

private struct TrainsetGroupLabel: View {
    let title: String
    let collected: Int
    let total: Int
    let newCount: Int
    var isSeries = false

    var body: some View {
        HStack(spacing: 10) {
            if isSeries {
                Image(systemName: TravelCollection.Category.series.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.brand.gradient, in: .rect(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(isSeries ? .headline : .subheadline.weight(.semibold))
                Text("\(collected) von \(total) gesammelt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if newCount > 0 { NewBadge(text: "\(newCount) neu") }
        }
    }
}

/// One row per Tz: a collected one expands to its rides, one not collected yet is greyed out.
private struct TrainsetRows: View {
    let items: [TravelCollection.Item]
    let newIDs: Set<String>

    var body: some View {
        ForEach(items) { item in
            if item.isCollected {
                DisclosureGroup {
                    ForEach(Array(item.sightings.enumerated()), id: \.offset) { _, sighting in
                        CollectionRideLink(sighting: sighting)
                    }
                } label: {
                    TrainsetLabel(item: item, isNew: newIDs.contains(item.id))
                }
            } else {
                TrainsetLabel(item: item, isNew: false)
            }
        }
    }
}

private struct TrainsetLabel: View {
    let item: TravelCollection.Item
    let isNew: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isCollected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isCollected ? Color.brand : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline.weight(.semibold).monospacedDigit())
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isNew { NewBadge() }
            if item.isCollected {
                (item.sightings.count == 1 ? Text("1 Fahrt") : Text("\(item.sightings.count) Fahrten"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(item.isCollected ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isCollected ? "Gesammelt" : "Noch nicht gesammelt")
    }
}

/// A ride of a collected item; opens its journey.
private struct CollectionRideLink: View {
    let sighting: TravelCollection.Sighting
    @Environment(AppModel.self) private var model

    var body: some View {
        if let journey = sighting.journey {
            RouteLink(value: ConnectionsRoute.journey(model.collectionRoute(for: journey))) {
                SightingRow(sighting: sighting)
            }
        } else {
            SightingRow(sighting: sighting)
        }
    }
}

private struct SightingRow: View {
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
        .pageButtonStyle()
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
    private static let unnamedTrainsetsSeenKey = "collectionUnnamedTrainsetsSeen"

    /// The collection from every ride the travel map draws; trainsets from the formations remembered for
    /// saved journeys, also where a Träwelling check-in replaced the saved leg.
    func travelCollection() async -> TravelCollection {
        await loadTraewellingTrips()
        let all = TravelMapSelection(range: .all, includeTraewelling: settings.traewellingEnabled)
        let journeys = mapJourneys(for: all)
        let travelled = travelledLegs(of: journeys)
        let legs = travelled.map(\.leg)
        let rides = zip(travelled, rememberedFormations(for: legs)).map { ride, formation in
            TravelCollection.Ride(leg: ride.leg, formation: formation, journey: journeys[ride.group])
        }
        return await Task.detached(priority: .userInitiated) { TravelCollection(rides: rides) }.value
    }

    /// Items collected since the collection was last opened. The first time, everything collected so far
    /// becomes the starting point, so it doesn't all show up as new; the same once for the trainsets without
    /// a name, which only count since #521.
    func newCollectionIDs(in collection: TravelCollection) -> Set<String> {
        let defaults = UserDefaults.standard
        var stored = defaults.stringArray(forKey: Self.collectionSeenKey)
        if stored == nil { markCollectionSeen(collection) }
        if !defaults.bool(forKey: Self.unnamedTrainsetsSeenKey) {
            defaults.set(true, forKey: Self.unnamedTrainsetsSeenKey)
            if let seen = stored {
                stored = Array(Set(seen).union(collection.collectedUnnamedTrainsetIDs)).sorted()
                defaults.set(stored, forKey: Self.collectionSeenKey)
            }
        }
        return collection.newIDs(since: stored.map { Set($0) })
    }

    /// The journey of a ride in the collection: the saved journey (also one a check-in replaced), else the
    /// check-in itself.
    func collectionRoute(for journey: Journey) -> JourneyRoute {
        let keys = Set(journey.legs.map(\.formationKey))
        let saved = pastJourneys.first { $0.journey.id == journey.id }
            ?? pastJourneys.first { $0.journey.legs.contains { keys.contains($0.formationKey) } }
        if let saved { return saved.route(readOnly: true) }
        return JourneyRoute(journey: journey, finalDestination: journey.legs.last?.destination ?? journey.legs[0].destination,
                            readOnly: true)
    }

    func markCollectionSeen(_ collection: TravelCollection) {
        UserDefaults.standard.set(collection.collectedIDs.sorted(), forKey: Self.collectionSeenKey)
    }
}
