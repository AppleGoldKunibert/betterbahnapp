import BetterBahnKit
import SwiftUI

/// "Wagenreihung" row next to a train that unfolds the Wagenreihung in place: by itself from 30
/// minutes before the departure until 15 minutes after it (`CoachSequence.unfoldsByItself`), else
/// with a tap. Shown once bahn.de has a coach sequence for the train (the same request
/// `TrainFormationLabel` makes, so it is only sent once), or else vagonweb.cz has the planned one
/// ("Plan-Wagenreihung").
struct CoachSequenceDisclosure: View {
    /// bahn.de's request, only for departures within `BahnDeClient.formationLookahead`.
    let request: BahnDeClient.FormationRequest?
    /// The same for any later departure, for vagonweb's planned Wagenreihung days ahead.
    let plannedRequest: BahnDeClient.FormationRequest?
    /// Live departure at the request's station; the Wagenreihung unfolds around it.
    let departure: Date?
    /// Space above the row, only while it is shown (a stack's spacing would stay when it isn't).
    var spacing: CGFloat = 0

    init(leg: Leg, spacing: CGFloat = 0) {
        self.spacing = spacing
        request = BahnDeClient.formationRequest(for: leg)
        plannedRequest = BahnDeClient.formationRequest(for: leg, lookahead: nil)
        departure = leg.departure.best
    }

    init(trip: Trip, spacing: CGFloat = 0) {
        self.spacing = spacing
        let request = BahnDeClient.formationRequest(for: trip)
        let plannedRequest = BahnDeClient.formationRequest(for: trip, lookahead: nil)
        self.request = request
        self.plannedRequest = plannedRequest
        departure = Self.departure(of: trip, for: request ?? plannedRequest)
    }

    /// The live departure of `trip` at the request's stop.
    static func departure(of trip: Trip, for request: BahnDeClient.FormationRequest?) -> Date? {
        guard let request else { return nil }
        let stop = trip.stopovers.first { $0.station.id == request.station.id && $0.departure?.planned == request.plannedDeparture }
        return stop?.departure?.best ?? request.plannedDeparture
    }

    @Environment(AppModel.self) private var model
    @State private var sequence: CoachSequence?
    /// Opened or closed by hand; nil follows the departure time.
    @State private var expanded: Bool?

    var body: some View {
        // A ZStack rather than Group: `.task` never fires on a view that is empty.
        ZStack {
            if let sequence, !sequence.coaches.isEmpty, let shown = request ?? plannedRequest {
                TimelineView(.everyMinute) { context in
                    let open = expanded ?? CoachSequence.unfoldsByItself(departure: departure, now: context.date)
                    VStack(alignment: .leading, spacing: 12) {
                        CoachSequenceToggle(title: sequence.source == .bahnDe ? "Wagenreihung" : "Plan-Wagenreihung", open: open) {
                            withAnimation(.snappy) { expanded = !open }
                        }
                        if open {
                            CoachSequencePanel(request: shown, sequence: sequence)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, spacing)
                }
            }
        }
        .task(id: plannedRequest) {
            sequence = nil
            if let request, let live = try? await model.coachSequence(for: request), !live.coaches.isEmpty {
                sequence = live
            } else if let plannedRequest {
                sequence = await model.plannedCoachSequence(for: plannedRequest)
            }
        }
    }
}

/// "Wagenreihung ⌄", styled like a card's "Mehr".
struct CoachSequenceToggle: View {
    let title: String
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "train.side.front.car")
                Text(title)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Ausgeklappt" : "Eingeklappt")
    }
}

/// A train's coach sequence ("Wagenreihung") in place, inside a card: notes, a card per series with
/// its side view, then the platform from left to right with its sectors, the coaches to scale with
/// number, class and amenities, and the direction the train leaves in.
struct CoachSequencePanel: View {
    let request: BahnDeClient.FormationRequest
    @State private var sequence: CoachSequence?

    /// - Parameter sequence: already loaded by the caller; fetched here otherwise (e.g. from a stop's platform).
    init(request: BahnDeClient.FormationRequest, sequence: CoachSequence? = nil) {
        self.request = request
        _sequence = State(initialValue: sequence)
    }

    @Environment(AppModel.self) private var model
    @State private var loading = false
    @State private var blocked = false
    /// What bahn.de's sequence has differently from vagonweb's plan (`CoachSequence.deviations(fromPlan:)`).
    @State private var deviations: [String] = []
    /// Why bahn.de had no Wagenreihung when vagonweb's plan is shown instead (`BahnDeClient.coachSequenceNote(for:)`).
    @State private var bahnDeNote: String?

    private var station: Station { request.station }

