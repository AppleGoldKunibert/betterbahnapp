import BetterBahnKit
import SwiftUI

/// The small "−42 kg CO₂" under a journey's legs (#386); tapping it opens `CO2Sheet`.
struct CO2SavingButton: View {
    let comparison: CO2Comparison
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "leaf.fill").foregroundStyle(Color.punctual)
                Text("−\(CO2Comparison.kilogramsText(comparison.savedComparedToCar)) CO₂")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(CO2Comparison.kilogramsText(comparison.savedComparedToCar)) CO₂ weniger als mit dem Auto")
        .sheet(isPresented: $showsDetails) { CO2Sheet(comparison: comparison) }
    }
}

/// Distance and CO₂ by train, car and plane for one journey.
struct CO2Sheet: View {
    let comparison: CO2Comparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Strecke", value: "\(comparison.kilometers.formatted(.number.precision(.fractionLength(0)))) km")
                }
                Section {
                    row(String(localized: "Bahn"), systemImage: "tram.fill", kilograms: comparison.train, color: .punctual)
                    row(String(localized: "Auto"), systemImage: "car.fill", kilograms: comparison.car, color: .slightDelay)
                    row(String(localized: "Flugzeug"), systemImage: "airplane", kilograms: comparison.plane, color: .heavyDelay)
                } header: {
                    Text("CO₂ für diese Reise")
                } footer: {
                    Text("Mit der Bahn sparst du \(CO2Comparison.kilogramsText(comparison.savedComparedToCar)) gegenüber dem Auto und \(CO2Comparison.kilogramsText(comparison.savedComparedToPlane)) gegenüber dem Flugzeug.")
                }
                Section {
                } footer: {
                    Text("Durchschnittswerte des Umweltbundesamts von 2024 pro Person und Kilometer für Fernverkehr, Nahverkehr, Auto und Inlandsflug.")
                }
            }
            .navigationTitle("CO₂-Vergleich")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, systemImage: String, kilograms: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text(CO2Comparison.kilogramsText(kilograms)).monospacedDigit()
            } label: {
                Label(title, systemImage: systemImage)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(4, proxy.size.width * kilograms / max(comparison.plane, comparison.car, comparison.train, 0.001)))
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }
}

extension CO2Comparison {
    /// "0,6 kg" below 10 kg, else whole kilograms ("42 kg").
    static func kilogramsText(_ kilograms: Double) -> String {
        "\(kilograms.formatted(.number.precision(.fractionLength(kilograms < 10 ? 1 : 0)))) kg"
    }
}
