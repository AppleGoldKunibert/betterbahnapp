import BetterBahnKit
import SwiftUI

/// "☀ 18° bei Ankunft" (#385): one quiet line at the destination or a long transfer; a tap shows the
/// hour's forecast.
struct WeatherLabel: View {
    let forecast: WeatherForecast
    /// Follows the temperature: "bei Ankunft", "beim Umstieg".
    let context: String
    let station: String
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: forecast.symbolName)
                    .symbolRenderingMode(.multicolor)
                Text("\(forecast.temperatureText) \(context)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(forecast.conditionText), \(forecast.temperatureText) \(context)")
        .accessibilityHint("Zeigt die Wettervorhersage")
        .popover(isPresented: $showsDetails) {
            WeatherDetails(forecast: forecast, station: station)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The hour's forecast at a station: temperature, rain and wind, with Open-Meteo's credit (CC BY 4.0).
struct WeatherDetails: View {
    let forecast: WeatherForecast
    let station: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: forecast.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(forecast.temperatureText) · \(forecast.conditionText)")
                        .font(.headline)
                    Text("\(station) · \(hourLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let rain = rainText {
                    Label(rain, systemImage: "drop.fill")
                }
                if let wind = forecast.windSpeed {
                    Label("Wind \(Int(wind.rounded())) km/h", systemImage: "wind")
                }
            }
            .font(.subheadline)
            Link("Wetterdaten von Open-Meteo.com", destination: URL(string: "https://open-meteo.com")!)
                .font(.caption2)
                .tint(.secondary)
        }
        .journeyRoundedType()
        .padding()
        // A fixed width, so the popover measures the text's height at the width it shows it at.
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Regen 60 % · 2,7 mm", without the parts the forecast lacks.
    private var rainText: String? {
        var parts: [String] = []
        if let chance = forecast.precipitationProbability { parts.append(String(localized: "\(chance) %")) }
        if let amount = forecast.precipitation, amount > 0 {
            parts.append("\(amount.formatted(.number.precision(.fractionLength(1)))) mm")
        }
        return parts.isEmpty ? nil : String(localized: "Regen \(parts.joined(separator: " · "))")
    }

    private var hourLabel: String {
        let date = forecast.date
        if Calendar.current.isDateInToday(date) { return String(localized: "heute \(date.timeString)") }
        if Calendar.current.isDateInTomorrow(date) { return String(localized: "morgen \(date.timeString)") }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(date.timeString)"
    }
}

#Preview {
    WeatherDetails(forecast: WeatherForecast(date: .now, temperature: 17.6, precipitationProbability: 20, precipitation: 0.3,
                                             windSpeed: 14, weatherCode: 80),
                   station: "München Hbf")
}
