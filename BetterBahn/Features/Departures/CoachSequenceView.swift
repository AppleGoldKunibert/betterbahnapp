import BetterBahnKit
import SwiftUI

/// A train's coach sequence ("Wagenreihung"): a card per series with its side view, then the platform
/// from left to right with its sectors, the coaches to scale with number, class and amenities, and the
/// direction the train leaves in.
struct CoachSequenceView: View {
    let request: BahnDeClient.FormationRequest
    let trainName: String?
    @State private var sequence: CoachSequence?

    /// - Parameter sequence: already loaded by the caller; fetched here otherwise (e.g. from a stop's platform).
    init(request: BahnDeClient.FormationRequest, trainName: String?, sequence: CoachSequence? = nil) {
        self.request = request
        self.trainName = trainName
        _sequence = State(initialValue: sequence)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var loading = false
    @State private var blocked = false
    /// What bahn.de's sequence has differently from vagonweb's plan (`CoachSequence.deviations(fromPlan:)`).
    @State private var deviations: [String] = []

    private var station: Station { request.station }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let sequence {
                    VStack(alignment: .leading, spacing: 16) {
                        header(sequence)
                        ForEach(Array(sequence.formation.partsBySeries.enumerated()), id: \.offset) { _, part in
                            TrainCard(formation: part)
                        }
                        CoachSequenceDiagram(sequence: sequence)
                        legend(sequence)
                    }
                    .padding()
                } else if loading {
                    ProgressView().padding(.top, 60)
                } else {
                    ContentUnavailableView(
                        "Keine Wagenreihung",
                        systemImage: "train.side.front.car",
                        description: Text(blocked ? "bahn.de ist gerade nicht erreichbar."
                                                  : "Für diesen Halt gibt es (noch) keine Wagenreihung.")
                    )
                    .padding(.top, 40)
                }
            }
            .background(AppBackground())
            .navigationTitle("Wagenreihung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .task {
            if sequence == nil {
                loading = true
                do {
                    sequence = try await model.coachSequence(for: request)
                } catch TransitError.rateLimited {
                    blocked = true
                } catch {}
                if sequence?.coaches.isEmpty ?? true, let planned = await model.plannedCoachSequence(for: request) {
                    sequence = planned
                    blocked = false
                }
                loading = false
            }
            // bahn.de flags nearly every train as differing, so compare with the plan here.
            if let sequence, sequence.source == .bahnDe, !sequence.coaches.isEmpty,
               let plan = await model.plannedCoachSequence(for: request, direction: false) {
                deviations = sequence.deviations(fromPlan: plan)
            }
        }
    }

    /// Where the train goes; coupled trains that split later list every destination.
    private func destination(_ sequence: CoachSequence) -> String? {
        var destinations: [String] = []
        for case let destination? in sequence.travellingGroups.filter(\.isRequestedTrain).map(\.destination)
        where !destinations.contains(destination) {
            destinations.append(destination)
        }
        return destinations.isEmpty ? nil : destinations.joined(separator: " / ")
    }

    private func header(_ sequence: CoachSequence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let trainName {
                Text([trainName, destination(sequence)].compactMap(\.self).joined(separator: " → "))
                    .font(.headline)
            }
            Text([station.displayName, sequence.platform.map { "Gleis \($0)" }].compactMap(\.self).joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if case .vagonweb(let from, let until) = sequence.source {
                plannedNote(sequence, from: from, until: until)
            }
            if !deviations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    InfoChip(text: "Abweichende Wagenreihung", systemImage: "exclamationmark.triangle.fill", tint: .slightDelay)
                    Text(deviations.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if sequence.hasOtherTrains || sequence.partsGoToDifferentPlaces {
                InfoChip(text: "Zugteile mit anderem Ziel – auf den Wagen achten", systemImage: "arrow.triangle.branch", tint: .slightDelay)
            }
        }
    }

    /// vagonweb's plan is for the whole train, not this stop: no platform positions, and the real
    /// train can differ (bahn.de has the actual one in the hours before departure). Turned round when
    /// the train changed direction on the way; without its stops the direction is unknown.
    private func plannedNote(_ sequence: CoachSequence, from: Date?, until: Date?) -> some View {
        let validity: String? = switch (from, until) {
        case let (from?, until?): "gilt \(from.formatted(.dateTime.day().month(.twoDigits).year())) – \(until.formatted(.dateTime.day().month(.twoDigits).year()))"
        default: nil
        }
        return VStack(alignment: .leading, spacing: 4) {
            InfoChip(text: "Plan-Wagenreihung – kann abweichen", systemImage: "calendar", tint: .secondary)
            Text(["Ohne Gleisabschnitte", validity, "Daten: vagonweb.cz"].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if sequence.travelsTowardsPlatformEnd == nil {
                Text("Fahrtrichtung unbekannt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !sequence.reversals.isEmpty {
                Text("Fahrtrichtungswechsel in \(ListFormatter.localizedString(byJoining: sequence.reversals))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func legend(_ sequence: CoachSequence) -> some View {
        let amenities = CoachSequence.Coach.Amenity.allCases.filter { amenity in
            sequence.coaches.contains { $0.amenities.contains(amenity) }
        }
        if !amenities.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(amenities, id: \.self) { amenity in
                        Label(amenity.title, systemImage: amenity.symbolName)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One series of the train: "ICE 1 BR 401" with the Tz below and the series' side view running off
/// the card's trailing edge, like on vagonweb (#167). Coupled trainsets of one series share a card
/// ("2× ICE 4"). Drawings: DB Fahrzeuglexikon, © Deutsche Bahn AG.
private struct TrainCard: View {
    let formation: TrainFormation

    private static let drawingHeight: CGFloat = 54

    var body: some View {
        let drawing = formation.drawing
        Card(padding: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let model = formation.modelSummary {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(model)
                                .font(.headline)
                            if let series = drawing?.series {
                                Text(series)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let units = formation.unitDescription {
                        Text(units)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14)
                .padding(.leading, 16)
                .padding(.trailing, drawing == nil ? 16 : 0)
                .layoutPriority(1)
                if let drawing {
                    VStack(alignment: .trailing, spacing: 2) {
                        // As wide as the card leaves, cut off at its edge.
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: Self.drawingHeight, maxHeight: Self.drawingHeight)
                            .overlay(alignment: .leading) {
                                Image(drawing.assetName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: Self.drawingHeight)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .clipped()
                            .accessibilityHidden(true)
                        Text("Quelle: Deutsche Bahn")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 16)
                    }
                    .frame(minWidth: 90)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The platform from its start (left) to its end, everything placed by its position in meters. Scrolls
/// sideways and opens at the front of the train.
private struct CoachSequenceDiagram: View {
    let sequence: CoachSequence

    private static let pointsPerMeter: CGFloat = 3
    /// Coach length used when bahn.de gave no positions.
    private static let fallbackCoachLength = 26.4

    private struct Placed: Identifiable {
        var coach: CoachSequence.Coach
        var start: Double
        var end: Double
        var id: Int { coach.id }
    }

    /// Train and destination (or Tz) of one part, above its coaches.
    private struct PartLabel: Identifiable {
        var id: Int
        var text: String
        var start: Double
        var end: Double
    }

    private var hasPositions: Bool { sequence.coaches.allSatisfy { $0.start != nil && $0.end != nil } }

    /// Coaches with their positions, or one after the other from the front when any is missing.
    private var placed: [Placed] {
        sequence.coaches.enumerated().map { index, coach in
            if hasPositions, let start = coach.start, let end = coach.end {
                Placed(coach: coach, start: min(start, end), end: max(start, end))
            } else {
                Placed(coach: coach, start: Double(index) * Self.fallbackCoachLength, end: Double(index + 1) * Self.fallbackCoachLength)
            }
        }
    }

    var body: some View {
        let placed = placed.sorted { $0.start < $1.start }
        let sectors = hasPositions ? sequence.sectors : []
        // Only the stretch of the platform where the train stands, plus a little margin.
        let left = max(0, (placed.map(\.start).min() ?? 0) - 10)
        let right = max(placed.map(\.end).max() ?? 0, sequence.platformLength.map { min($0, (placed.map(\.end).max() ?? 0) + 10) } ?? 0)
        let x = { (meters: Double) in CGFloat(meters - left) * Self.pointsPerMeter }
        let width = x(right)
        let labels = partLabels(placed)
        // Trainsets have a nose at both ends of each part; so do locomotives and power cars.
        let hasTrainsets = !sequence.formation.units.isEmpty

        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !sectors.isEmpty {
                            ZStack(alignment: .leading) {
                                ForEach(sectors.filter { $0.end > left && $0.start < right }, id: \.name) { sector in
                                    let start = max(sector.start, left)
                                    let end = min(sector.end, right)
                                    Text(sector.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: max(x(end) - x(start) - 2, 0), height: 26)
                                        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 6, style: .continuous))
                                        .offset(x: x(start) + 1)
                                }
                            }
                            .frame(width: width, alignment: .leading)
                            .accessibilityHidden(true)
                        }
                        if !labels.isEmpty {
                            ZStack(alignment: .topLeading) {
                                ForEach(labels) { label in
                                    Text(label.text)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color.brand)
                                        .lineLimit(2)
                                        .frame(width: max(x(label.end) - x(label.start), 0), alignment: .leading)
                                        .offset(x: x(label.start) + 1.5)
                                }
                            }
                            .frame(width: width, alignment: .topLeading)
                        }
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(placed.enumerated()), id: \.element.id) { index, item in
                                let group = item.coach.group
                                let nose = hasTrainsets || !item.coach.isPassengerCoach
                                CoachTile(coach: item.coach,
                                          leadingNose: nose && (index == 0 || placed[index - 1].coach.group != group),
                                          trailingNose: nose && (index == placed.count - 1 || placed[index + 1].coach.group != group))
                                    .frame(width: max(x(item.end) - x(item.start) - 3, 36))
                                    .offset(x: x(item.start) + 1.5)
                            }
                            // A dashed line where one part of the train ends and the next begins.
                            ForEach(partBoundaries(placed), id: \.self) { meters in
                                DividerLine()
                                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    .frame(width: 1.5, height: CoachTile.height + 8)
                                    .offset(x: x(meters) - 0.75, y: -4)
                            }
                        }
                        .frame(width: width, alignment: .topLeading)
                    }
                    .padding(.vertical, 4)
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .defaultScrollAnchor(sequence.travelsTowardsPlatformEnd == true ? .trailing : .leading)
                if let towardsEnd = sequence.travelsTowardsPlatformEnd {
                    directionLabel(towardsEnd: towardsEnd)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 14)
        }
    }

    /// Where one part of the train meets the next, in meters along the platform.
    private func partBoundaries(_ placed: [Placed]) -> [Double] {
        guard sequence.groups.count > 1 else { return [] }
        // A locomotive in a group of its own (changed on the way) is no separate part of the train.
        let ordered = placed.filter { !sequence.isLocomotiveOnly(group: $0.coach.group) }
        return zip(ordered, ordered.dropFirst()).compactMap { previous, next in
            previous.coach.group == next.coach.group ? nil : (previous.end + next.start) / 2
        }
    }

    /// "← Richtung" at the left or "Richtung →" at the right: where the train leaves to.
    private func directionLabel(towardsEnd: Bool) -> some View {
        HStack(spacing: 4) {
            if !towardsEnd { Image(systemName: "arrow.left") }
            Text("Richtung")
            if towardsEnd { Image(systemName: "arrow.right") }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: towardsEnd ? .trailing : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(towardsEnd ? "Fahrtrichtung nach rechts" : "Fahrtrichtung nach links")
    }

    /// Each part's label, spanning its coaches.
    private func partLabels(_ placed: [Placed]) -> [PartLabel] {
        placed.compactMap { item in
            guard let text = groupLabel(for: item.coach) else { return nil }
            let part = placed.filter { $0.coach.group == item.coach.group }
            return PartLabel(id: item.coach.group, text: text,
                             start: part.map(\.start).min() ?? item.start, end: part.map(\.end).max() ?? item.end)
        }
    }

    /// Train and destination (or Tz) on the first coach of each part, when the train has several.
    private func groupLabel(for coach: CoachSequence.Coach) -> String? {
        guard sequence.travellingGroups.count > 1, sequence.groups.indices.contains(coach.group),
              !sequence.isLocomotiveOnly(group: coach.group),
              sequence.coaches.first(where: { $0.group == coach.group })?.id == coach.id else { return nil }
        let group = sequence.groups[coach.group]
        let unit = group.unit?.number.map { "Tz \($0)" }
        // Each part's own number and destination whenever several trains run together (coupled ones too).
        if sequence.hasSeveralTrains || sequence.hasOtherTrains {
            let train = [group.trainName, group.destination].compactMap(\.self).joined(separator: " → ")
            return [train.isEmpty ? nil : train, unit].compactMap(\.self).joined(separator: " · ")
        }
        return unit
    }
}

/// A vertical line through the middle of its frame.
nonisolated private struct DividerLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

/// One coach seen from the side: its number in the box, class and amenities below. The ends of a
/// trainset are rounded like a nose.
private struct CoachTile: View {
    let coach: CoachSequence.Coach
    var leadingNose = false
    var trailingNose = false

    static let height: CGFloat = 46
    private static let amenitiesPerRow = 3

    var body: some View {
        VStack(spacing: 4) {
            shape
            VStack(spacing: 1) {
                ForEach(captionLines, id: \.self) { line in
                    Text(line)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(coach.closed ? .tertiary : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if coach.closed {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            amenities
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "Bistro", "1. Klasse" …
    private var captionLines: [String] {
        let kind: String? = switch coach.kind {
        case .locomotive: "Lok"
        case .powerCar: "Triebkopf"
        case .diningCar: "Restaurant"
        case .halfDiningCar: "Bistro"
        case .sleeper: "Schlafwagen"
        case .couchette: "Liegewagen"
        case .passenger, .other: nil
        }
        let classes: String? = switch (coach.firstClass, coach.secondClass) {
        case (true, true): "1./2. Kl."
        case (true, false): "1. Klasse"
        case (false, true): "2. Klasse"
        case (false, false): nil
        }
        return [kind, classes].compactMap(\.self)
    }

    @ViewBuilder
    private var amenities: some View {
        let items = coach.amenities
        if !items.isEmpty {
            VStack(spacing: 3) {
                ForEach(Array(stride(from: 0, to: items.count, by: Self.amenitiesPerRow)), id: \.self) { first in
                    HStack(spacing: 5) {
                        ForEach(items[first..<min(first + Self.amenitiesPerRow, items.count)], id: \.self) { amenity in
                            if amenity == .bikeSpace, let bikes = coach.bikeSpaces {
                                HStack(spacing: 1) {
                                    Image(systemName: amenity.symbolName)
                                    Text("\(bikes)").monospacedDigit()
                                }
                            } else {
                                Image(systemName: amenity.symbolName)
                            }
                        }
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        var parts = [coach.number.map { "Wagen \($0)" }, coach.title == "Wagen" ? nil : coach.title, coach.closed ? "Geschlossen" : nil].compactMap(\.self)
        parts += coach.amenities.map(\.title)
        if let bikes = coach.bikeSpaces, coach.amenities.contains(.bikeSpace) { parts.append("\(bikes) Fahrradstellplätze") }
        return parts.joined(separator: ", ")
    }

    private var shape: some View {
        let fill: Color = switch coach.kind {
        case .locomotive, .powerCar: .gray
        case .diningCar, .halfDiningCar: .brand
        default: coach.firstClass ? .yellow : .secondary
        }
        let corner: CGFloat = coach.isPassengerCoach ? 6 : 10
        let nose: CGFloat = 20
        let outline = UnevenRoundedRectangle(topLeadingRadius: leadingNose ? nose : corner,
                                             bottomLeadingRadius: leadingNose ? nose : corner,
                                             bottomTrailingRadius: trailingNose ? nose : corner,
                                             topTrailingRadius: trailingNose ? nose : corner,
                                             style: .continuous)
        return outline
            .fill(fill.opacity(coach.isPassengerCoach ? 0.22 : 0.45))
            .overlay {
                outline.strokeBorder(fill.opacity(0.6), lineWidth: 1)
            }
            .overlay {
                if let number = coach.number {
                    Text(number)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(coach.closed ? .secondary : .primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
            .frame(height: Self.height)
            .opacity(coach.closed ? 0.5 : 1)
    }
}

extension CoachSequence.Coach {
    /// "Wagen 21 · 2. Klasse", "Bordrestaurant · 1. Klasse", "Triebkopf" …
    var title: String {
        let classes = switch (firstClass, secondClass) {
        case (true, true): "1./2. Klasse"
        case (true, false): "1. Klasse"
        case (false, true): "2. Klasse"
        case (false, false): nil as String?
        }
        let kind: String? = switch kind {
        case .locomotive: "Lok"
        case .powerCar: "Triebkopf"
        case .diningCar: "Bordrestaurant"
        case .halfDiningCar: "Bordbistro"
        case .sleeper: "Schlafwagen"
        case .couchette: "Liegewagen"
        case .passenger, .other: nil
        }
        return [kind, classes].compactMap(\.self).joined(separator: " · ").nilIfEmpty ?? "Wagen"
    }
}

extension CoachSequence.Coach.Amenity {
    var title: String {
        switch self {
        case .bikeSpace: "Fahrradstellplätze"
        case .wheelchairSpace: "Rollstuhlstellplätze"
        case .wheelchairToilet: "Rollstuhlgerechtes WC"
        case .severelyDisabledSeats: "Plätze für Schwerbehinderte"
        case .quietZone: "Ruhebereich"
        case .familyZone: "Familienbereich"
        case .infantCabin: "Kleinkindabteil"
        case .bahnComfortSeats: "BahnComfort-Plätze"
        case .info: "Info-Punkt"
        }
    }

    var symbolName: String {
        switch self {
        case .bikeSpace: "bicycle"
        case .wheelchairSpace: "figure.roll"
        case .wheelchairToilet: "toilet.fill"
        case .severelyDisabledSeats: "accessibility"
        case .quietZone: "speaker.slash.fill"
        case .familyZone: "figure.2.and.child.holdinghands"
        case .infantCabin: "stroller.fill"
        case .bahnComfortSeats: "star.fill"
        case .info: "info.circle.fill"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
