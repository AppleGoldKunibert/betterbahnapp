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
        .journeyRoundedType()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(CO2Comparison.kilogramsText(comparison.savedComparedToCar)) CO₂ weniger als mit dem Auto")
        .sheet(isPresented: $showsDetails) { CO2Sheet(comparison: comparison) }
    }
}

/// Distance and CO₂ by train, car and plane for one journey. Minimal and Fahrkarte share the layout; the
/// ticket puts a small "STRECKE" over the distance and uses its rounded type.
struct CO2Sheet: View {
    let comparison: CO2Comparison
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            if design == .fahrkarte {
                                JourneyTicketCaption(text: String(localized: "Strecke"))
                            } else {
                                Text("Strecke").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text("\(comparison.kilometers.formatted(.number.precision(.fractionLength(0)))) km")
                                .font(.largeTitle.weight(.bold))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: String(localized: "CO₂ für diese Reise"), systemImage: "leaf.fill")
                        Card {
                            VStack(alignment: .leading, spacing: 16) {
                                row(String(localized: "Bahn"), systemImage: "tram.fill", kilograms: comparison.train, color: .punctual)
                                row(String(localized: "Auto"), systemImage: "car.fill", kilograms: comparison.car, color: .slightDelay)
                                row(String(localized: "Flugzeug"), systemImage: "airplane", kilograms: comparison.plane, color: .heavyDelay)
                            }
                        }
                        Text("Mit der Bahn sparst du \(CO2Comparison.kilogramsText(comparison.savedComparedToCar)) gegenüber dem Auto und \(CO2Comparison.kilogramsText(comparison.savedComparedToPlane)) gegenüber dem Flugzeug.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }

                    Text("Durchschnittswerte des Umweltbundesamts von 2024 pro Person und Kilometer für Fernverkehr, Nahverkehr, Auto und Inlandsflug.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .fontDesign(design == .fahrkarte ? .rounded : nil)
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background { AppBackground() }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                }
                Spacer()
                Text(CO2Comparison.kilogramsText(kilograms))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.subheadline)
            GeometryReader { proxy in
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(4, proxy.size.width * kilograms / max(comparison.plane, comparison.car, comparison.train, 0.001)))
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

extension CO2Comparison {
    /// "0,6 kg" below 10 kg, else whole kilograms ("42 kg").
    static func kilogramsText(_ kilograms: Double) -> String {
        "\(kilograms.formatted(.number.precision(.fractionLength(kilograms < 10 ? 1 : 0)))) kg"
    }
}
