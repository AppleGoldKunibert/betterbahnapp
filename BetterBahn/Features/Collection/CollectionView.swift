import BetterBahnKit
import SwiftUI

/// The collection ("Sammlung", #384): special liveries, series, named trainsets and big stations, each
/// with its progress; opened from the Verbindungen tab next to "Vergangene Fahrten". Computed on the
/// device from Kit `TravelCollection`.
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appDesign) private var design
    @State private var collection: TravelCollection?
    /// Collected since the last visit; kept for this visit, so the "Neu" badges stay while looking.
    @State private var newIDs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: design == .fahrkarte ? 16 : 12) {
                if let collection {
                    ForEach(collection.groups) { group in
                        NavigationLink {
                            CollectionCategoryView(group: group, newIDs: newIDs)
                        } label: {
                            CollectionGroupCard(group: group, newCount: group.items.count(where: { newIDs.contains($0.id) }))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Zählt deine gespeicherten Reisen und Träwelling-Check-ins. Züge zählen, wenn wir die Wagenreihung kennen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                } else {
                    ProgressView().padding(.top, 60)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
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

/// Minimal: a card with a tinted icon tile, the count and a progress bar. Fahrkarte: a small ticket with the
/// category in its stub and the count large below the perforation.
private struct CollectionGroupCard: View {
    let group: TravelCollection.Group
    let newCount: Int
    @Environment(\.appDesign) private var design

    var body: some View {
        Group {
            if design == .fahrkarte { ticket } else { card }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(systemImage: group.category.systemImage, color: .brandLegible, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.category.title).font(.headline)
                        Text("\(group.collected) von \(group.total) gesammelt")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if newCount > 0 { NewBadge(text: "\(newCount) neu") }
                    chevron
                }
                CollectionProgressBar(value: group.collected, total: group.total)
            }
        }
    }

    private var ticket: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: group.category.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(group.category.title)
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if newCount > 0 { NewBadge(text: "\(newCount) neu") }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            TicketPerforation(notchRadius: 7)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.collected.formatted())
                        .font(.largeTitle.weight(.bold))
                        .monospacedDigit()
                    Text("von \(group.total)")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    chevron
                }
                CollectionProgressBar(value: group.collected, total: group.total)
            }
            .padding(16)
        }
        .fontDesign(.rounded)
        .ticketBackground(notchRadius: 7, cornerRadius: 18)
        .environment(\.cardSurface, Color.ticket)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// A slim progress bar in the accent color on a faint track.
private struct CollectionProgressBar: View {
    let value: Int
    let total: Int

    var body: some View {
        ProgressView(value: Double(min(value, max(total, 1))), total: Double(max(total, 1)))
            .tint(.brandLegible)
            .accessibilityHidden(true)
    }
}

private struct NewBadge: View {
    var text: LocalizedStringKey = "Neu"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.onBrandLegible)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.brandLegible, in: .capsule)
    }
}

/// One category's items as a grid, the ones not collected yet greyed out; collected first.
struct CollectionCategoryView: View {
    let group: TravelCollection.Group
    let newIDs: Set<String>
    @State private var selected: TravelCollection.Item?
    @Environment(\.appDesign) private var design

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                progressHeader
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(sortedItems) { item in
                        Button { selected = item } label: {
                            CollectionTile(item: item, isNew: newIDs.contains(item.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .readableWidth()
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

    /// How much of the category is collected: Minimal in a card, Fahrkarte as a large count on the page.
    @ViewBuilder private var progressHeader: some View {
        if design == .fahrkarte {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.collected.formatted())
                        .font(.largeTitle.weight(.heavy))
                    Text("von \(group.total) gesammelt")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .fontDesign(.rounded)
                .accessibilityElement(children: .combine)
                CollectionProgressBar(value: group.collected, total: group.total)
            }
            .padding(.horizontal, 4)
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(group.collected) von \(group.total) gesammelt")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    CollectionProgressBar(value: group.collected, total: group.total)
                }
            }
        }
    }

    private var sortedItems: [TravelCollection.Item] {
        group.items.filter(\.isCollected) + group.items.filter { !$0.isCollected }
    }
}

/// Minimal: a card tile with a tinted icon tile. Fahrkarte: a flat tile with the symbol in a round stamp,
/// dashed while not collected.
private struct CollectionTile: View {
    let item: TravelCollection.Item
    let isNew: Bool
    @Environment(\.appDesign) private var design

    var body: some View {
        let isTicket = design == .fahrkarte
        VStack(spacing: 8) {
            if isTicket { stamp } else { iconTile }
            VStack(spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)
        }
        .fontDesign(isTicket ? .rounded : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(isTicket ? Color.ticket : Color.card, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: isTicket ? 1 : 0.5)
        }
        .shadow(color: .black.opacity(isTicket ? 0 : 0.04), radius: 6, y: 2)
        .opacity(item.isCollected ? 1 : 0.6)
        .overlay(alignment: .topTrailing) {
            if isNew { NewBadge().offset(x: 4, y: -4) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isCollected ? "Gesammelt" : "Noch nicht gesammelt")
    }

    private var iconTile: some View {
        Image(systemName: item.category.systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(item.isCollected ? Color.brandLegible : Color.secondary)
            .frame(width: 48, height: 48)
            .background((item.isCollected ? Color.brandLegible : Color.secondary).opacity(0.12),
                        in: .rect(cornerRadius: 13, style: .continuous))
    }

    private var stamp: some View {
        Image(systemName: item.category.systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(item.isCollected ? Color.brandLegible : Color.secondary)
            .frame(width: 48, height: 48)
            .overlay {
                Circle()
                    .strokeBorder(item.isCollected ? Color.brandLegible : Color.secondary.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: item.isCollected ? [] : [3, 4]))
            }
    }
}

/// When and on which rides an item was collected.
private struct CollectionItemSheet: View {
    let item: TravelCollection.Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        IconTile(systemImage: item.category.systemImage,
                                 color: item.isCollected ? .brandLegible : .secondary, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.title3.weight(design == .fahrkarte ? .bold : .semibold))
                                .fontDesign(design == .fahrkarte ? .rounded : nil)
                            if let subtitle = item.subtitle {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
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
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
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
