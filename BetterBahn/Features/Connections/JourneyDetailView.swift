import BetterBahnKit
import SwiftUI

struct JourneyDetailView: View {
    @State var journey: Journey
    let finalDestination: Station
    /// Old plans are shown without actions.
    var readOnly = false
    var title = "Reiseplan"

    @Environment(AppModel.self) private var model
    @State private var legToReplace: LegSelection?
    @State private var checkinLeg: Leg?
    @State private var showAlternatives = false

    struct LegSelection: Identifiable {
        let index: Int
        let leg: Leg
        var id: String { leg.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                if !readOnly { issuesCard }
                ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                    if !leg.isWalking {
                        LegCard(
                            leg: leg,
                            transferBroken: journey.brokenTransferIndices.contains(journey.transitLegs.firstIndex(of: leg) ?? -1),
                            onReplace: readOnly ? nil : { legToReplace = LegSelection(index: index, leg: leg) },
                            onCheckin: readOnly ? nil : { checkinLeg = leg }
                        )
                        if let info = transferInfo(after: leg) {
                            TransferRow(from: leg, to: info.next, walk: info.walk)
                        }
                    }
                }
                if !readOnly { historySection }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .refreshable { await refreshRealtime() }
        .tabBarSafePadding()
        .background { AppBackground() }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $legToReplace) { selection in
            AlternativeTrainsSheet(leg: selection.leg) { newLeg in
                let updated = try await model.trainPicker.replacing(
                    legAt: selection.index, in: journey, with: newLeg, finalDestination: finalDestination)
                withAnimation {
                    if let entry = model.savedEntry(for: journey) {
                        model.replaceSaved(id: entry.id, with: updated, reason: "Anderer Zug gewählt")
                    }
                    journey = updated
                }
            }
        }
        .sheet(item: $checkinLeg) { CheckinSheet(leg: $0) }
        .sheet(isPresented: $showAlternatives) {
            if let entry = model.savedEntry(for: journey) {
                AlternativeJourneySheet(entry: entry) { newJourney in
                    withAnimation { journey = newJourney }
                }
            }
        }
        .onChange(of: model.savedEntry(for: journey)?.journey) { _, refreshed in
            // Pick up realtime refreshes of this saved journey.
            if let refreshed, refreshed != journey { journey = refreshed }
        }
    }

    /// Pull-to-refresh: re-fetches realtime data (delays, platforms, cancellations) for every leg.
    private func refreshRealtime() async {
        guard !readOnly else { return }
        let refreshed = await model.journeyRefresher.refresh(journey)
        guard refreshed != journey else { return }
        if let entry = model.savedEntry(for: journey) {
            model.updateSavedJourneyData(id: entry.id, journey: refreshed)
        }
        withAnimation { journey = refreshed }
    }

    /// The next transit leg after `leg`, plus the walking leg between them, if any.
    private func transferInfo(after leg: Leg) -> (next: Leg, walk: Leg?)? {
        guard let index = journey.legs.firstIndex(of: leg) else { return nil }
        let rest = journey.legs[(index + 1)...]
        guard let next = rest.first(where: { !$0.isWalking }) else { return nil }
        return (next, rest.prefix(while: \.isWalking).first)
    }

    @ViewBuilder
    private var issuesCard: some View {
        let issues = journey.connectionIssues()
        if !issues.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 12) {
                            IconTile(systemImage: issue.isBlocking ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark.fill",
                                     color: issue.isBlocking ? .heavyDelay : .slightDelay, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.title).font(.headline)
                                Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if issues.contains(where: \.isBlocking) {
                        Button {
                            if !model.isSaved(journey) { model.save(journey) }
                            showAlternatives = true
                        } label: {
                            Label("Alternative suchen", systemImage: "arrow.triangle.branch")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.brand)
                        .controlSize(.large)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let versions = model.savedEntry(for: journey)?.previousVersions, !versions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Frühere Reisepläne", systemImage: "clock.arrow.circlepath")
                ForEach(versions) { version in
                    NavigationLink {
                        JourneyDetailView(journey: version.journey, finalDestination: finalDestination, readOnly: true,
                                          title: "Früherer Reiseplan")
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Ersetzt \(version.replacedAt.formatted(date: .abbreviated, time: .shortened)) · \(version.reason)",
                                  systemImage: "arrow.uturn.backward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.horizontal, 6)
                            JourneyCard(journey: version.journey).opacity(0.75)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    if let departure = journey.departure, let first = journey.legs.first {
                        VStack(alignment: .leading, spacing: 4) {
                            TimeStack(time: departure, font: .largeTitle.weight(.bold))
                            Text(first.origin.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 12)
                    if let arrival = journey.arrival, let last = journey.legs.last {
                        VStack(alignment: .trailing, spacing: 4) {
                            TimeStack(time: arrival, alignment: .trailing, font: .largeTitle.weight(.bold))
                            Text(last.destination.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                JourneySegmentBar(journey: journey)

                HStack(spacing: 8) {
                    if let duration = journey.duration {
                        InfoChip(text: duration.durationString, systemImage: "clock.fill")
                    }
                    InfoChip(text: journey.transfers == 0 ? "Direkt" : "\(journey.transfers) Umstieg\(journey.transfers == 1 ? "" : "e")",
                             systemImage: "arrow.triangle.swap")
                    if model.bc100Rules.isValid(journey) {
                        InfoChip(text: "BC100", systemImage: "creditcard.fill", tint: .punctual)
                    }
                }

                if !readOnly {
                    liveActivityButton
                } else {
                    Label("Früherer Plan – nicht mehr aktiv", systemImage: "archivebox.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var liveActivityButton: some View {
        VStack(spacing: 8) {
            SaveJourneyButton(journey: journey)
            if model.isSaved(journey) {
                Label(model.liveActivities.isActive(journey)
                      ? "Wird als Live Activity angezeigt"
                      : "Erscheint als Live Activity ab 30 Minuten vor der Abfahrt",
                      systemImage: "bolt.badge.clock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let entry = model.savedEntry(for: journey), model.isLiveActivityEligible(journey) {
                    Toggle(isOn: Binding(
                        get: { model.manualLiveActivityJourneyID == entry.id || model.liveActivities.isActive(journey) },
                        set: { model.manualLiveActivityJourneyID = $0 ? entry.id : nil }
                    )) {
                        Label("Diese Reise als Live Activity zeigen", systemImage: "arrow.left.arrow.right.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .tint(.brand)
                }
            }
        }
    }
}

/// Shows the transfer between two transit legs: how much time there is (color-coded by comfort),
/// the platform change, and the walking time if the connection requires walking.
struct TransferRow: View {
    let from: Leg
    let to: Leg
    var walk: Leg?

    private var minutes: Int {
        Int((to.departure.best.timeIntervalSince(from.arrival.best) / 60).rounded())
    }
    private var broken: Bool { minutes < 0 }
    private var color: Color { transferColor(minutes) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: walk != nil ? "figure.walk" : "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(broken ? "Umstieg nicht erreichbar" : "Umstieg · \(minutes) min")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                if let walk {
                    Text("\(Int((walk.arrival.best.timeIntervalSince(walk.departure.best) / 60).rounded())) min Fußweg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if from.arrivalPlatform?.best != nil || to.departurePlatform?.best != nil {
                HStack(spacing: 6) {
                    PlatformBadge(platform: from.arrivalPlatform)
                    Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    PlatformBadge(platform: to.departurePlatform)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }
}

struct LegCard: View {
    let leg: Leg
    var transferBroken = false
    var onReplace: (() -> Void)?
    var onCheckin: (() -> Void)?

    @State private var showStops = false
    @State private var showDetails = false
    @State private var showFullTrip = false

    private var color: Color { leg.line?.product.color ?? .gray }
    private var intermediate: [Stopover] { Array(leg.stopovers.dropFirst().dropLast()) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    showFullTrip = true
                } label: {
                    HStack(spacing: 10) {
                        IconTile(systemImage: leg.line?.product.symbolName ?? "tram.fill", color: color, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leg.line?.name ?? "Zug").font(.headline)
                            if let direction = leg.direction {
                                Text("Richtung \(direction)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if leg.cancelled {
                            InfoChip(text: "Fällt aus", systemImage: "xmark.octagon.fill", tint: .heavyDelay)
                        } else {
                            DelayPill(minutes: leg.departure.delayMinutes)
                        }
                        if leg.tripId != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(leg.tripId == nil)

                VStack(spacing: 0) {
                    TimelineNode(kind: .major, color: color, lineBelow: color) {
                        stationRow(time: leg.departure, name: leg.origin.displayName, platform: leg.departurePlatform)
                    }

                    if !intermediate.isEmpty {
                        TimelineNode(kind: .minor, color: color, lineAbove: color, lineBelow: color) {
                            Button {
                                withAnimation(.snappy) { showStops.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(intermediate.count) Zwischenhalt\(intermediate.count == 1 ? "" : "e")")
                                    Text("· \(leg.arrival.best.timeIntervalSince(leg.departure.best).durationString)")
                                    Image(systemName: "chevron.down")
                                        .rotationEffect(.degrees(showStops ? 180 : 0))
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        if showStops {
                            ForEach(intermediate) { stop in
                                TimelineNode(kind: .minor, color: color, lineAbove: color, lineBelow: color) {
                                    HStack {
                                        Text(stop.station.displayName).font(.caption).lineLimit(1)
                                        Spacer()
                                        if let time = stop.departure ?? stop.arrival {
                                            Text(time.best.timeString)
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(delayColor(time.delayMinutes))
                                        }
                                    }
                                    .strikethrough(stop.cancelled)
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    TimelineNode(kind: .major, color: color, lineAbove: color) {
                        stationRow(time: leg.arrival, name: leg.destination.displayName, platform: leg.arrivalPlatform)
                    }
                }

                if transferBroken {
                    RemarkRow(text: "Dieser Anschluss ist wegen Verspätung nicht mehr erreichbar.")
                }
                ForEach(leg.remarks, id: \.self) { RemarkRow(text: $0) }

                if leg.line?.operatorName != nil || onReplace != nil || onCheckin != nil {
                    Button {
                        withAnimation(.snappy) { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showDetails ? "Weniger" : "Mehr")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showDetails ? 180 : 0))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        if let operatorName = leg.line?.operatorName {
                            Label(operatorName, systemImage: "building.2.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if onReplace != nil || onCheckin != nil {
                            HStack(spacing: 10) {
                                if let onReplace {
                                    ActionTileButton(title: "Anderer Zug", systemImage: "arrow.left.arrow.right", tint: .primary, action: onReplace)
                                }
                                if let onCheckin {
                                    ActionTileButton(title: "Träwelling", systemImage: "checkmark.seal.fill", tint: .brand, action: onCheckin)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showFullTrip) {
            LegTripSheet(leg: leg)
        }
    }

    private func stationRow(time: TimeInfo, name: String, platform: PlatformInfo?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TimeStack(time: time, cancelled: leg.cancelled, font: .headline)
                .frame(width: 54, alignment: .leading)
            Text(name)
                .font(.headline)
                .lineLimit(2)
            Spacer()
            PlatformBadge(platform: platform)
        }
    }
}

struct AlternativeTrainsSheet: View {
    let leg: Leg
    let onSelect: (Leg) async throws -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var alternatives: [Leg] = []
    @State private var isLoading = true
    @State private var applyingID: String?
    @State private var onlyBC100 = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                IconTile(systemImage: "arrow.left.arrow.right", color: .brand, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(leg.origin.displayName) → \(leg.destination.displayName)")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                    Text("Aktuell: \(leg.line?.name ?? "Zug") um \(leg.departure.planned.timeString)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            Toggle(isOn: $onlyBC100) {
                                Label("Nur BahnCard 100", systemImage: "creditcard.fill")
                                    .font(.subheadline.weight(.medium))
                            }
                            .tint(.brand)
                        }
                    }

                    if let error {
                        ErrorBanner(error: error)
                    }

                    if !alternatives.isEmpty {
                        SectionHeader(title: "Züge auf dieser Strecke", systemImage: "tram.fill",
                                      trailing: "30 Min. vorher bis 3 Std. nachher")
                            .padding(.top, 6)
                    }

                    ForEach(alternatives) { alternative in
                        Button {
                            apply(alternative)
                        } label: {
                            AlternativeRow(leg: alternative, current: leg, isApplying: applyingID == alternative.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingID != nil)
                    }
                }
                .padding()
            }
            .background { AppBackground() }
            .overlay {
                if isLoading {
                    ProgressView("Suche Züge …")
                } else if alternatives.isEmpty, error == nil {
                    ContentUnavailableView("Keine anderen Züge", systemImage: "tram.fill",
                                           description: Text("Kein anderer Zug fährt in diesem Zeitraum direkt von \(leg.origin.displayName) nach \(leg.destination.displayName)."))
                }
            }
            .navigationTitle("Anderen Zug wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task(id: onlyBC100) { await load() }
            .onAppear { onlyBC100 = model.settings.onlyBC100ByDefault }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            alternatives = try await model.trainPicker.alternatives(
                for: leg, bc100Rules: onlyBC100 ? model.bc100Rules : nil)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func apply(_ alternative: Leg) {
        applyingID = alternative.id
        Task {
            defer { applyingID = nil }
            do {
                try await onSelect(alternative)
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}

struct AlternativeRow: View {
    let leg: Leg
    let current: Leg
    var isApplying = false

    var body: some View {
        let duration = leg.arrival.best.timeIntervalSince(leg.departure.best)
        let difference = Int((duration - current.arrival.best.timeIntervalSince(current.departure.best)) / 60)
        Card(padding: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    LineBadge(line: leg.line)
                    HStack(spacing: 8) {
                        TimeStack(time: leg.departure, font: .headline)
                        Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        TimeStack(time: leg.arrival, font: .headline)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(duration.compactDuration).font(.subheadline.weight(.semibold))
                    if difference != 0 {
                        Text(difference > 0 ? "+\(difference) min" : "\(difference) min")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(difference > 0 ? Color.slightDelay : Color.punctual)
                    }
                }
                if isApplying {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview("Reiseplan-Teilstrecke") {
    ScrollView {
        VStack(spacing: 16) {
            LegCard(leg: PreviewData.firstLeg, onReplace: {}, onCheckin: {})
            TransferRow(from: PreviewData.firstLeg, to: PreviewData.secondLeg, walk: PreviewData.walk)
            LegCard(leg: PreviewData.secondLeg, onReplace: {}, onCheckin: {})
            AlternativeRow(leg: PreviewData.secondLeg, current: PreviewData.firstLeg)
        }
        .padding()
    }
    .background { AppBackground() }
    .environment(AppModel())
}

/// Finds a new way to the destination after a missed transfer or cancellation.
struct AlternativeJourneySheet: View {
    let entry: SavedJourney
    let onApply: (Journey) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var alternatives: [Journey] = []
    @State private var isLoading = true
    @State private var error: Error?

    /// Legs that still work, and where/when to continue from.
    private var restart: (keep: [Leg], from: Station, date: Date, reason: String)? {
        let legs = entry.journey.legs
        let transit = entry.journey.transitLegs
        guard let destination = legs.last?.destination else { return nil }
        _ = destination
        for issue in entry.journey.connectionIssues() where issue.isBlocking {
            switch issue {
            case .transferMissed(let at, let arrivingLine, _, _):
                guard let arriving = transit.first(where: { $0.line?.name == arrivingLine && $0.destination.name == at }),
                      let index = legs.firstIndex(of: arriving) else { continue }
                return (Array(legs[...index]), arriving.destination, arriving.arrival.best, issue.title)
            case .legCancelled(let line, let from, _):
                guard let cancelled = transit.first(where: { $0.line?.name == line && $0.origin.name == from }),
                      let index = legs.firstIndex(of: cancelled) else { continue }
                return (Array(legs[..<index]), cancelled.origin, cancelled.departure.planned, issue.title)
            case .transferAtRisk:
                continue
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let restart, let destination = entry.journey.legs.last?.destination {
                        Card {
                            HStack(spacing: 12) {
                                IconTile(systemImage: "arrow.triangle.branch", color: .brand, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ab \(restart.from.displayName)").font(.headline)
                                    Text("nach \(destination.displayName), frühestens \(restart.date.timeString)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let error { ErrorBanner(error: error) }
                    ForEach(alternatives) { alternative in
                        Button {
                            apply(alternative)
                        } label: {
                            JourneyCard(journey: alternative)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Der bisherige Reiseplan bleibt unter „Frühere Reisepläne“ erhalten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding()
            }
            .background { AppBackground() }
            .overlay {
                if isLoading {
                    ProgressView("Suche Alternativen …")
                } else if alternatives.isEmpty, error == nil {
                    ContentUnavailableView("Keine Alternativen gefunden", systemImage: "tram.fill")
                }
            }
            .navigationTitle("Alternative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        defer { isLoading = false }
        guard let restart, let destination = entry.journey.legs.last?.destination else {
            error = TransitError.notFound("Problemstelle")
            return
        }
        do {
            let page = try await model.provider.journeys(JourneyQuery(
                from: restart.from, to: destination, date: restart.date.addingTimeInterval(2 * 60)))
            var results = page.journeys.filter { !$0.connectionIssues().contains(where: \.isBlocking) }
            if model.settings.onlyBC100ByDefault { results = results.filter(model.bc100Rules.isValid) }
            alternatives = results
        } catch {
            self.error = error
        }
    }

    private func apply(_ alternative: Journey) {
        guard let restart else { return }
        let combined = Journey(legs: restart.keep + alternative.legs, source: entry.journey.source)
        model.replaceSaved(id: entry.id, with: combined, reason: restart.reason)
        onApply(combined)
        dismiss()
    }
}
