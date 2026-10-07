import BetterBahnKit
import SwiftUI

/// Saved rides already travelled that no Träwelling check-in covers — the rides the travel map only
/// shows with "Gespeichert" on. Helps to find check-ins that were forgotten, and checks them in.
struct UncheckedRidesView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TravelMapRange = .month
    @State private var isLoaded = false
    @State private var confirmCheckinAll = false
    @State private var progress: (done: Int, total: Int)?
    /// What checking in did per ride (by `Leg.id`). Successful rides leave the list after the sync
    /// that follows; failed ones stay with their reason.
    @State private var outcomes: [String: Outcome] = [:]
    @State private var summary: String?

    enum Outcome {
        case checkedIn, manualTrip, alreadyCheckedIn
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Zeitraum", selection: $range) {
                    ForEach(TravelMapRange.allCases.filter { $0 != .custom }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let error = model.traewellingSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.slightDelay)
            }
            if !isLoaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                let rides = model.uncheckedRides(in: TravelMapSelection(range: range).interval)
                if let summary {
                    Label(summary, systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                }
                if rides.isEmpty {
                    ContentUnavailableView("Alles eingecheckt", systemImage: "checkmark.seal.fill",
                                           description: Text("Jede gespeicherte Fahrt in diesem Zeitraum hat einen Träwelling-Check-in."))
                } else {
                    Section { checkinAllButton(rides) }
                    Section {
                        ForEach(Array(rides.enumerated()), id: \.offset) { row($0.element) }
                    } header: {
                        Text(rides.count == 1 ? "1 Fahrt" : "\(rides.count) Fahrten")
                    } footer: {
                        Text("Gespeicherte Fahrten, zu denen es keinen Träwelling-Check-in zur selben Zeit gibt. Auf der Karte erscheinen sie nur mit „Gespeichert“. Zum vollständigen Abgleich mit Träwelling nach unten ziehen.")
                    }
                }
            }
        }
        .navigationTitle("Nicht eingecheckt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isSyncingTraewelling {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
        .task {
            await model.loadTraewellingTrips()
            isLoaded = true
            // Otherwise a check-in made since the map was last opened would be listed as missing.
            await model.syncTraewelling()
        }
        // A full resync also finds check-ins the incremental sync stopped short of and takes over
        // edits. It waits for the sync started on open, which would otherwise make it a no-op.
        .refreshable { await fullResync() }
    }

    private func checkinAllButton(_ rides: [Leg]) -> some View {
        Button {
            confirmCheckinAll = true
        } label: {
            HStack {
                if let progress {
                    ProgressView()
                    Text("Checke ein … \(progress.done)/\(progress.total)")
                        .monospacedDigit()
                } else {
                    IconLabel(title: "Alle bei Träwelling einchecken", systemImage: "checkmark.seal.fill", color: .brand)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(progress != nil || model.isSyncingTraewelling)
        .confirmationDialog(rides.count == 1 ? "1 Fahrt einchecken?" : "\(rides.count) Fahrten einchecken?",
                            isPresented: $confirmCheckinAll, titleVisibility: .visible) {
            Button("Einchecken") { Task { await checkInAll(rides) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Sichtbarkeit: \(model.settings.traewellingVisibility.label). Züge, die Träwelling nicht findet, werden als manuelle Fahrt angelegt.")
        }
    }

    private func row(_ leg: Leg) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                LineBadge(line: leg.line, size: .small)
                Spacer()
                Text(leg.departure.planned.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("\(leg.origin.name) → \(leg.destination.name)")
                .font(.subheadline)
            Text(checkinsSameDay(as: leg))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let outcome = outcomes[leg.id] {
                outcomeLabel(outcome)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func outcomeLabel(_ outcome: Outcome) -> some View {
        switch outcome {
        case .checkedIn:
            Label("Eingecheckt", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.punctual)
        case .manualTrip:
            Label("Als manuelle Fahrt eingecheckt", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.punctual)
        case .alreadyCheckedIn:
            Label("Zu dieser Zeit schon eingecheckt", systemImage: "info.circle.fill").font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.slightDelay)
        }
    }

    /// The check-ins the app has for that day, so a ride listed although it was checked in shows
    /// whether the check-in is missing locally or just doesn't line up.
    private func checkinsSameDay(as leg: Leg) -> String {
        let calendar = Calendar.current
        let time = Date.FormatStyle().hour().minute()
        let sameDay = model.traewellingTrips.flatMap(\.journey.transitLegs)
            .filter { calendar.isDate($0.departure.planned, inSameDayAs: leg.departure.planned) }
            .sorted { $0.departure.planned < $1.departure.planned }
            .map { "\($0.line?.name ?? "Fahrt") \($0.departure.planned.formatted(time))–\($0.arrival.planned.formatted(time))" }
        return sameDay.isEmpty
            ? "Kein Träwelling-Check-in an diesem Tag in der App"
            : "Träwelling an dem Tag: " + sameDay.joined(separator: " · ")
    }

    // MARK: Checking in

    /// One after another, oldest first, so the check-ins land on Träwelling in the order they were ridden.
    private func checkInAll(_ rides: [Leg]) async {
        let pending = Array(rides.filter { outcomes[$0.id]?.isFailure ?? true }.reversed())
        summary = nil
        progress = (0, pending.count)
        for (index, leg) in pending.enumerated() {
            outcomes[leg.id] = await checkIn(leg)
            progress = (index + 1, pending.count)
        }
        progress = nil
        var done = 0, manual = 0, failed = 0
        for leg in pending {
            switch outcomes[leg.id] {
            case .checkedIn: done += 1
            case .manualTrip: done += 1; manual += 1
            case .failed: failed += 1
            case .alreadyCheckedIn, nil: break
            }
        }
        summary = "\(done) eingecheckt" + (manual > 0 ? ", davon \(manual) manuell" : "")
            + (failed > 0 ? ", \(failed) fehlgeschlagen" : "")
        // New check-ins for past rides may sit anywhere in the history, past statuses the
        // incremental sync stops at; only a full resync is sure to bring them in.
        await fullResync()
    }

    /// The real train if Träwelling finds it, otherwise a manual trip.
    private func checkIn(_ leg: Leg) async -> Outcome {
        let draft = CheckinDraft(leg: leg, visibility: model.settings.traewellingVisibility)
        do {
            let result = try await model.traewelling.checkin(draft, allowManualTrip: true)
            return result.isManualTrip ? .manualTrip : .checkedIn
        } catch TraewellingError.stopNotOnTrip {
            // Träwelling has the train, but not with these stops: a manual trip still records the ride.
            do {
                _ = try await model.traewelling.checkinAsManualTrip(draft)
                return .manualTrip
            } catch {
                return .failed(error.localizedDescription)
            }
        } catch TraewellingError.collision {
            return .alreadyCheckedIn
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func fullResync() async {
        while model.isSyncingTraewelling { try? await Task.sleep(for: .milliseconds(200)) }
        await model.syncTraewelling(force: true)
    }
}
