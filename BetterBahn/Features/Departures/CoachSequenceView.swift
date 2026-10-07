import BetterBahnKit
import SwiftUI

/// A train's coach sequence ("Wagenreihung") drawn along the platform: sectors on the left, coaches
/// to scale with number, class and amenities, and the direction the train leaves in.
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
            if let drawing = sequence.formation.drawing {
                TrainDrawingRow(formation: sequence.formation, drawing: drawing)
            } else if let units = sequence.formation.unitDescription ?? sequence.formation.modelSummary {
                Label(units, systemImage: "tram.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// "ICE 1 BR 401" with the Tz below and the series' side view next to it, cut off at the edge like
/// on vagonweb (#167). Drawings: DB Fahrzeuglexikon, © Deutsche Bahn AG.
private struct TrainDrawingRow: View {
    let formation: TrainFormation
    let drawing: TrainDrawing

    private static let height: CGFloat = 46

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let model = formation.modelSummary {
                    HStack(spacing: 4) {
                        Text(model).bold()
                        if let series = drawing.series {
                            Text(series).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                if let units = formation.unitDescription {
                    Text(units)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            // As wide as its height allows, cut off at the trailing edge.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
                .overlay(alignment: .leading) {
                    Image(drawing.assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: Self.height)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .clipped()
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The platform drawn top to bottom, everything placed by its position in meters.
private struct CoachSequenceDiagram: View {
    let sequence: CoachSequence

    private static let pointsPerMeter: CGFloat = 2.6
    /// Coach length used when bahn.de gave no positions.
    private static let fallbackCoachLength = 26.4

    private struct Placed: Identifiable {
        var coach: CoachSequence.Coach
        var start: Double
        var end: Double
        var id: Int { coach.id }
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
        let placed = placed
        let sectors = hasPositions ? sequence.sectors : []
        // Only the stretch of the platform where the train stands, plus a little margin.
        let top = max(0, (placed.map(\.start).min() ?? 0) - 10)
        let bottom = max(placed.map(\.end).max() ?? 0, sequence.platformLength.map { min($0, (placed.map(\.end).max() ?? 0) + 10) } ?? 0)
        let scale = Self.pointsPerMeter
        let y = { (meters: Double) in CGFloat(meters - top) * scale }

        VStack(spacing: 8) {
            if sequence.travelsTowardsPlatformEnd == false { directionLabel(up: true) }
            HStack(alignment: .top, spacing: 10) {
                // Sectors
                ZStack(alignment: .top) {
                    ForEach(sectors.filter { $0.end > top && $0.start < bottom }, id: \.name) { sector in
                        let start = max(sector.start, top)
                        let end = min(sector.end, bottom)
                        Text(sector.name)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: y(end) - y(start))
                            .overlay(alignment: .top) {
                                Rectangle().fill(.secondary.opacity(0.4)).frame(height: 1)
                            }
                            .offset(y: y(start))
                    }
                }
                .frame(width: 32, height: y(bottom), alignment: .top)

                ZStack(alignment: .topLeading) {
                    ForEach(placed) { item in
                        CoachRow(coach: item.coach, group: groupLabel(for: item.coach))
                            .frame(height: max(y(item.end) - y(item.start) - 3, 24), alignment: .top)
                            .offset(y: y(item.start))
                    }
                    // A dashed line where one part of the train ends and the next begins.
                    ForEach(partBoundaries(placed), id: \.self) { meters in
                        DividerLine()
                            .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(height: 1.5)
                            .offset(y: y(meters) - 2.25)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: y(bottom), maxHeight: y(bottom), alignment: .topLeading)
            }
            if sequence.travelsTowardsPlatformEnd == true { directionLabel(up: false) }
        }
    }

    /// Where one part of the train meets the next, in meters along the platform.
    private func partBoundaries(_ placed: [Placed]) -> [Double] {
        guard sequence.groups.count > 1 else { return [] }
        // A locomotive in a group of its own (changed on the way) is no separate part of the train.
        let ordered = placed.sorted { $0.start < $1.start }.filter { !sequence.isLocomotiveOnly(group: $0.coach.group) }
        return zip(ordered, ordered.dropFirst()).compactMap { previous, next in
            previous.coach.group == next.coach.group ? nil : (previous.end + next.start) / 2
        }
    }

    private func directionLabel(up: Bool) -> some View {
        Label("Fahrtrichtung", systemImage: up ? "arrow.up" : "arrow.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
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

nonisolated private struct DividerLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

private struct CoachRow: View {
    let coach: CoachSequence.Coach
    let group: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            shape
            VStack(alignment: .leading, spacing: 3) {
                if let group {
                    Text(group)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.brand)
                        .lineLimit(2)
                }
                Text(coach.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(coach.closed ? .secondary : .primary)
                if coach.closed {
                    Label("Geschlossen", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !coach.amenities.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(coach.amenities, id: \.self) { amenity in
                            Image(systemName: amenity.symbolName)
                                .accessibilityLabel(amenity.title)
                        }
                        if let bikes = coach.bikeSpaces {
                            Text("\(bikes)").monospacedDigit()
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var shape: some View {
        let fill: Color = switch coach.kind {
        case .locomotive, .powerCar: .gray
        case .diningCar, .halfDiningCar: .brand
        default: coach.firstClass ? .yellow : .secondary
        }
        return RoundedRectangle(cornerRadius: coach.isPassengerCoach ? 6 : 14, style: .continuous)
            .fill(fill.opacity(coach.isPassengerCoach ? 0.22 : 0.45))
            .overlay {
                RoundedRectangle(cornerRadius: coach.isPassengerCoach ? 6 : 14, style: .continuous)
                    .strokeBorder(fill.opacity(0.6), lineWidth: 1)
            }
            .overlay {
                if let number = coach.number {
                    Text(number)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(coach.closed ? .secondary : .primary)
                }
            }
            .frame(width: 56)
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
