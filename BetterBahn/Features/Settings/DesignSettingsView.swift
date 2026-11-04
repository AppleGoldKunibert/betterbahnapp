import BetterBahnKit
import SwiftUI
import UIKit

/// Settings › Design (#504): the app's design with a preview of each, and the accent color, which the app icon
/// follows.
struct DesignSettingsView: View {
    private var theme: Theme { Theme.shared }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(AppDesign.allCases, id: \.self) { design in
                        DesignPreviewButton(design: design, isSelected: theme.design == design) {
                            withAnimation(.snappy) { theme.design = design }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                .listRowBackground(Color.clear)
            } header: {
                Text("Design")
            } footer: {
                Text(theme.design.summary)
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 14) {
                    ForEach(AccentPreset.allCases, id: \.self) { preset in
                        AccentSwatch(color: preset.color, name: preset.displayName,
                                     isSelected: theme.accent == .preset(preset)) {
                            withAnimation(.snappy) { theme.accent = .preset(preset) }
                        }
                    }
                }
                .padding(.vertical, 6)

                ColorPicker(selection: customColor, supportsOpacity: false) {
                    HStack(spacing: 12) {
                        Text("Eigene Farbe")
                        if case .custom = theme.accent {
                            Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.brandText)
                        }
                    }
                }
            } header: {
                Text("Akzentfarbe")
            }

            Section {
                HStack(spacing: 14) {
                    AppLogoView(size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App-Symbol").font(.headline)
                        Text("Passt sich deiner Farbe an, sobald du diese Seite verlässt.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Design")
        .navigationBarTitleDisplayMode(.inline)
        // iOS asks before every icon change: change it once, when the user is done picking.
        .onDisappear { theme.applyAppIcon() }
    }

    /// The color picker sets a color of the user's own.
    private var customColor: Binding<Color> {
        Binding {
            theme.accent.color.swiftUIColor
        } set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            theme.accent = .custom(RGBColor(red: red, green: green, blue: blue))
        }
    }
}

extension AppDesign {
    var displayName: String {
        switch self {
        case .minimal: String(localized: "Minimal")
        case .fahrkarte: String(localized: "Fahrkarte")
        }
    }

    var summary: String {
        switch self {
        case .minimal: String(localized: "Vertraut und aufgeräumt: Karten wie gewohnt, seltene Optionen eingeklappt.")
        case .fahrkarte: String(localized: "Die Suche als Fahrkarte, mit runder Schrift und ruhigem Hintergrund.")
        }
    }
}

extension AccentPreset {
    var displayName: String {
        switch self {
        case .rot: String(localized: "Rot")
        case .orange: String(localized: "Orange")
        case .gold: String(localized: "Gold")
        case .gruen: String(localized: "Grün")
        case .tuerkis: String(localized: "Türkis")
        case .blau: String(localized: "Blau")
        case .indigo: String(localized: "Indigo")
        case .lila: String(localized: "Lila")
        case .pink: String(localized: "Pink")
        case .graphit: String(localized: "Graphit")
        }
    }
}

/// A design's card: a small search page drawn with the design's own components, and its name.
private struct DesignPreviewButton: View {
    let design: AppDesign
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                DesignPreview()
                    .environment(\.appDesign, design)
                    .frame(height: 210)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isSelected ? Color.brandText : Color.hairline, lineWidth: isSelected ? 2.5 : 1)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.brandText : Color.secondary)
                    Text(design.displayName).font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(design.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A miniature of the connection search in the design of the environment.
private struct DesignPreview: View {
    @Environment(\.appDesign) private var design

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if design == .fahrkarte {
                Text("Wohin geht’s?")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                VStack(alignment: .leading, spacing: 0) {
                    stop(label: String(localized: "Von"), name: "Berlin Hbf", ticket: true)
                    stop(label: String(localized: "Nach"), name: "München Hbf", ticket: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ticketBackground(cornerRadius: 12)
            } else {
                Text("Verbindungen").font(.system(size: 15, weight: .bold))
                Card(padding: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        stop(label: String(localized: "Start"), name: "Berlin Hbf", ticket: false)
                        Divider()
                        stop(label: String(localized: "Ziel"), name: "München Hbf", ticket: false)
                    }
                }
            }
            Card(padding: 10) {
                HStack(spacing: 6) {
                    IconTile(systemImage: "slider.horizontal.3", color: .secondary, size: 18)
                    Text("Optionen").font(.system(size: 10, weight: .medium))
                }
            }
            Text("Suchen")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.onBrand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.brand, in: .capsule)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { AppBackground() }
    }

    private func stop(label: String, name: String, ticket: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ticket ? label.uppercased() : label)
                .font(.system(size: 7, weight: ticket ? .semibold : .regular))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: ticket ? 12 : 10, weight: .bold, design: ticket ? .rounded : .default))
                .lineLimit(1)
        }
        .padding(.vertical, ticket ? 3 : 0)
    }
}

/// One accent color to pick: a filled circle, ringed while selected.
private struct AccentSwatch: View {
    let color: RGBColor
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 36, height: 36)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark").font(.footnote.weight(.bold))
                            .foregroundStyle(color.readableForeground.swiftUIColor)
                    }
                }
                .padding(3)
                .overlay { Circle().strokeBorder(isSelected ? color.swiftUIColor : .clear, lineWidth: 2) }
                .frame(maxWidth: .infinity)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The app icon in the current accent color: the train on an accent gradient, as on the home screen.
struct AppLogoView: View {
    let size: CGFloat

    var body: some View {
        let accent = Theme.shared.accent.color
        let hsb = accent.hsb
        // The home screen icons' gradient: lighter and a little less saturated at the top.
        LinearGradient(colors: [Color(hue: hsb.hue, saturation: hsb.saturation * 0.79, brightness: min(1, hsb.brightness * 1.14)),
                                accent.swiftUIColor],
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                Image("AppLogoTrain")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}
