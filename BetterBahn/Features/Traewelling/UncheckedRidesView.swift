import BetterBahnKit
import SwiftUI

/// Saved rides already travelled that no Träwelling check-in covers — the rides the travel map only
/// shows with "Gespeichert" on. Helps to find check-ins that were forgotten.
struct UncheckedRidesView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TravelMapRange = .month
    @State private var isLoaded = false

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
                if rides.isEmpty {
                    ContentUnavailableView("Alles eingecheckt", systemImage: "checkmark.seal.fill",
                                           description: Text("Jede gespeicherte Fahrt in diesem Zeitraum hat einen Träwelling-Check-in."))
                } else {
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
        // A full resync also finds check-ins the incremental sync stopped short of.
        .refreshable { await model.syncTraewelling(force: true) }
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
        }
        .padding(.vertical, 2)
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
}
