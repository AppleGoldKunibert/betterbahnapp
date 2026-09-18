import BetterBahnKit
import SwiftUI

// MARK: - Tokens

extension Color {
    static let brand = Color(red: 0.86, green: 0.09, blue: 0.19)
    static let brandDeep = Color(red: 0.55, green: 0.03, blue: 0.14)
    static let punctual = Color(red: 0.13, green: 0.62, blue: 0.35)
    static let slightDelay = Color(red: 0.95, green: 0.55, blue: 0.05)
    static let heavyDelay = Color(red: 0.88, green: 0.15, blue: 0.20)
    /// Card surface: white in light mode, elevated gray in dark mode.
    static let card = Color(.secondarySystemGroupedBackground)
}

extension Date {
    var timeString: String { formatted(date: .omitted, time: .shortened) }
}

extension TimeInterval {
    var durationString: String {
        let minutes = Int((self / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
    }

    var compactDuration: String {
        let minutes = Int((self / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60):\(String(format: "%02d", minutes % 60)) h" : "\(minutes) min"
    }
}

func delayColor(_ minutes: Int?) -> Color {
    guard let minutes else { return .secondary }
    return minutes >= 6 ? .heavyDelay : minutes >= 1 ? .slightDelay : .punctual
}

/// Colors an Umstieg by how comfortable the transfer time is: very short or very long is risky (red),
/// a bit tight or a long wait is okay (yellow), a relaxed transfer is ideal (green).
func transferColor(_ minutes: Int) -> Color {
    switch minutes {
    case ..<5: .heavyDelay
    case 5..<15: .slightDelay
    case 15..<30: .punctual
    case 30..<60: .slightDelay
    default: .heavyDelay
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: .rect(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            .overlay {
                // Subtle edge so cards stay visible on dark backgrounds.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

/// Grouped background with a soft brand glow at the top.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [Color.brand.opacity(colorScheme == .dark ? 0.28 : 0.16), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 340)
        }
        .ignoresSafeArea()
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.brand)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// iOS-Settings style colored icon square.
struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct IconLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconTile(systemImage: systemImage, color: color, size: 28)
        }
    }
}

// MARK: - Transit components

struct LineBadge: View {
    let line: Line?
    var size: ControlSize = .regular

    private var badgeFont: Font { size == .small ? Font.caption2.weight(.bold) : Font.caption.weight(.bold) }

    var body: some View {
        if let line {
            HStack(spacing: 4) {
                Image(systemName: line.product.symbolName)
                    .font(badgeFont)
                Text(line.name)
                    .font(badgeFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, size == .small ? 6 : 8)
            .padding(.vertical, size == .small ? 3 : 4)
            .foregroundStyle(.white)
            .background(line.product.color.gradient, in: .capsule)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "figure.walk")
                Text("Fußweg")
            }
            .font(badgeFont)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.secondary)
            .background(Color.secondary.opacity(0.12), in: .capsule)
        }
    }
}

/// ICE/IC series (e.g. "ICE 3neo") and Triebzugnummer (e.g. "Tz 9465") of a leg, loaded lazily from
/// bahn.de's coach-sequence API since it's DB-only and needs an extra network request.
struct TrainFormationLabel: View {
    let leg: Leg?

    @Environment(AppModel.self) private var model
    @State private var formation: TrainFormation?

    private var summary: String? {
        guard let formation else { return nil }
        let parts = [formation.modelSummary, formation.unitSummary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if let summary {
                Label(summary, systemImage: "tram.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: leg?.id) {
            formation = nil
            guard let leg, let bahnDe = model.provider.bahnDe else { return }
            formation = try? await bahnDe.formation(for: leg)
        }
    }
}

/// Large planned time with the realtime time below, colored by delay.
struct TimeStack: View {
    let time: TimeInfo
    var cancelled = false
    var alignment: HorizontalAlignment = .leading
    var font: Font = .title3.weight(.semibold)

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(time.planned.timeString)
                .font(font)
                .monospacedDigit()
                .strikethrough(cancelled, color: .heavyDelay)
                .foregroundStyle(cancelled ? .secondary : .primary)
            if cancelled {
                Text("Ausfall")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.heavyDelay)
            } else if let actual = time.actual {
                Text(actual.timeString)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(delayColor(time.delayMinutes))
            }
        }
    }
}

struct DelayPill: View {
    let minutes: Int?