    var body: some View {
        Group {
            if let sequence {
                VStack(alignment: .leading, spacing: 12) {
                    notes(sequence)
                    ForEach(Array(sequence.formation.partsBySeries.enumerated()), id: \.offset) { _, part in
                        TrainCard(formation: part)
                    }
                    CoachSequenceDiagram(sequence: sequence)
                    legend(sequence)
                }
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Label(blocked ? "bahn.de ist gerade nicht erreichbar." : "Für diesen Halt gibt es (noch) keine Wagenreihung.",
                      systemImage: "train.side.front.car")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: request) {
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
            if sequence?.source != .bahnDe {
                bahnDeNote = await model.provider.bahnDe?.coachSequenceNote(for: request)
            }
            // bahn.de flags nearly every train as differing, so compare with the plan here.
            if let sequence, sequence.source == .bahnDe, !sequence.coaches.isEmpty,
               let plan = await model.plannedCoachSequence(for: request, direction: false) {
                deviations = sequence.deviations(fromPlan: plan)
            }
        }
    }

    private func notes(_ sequence: CoachSequence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([station.displayName, sequence.platform.map { "Gleis \($0)" }].compactMap(\.self).joined(separator: " · "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if case .vagonweb(let from, let until) = sequence.source {
                plannedNote(sequence, from: from, until: until)
            }
            if let bahnDeNote {
                Text("bahn.de: \(bahnDeNote)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
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
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                ForEach(amenities, id: \.self) { amenity in
                    Label(amenity.title, systemImage: amenity.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One series of the train: "ICE 1 BR 401" with each Tz and its Taufname below and the series' side
/// view running off the box's trailing edge, like on vagonweb (#167). Coupled trainsets of one series
/// share a box ("2× ICE 4"). Drawings: DB Fahrzeuglexikon, © Deutsche Bahn AG.
private struct TrainCard: View {
    let formation: TrainFormation

    private static let drawingHeight: CGFloat = 54

    var body: some View {
        let drawing = formation.drawing
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
                ForEach(Array(formation.units.enumerated()), id: \.offset) { _, unit in
                    if let number = unit.number {
                        Text("Tz \(number)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let name = unit.name {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 14)
            .padding(.leading, 16)
            .padding(.trailing, drawing == nil ? 16 : 0)
            .layoutPriority(1)
            if let drawing {
                VStack(alignment: .trailing, spacing: 2) {
                    // As wide as the box leaves, cut off at its edge.
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
        .insetPanel()
        .accessibilityElement(children: .combine)
    }
}

/// The platform from its start (left) to its end, everything placed by its position in meters. Scrolls
/// sideways and opens at the front of the train; each part's label (train, Tz, Taufname) stays in view
/// while scrolling until the part ends at the coupling point.
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

    /// Train and destination, Tz and Taufname of one part, above its coaches.
    private struct PartLabel: Identifiable {
        var id: Int
        var train: String?
        var unit: String?
        var name: String?
        var start: Double
        var end: Double
    }

    /// Widest a part's label gets; long Taufnamen wrap onto a second line.
    private static let labelWidth: CGFloat = 150

    /// How far the diagram is scrolled: the content's x at the visible leading edge.
    @State private var scrolled: CGFloat = 0

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
                                let start = x(label.start) + 1.5
                                let end = x(label.end) - 1.5
                                let labelWidth = max(min(Self.labelWidth, end - start), 0)
                                // Held at the visible edge while its part is in view, never past the coupling point.
                                partLabel(label)
                                    .frame(width: labelWidth, alignment: .leading)
                                    .offset(x: min(max(start, scrolled), end - labelWidth))
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
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x + geometry.contentInsets.leading
            } action: { _, offset in
                scrolled = offset
            }
            .defaultScrollAnchor(sequence.travelsTowardsPlatformEnd == true ? .trailing : .leading)
            if let towardsEnd = sequence.travelsTowardsPlatformEnd {
                directionLabel(towardsEnd: towardsEnd)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 12)
        .insetPanel()
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

    private func partLabel(_ label: PartLabel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let train = label.train {
                Text(train)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.brand)
                    .lineLimit(2)
            }
            if let unit = label.unit {
                Text(unit)
                    .font(.caption2.weight(.bold))
            }
            if let name = label.name {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// Each part's label, spanning its coaches.
    private func partLabels(_ placed: [Placed]) -> [PartLabel] {
        placed.compactMap { item in
            guard var label = partLabel(for: item.coach) else { return nil }
            let part = placed.filter { $0.coach.group == item.coach.group }
            label.start = part.map(\.start).min() ?? item.start
            label.end = part.map(\.end).max() ?? item.end
            return label
        }
    }

    /// Tz and Taufname on the first coach of each part (also of a single trainset), with the part's
    /// train and destination whenever several trains run together.
    private func partLabel(for coach: CoachSequence.Coach) -> PartLabel? {
        guard sequence.groups.indices.contains(coach.group), !sequence.isLocomotiveOnly(group: coach.group),
              sequence.coaches.first(where: { $0.group == coach.group })?.id == coach.id else { return nil }
        let group = sequence.groups[coach.group]
        var train: String?
        // Each part's own number and destination whenever several trains run together (coupled ones too).
        if sequence.travellingGroups.count > 1, sequence.hasSeveralTrains || sequence.hasOtherTrains {
            train = [group.trainName, group.destination].compactMap(\.self).joined(separator: " → ")
            if train?.isEmpty == true { train = nil }
        }
        let unit = group.unit?.number.map { "Tz \($0)" }
        guard train != nil || unit != nil else { return nil }
        return PartLabel(id: coach.group, train: train, unit: unit, name: unit == nil ? nil : group.unit?.name, start: 0, end: 0)
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

private extension View {
    /// The Wagenreihung's boxes inside a card: a faint fill instead of a card of their own.
    func insetPanel() -> some View {
        background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 16, style: .continuous))
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }
}