    var body: some View {
        if let minutes {
            HStack(spacing: 3) {
                Image(systemName: minutes > 0 ? "clock.badge.exclamationmark.fill" : "checkmark.circle.fill")
                Text(minutes > 0 ? "+\(minutes) min" : "pünktlich")
            }
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(delayColor(minutes))
            .background(delayColor(minutes).opacity(0.14), in: .capsule)
        }
    }
}

struct PlatformBadge: View {
    let platform: PlatformInfo?
    var prominent = false

    var body: some View {
        if let best = platform?.best {
            let changed = platform?.hasChanged == true
            VStack(spacing: 0) {
                Text("Gleis")
                    .font(.system(size: 8, weight: .semibold))
                    .textCase(.uppercase)
                    .opacity(0.8)
                Text(best)
                    .font(prominent ? .headline : .subheadline.weight(.bold))
                    .monospacedDigit()
            }
            .frame(minWidth: prominent ? 46 : 38)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .foregroundStyle(changed ? .white : .primary)
            .background(changed ? AnyShapeStyle(Color.heavyDelay.gradient) : AnyShapeStyle(Color.secondary.opacity(0.13)),
                        in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if changed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white, Color.heavyDelay)
                        .offset(x: 5, y: -5)
                }
            }
        }
    }
}

struct InfoChip: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .labelStyle(ChipLabelStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

struct RemarkRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.slightDelay)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.8))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.slightDelay.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

struct ErrorBanner: View {
    let error: Error

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(Color.heavyDelay)
            Text(error.localizedDescription)
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.heavyDelay.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

struct SourceNotice: View {
    var body: some View {
        InfoChip(text: "Daten von Transitous",
                 systemImage: "point.3.connected.trianglepath.dotted", tint: .secondary)
    }
}

/// Proportional bar of all legs, colored by product.
struct JourneySegmentBar: View {
    let journey: Journey

    var body: some View {
        GeometryReader { proxy in
            let total = max(journey.duration ?? 1, 1)
            let start = journey.departure?.best ?? .now
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.1)).frame(height: 6)
                ForEach(journey.legs) { leg in
                    let offset = max(leg.departure.best.timeIntervalSince(start), 0) / total
                    let length = max(leg.arrival.best.timeIntervalSince(leg.departure.best), 0) / total
                    Capsule()
                        .fill(leg.isWalking ? AnyShapeStyle(Color.secondary.opacity(0.3))
                                            : AnyShapeStyle((leg.line?.product.color ?? .gray).gradient))
                        .frame(width: max(proxy.size.width * length - 2, 4), height: leg.isWalking ? 3 : 6)
                        .offset(x: proxy.size.width * offset)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 8)
    }
}

// MARK: - Timeline

/// One node of a vertical route timeline.
struct TimelineNode<Content: View>: View {
    enum Kind { case major, minor, transfer }

    let kind: Kind
    let color: Color
    var lineAbove: Color? = nil
    var lineBelow: Color? = nil
    var dashedBelow = false
    var dimmed = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    segment(lineAbove, dashed: false).frame(height: kind == .minor ? 9 : 10)
                    segment(lineBelow, dashed: dashedBelow)
                }
                dot.padding(.top, kind == .minor ? 5 : 3)
            }
            .frame(width: 22)
            content
                .padding(.bottom, kind == .minor ? 6 : 14)
                .opacity(dimmed ? 0.45 : 1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func segment(_ color: Color?, dashed: Bool) -> some View {
        if let color {
            if dashed {
                Line()
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 5]))
                    .frame(width: 3)
            } else {
                Rectangle().fill(color).frame(width: 5)
            }
        } else {
            Color.clear.frame(width: 5)
        }
    }

    @ViewBuilder
    private var dot: some View {
        switch kind {
        case .major:
            Circle()
                .strokeBorder(color, lineWidth: 4)
                .background(Circle().fill(Color.card))
                .frame(width: 18, height: 18)
        case .transfer:
            Circle()
                .fill(color)
                .overlay(Circle().fill(Color.card).padding(5))
                .frame(width: 18, height: 18)
        case .minor:
            Circle()
                .fill(Color.card)
                .overlay(Circle().fill(color.opacity(0.9)).padding(2))
                .frame(width: 9, height: 9)
        }
    }

    nonisolated private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
        }
    }
}

// MARK: - Buttons

struct ActionTileButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .brand
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(tint)
                .background(tint.opacity(0.11), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Keeps the last content clear of the floating tab bar.
    func tabBarSafePadding() -> some View {
        safeAreaPadding(.bottom, 24)
    }
}
