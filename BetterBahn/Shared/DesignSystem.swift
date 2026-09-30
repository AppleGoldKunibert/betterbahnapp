import BetterBahnKit
import SwiftUI
import UIKit

extension UIImage {
    /// The app's own icon, as shown on the home screen. Xcode's icon-set compiler flattens it into
    /// a plain bundle resource referenced from `CFBundleIcons`, so it isn't reachable via the
    /// asset catalog (`UIImage(named: "AppIcon")` returns nil) — this reads it the way Settings.app does.
    static var appIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }
}

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

extension TicketType {
    /// Title of the "only valid with this ticket" filter toggle.
    var filterTitle: String { "Nur \(displayName)" }

    var filterSubtitle: String {
        switch self {
        case .deutschlandticket: "ICE, IC & Co. ausblenden"
        case .bahnCard100: "FlixTrain & Co. ausblenden"
        }
    }

    var symbolName: String {
        switch self {
        case .deutschlandticket: "ticket.fill"
        case .bahnCard100: "creditcard.fill"
        }
    }
}

extension Date {
    var timeString: String { formatted(date: .omitted, time: .shortened) }
}

extension TimeInterval {
    var durationString: String {
        let minutes = Int((self / 60).rounded())
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) h" }
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
    }

    var compactDuration: String {
        let minutes = Int((self / 60).rounded())
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) h" }
        return minutes >= 60 ? "\(minutes / 60):\(String(format: "%02d", minutes % 60)) h" : "\(minutes) min"
    }
}

func delayColor(_ minutes: Int?) -> Color {
    guard let minutes else { return .secondary }
    return minutes > 10 ? .heavyDelay : minutes > 5 ? .slightDelay : .punctual
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

/// Triebzug numbers and names of a train (e.g. "Tz 9457 „Bundesrepublik Deutschland“"). bahn.de's
/// coach sequence first (it only has one in the coming hours); bahn.expert as fallback, which
/// has the Tz once its data is live. Says so when bahn.de is refusing requests and nothing else helped.
struct TrainFormationLabel: View {
    let request: BahnDeClient.FormationRequest?
    let line: Line?
    let date: Date

    init(leg: Leg) {
        request = BahnDeClient.formationRequest(for: leg)
        line = leg.line
        date = leg.departure.planned
    }

    init(trip: Trip) {
        request = BahnDeClient.formationRequest(for: trip)
        line = trip.line
        date = trip.stopovers.first?.departure?.planned ?? .now
    }

    @Environment(AppModel.self) private var model
    @State private var formation: TrainFormation?
    @State private var blocked = false

    var body: some View {
        // A ZStack rather than Group: `.task` never fires on a view that is empty, and this one is
        // empty until the lookup it starts has finished.
        ZStack(alignment: .leading) {
            if let units = formation?.unitDescription {
                Label(units, systemImage: "tram.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if blocked {
                Label("Wagenreihung gerade nicht abrufbar", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(line?.name ?? "")|\(date)|\(request?.station.id ?? "")") {
            formation = nil
            blocked = false
            if let request {
                do {
                    formation = try await model.formation(for: request)
                } catch TransitError.rateLimited {
                    blocked = true
                } catch {}
            }
            if formation?.unitDescription == nil, let fallback = await model.trainType(for: line, on: date)?.formation,
               fallback.unitDescription != nil {
                formation = fallback
                blocked = false
            }
        }
    }
}

/// "ICE 4" / "ICE 3neo" / "ICE L" … next to a train's name. bahn.de's coach sequence first (the same
/// request `TrainFormationLabel` makes, so it is only sent once); bahn.expert as fallback, which has
/// DB's planned formation for days ahead.
struct TrainSeriesTag: View {
    let request: BahnDeClient.FormationRequest?
    let line: Line?
    let date: Date

    init(leg: Leg) {
        request = BahnDeClient.formationRequest(for: leg)
        line = leg.line
        date = leg.departure.planned
    }

    init(trip: Trip) {
        request = BahnDeClient.formationRequest(for: trip)
        line = trip.line
        date = trip.stopovers.first?.departure?.planned ?? .now
    }

    @Environment(AppModel.self) private var model
    @State private var family: String?

    var body: some View {
        // A ZStack rather than Group: `.task` never fires on a view that is empty, and this one is
        // empty until the lookup it starts has finished.
        ZStack {
            if let family {
                Text(family)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.secondary)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
                    .accessibilityLabel("Baureihe \(family)")
            }
        }
        .task(id: "\(line?.name ?? "")|\(date)|\(request?.station.id ?? "")") {
            family = nil
            if let request, let live = try? await model.formation(for: request)?.modelSummary {
                family = live
            } else {
                family = await model.trainType(for: line, on: date)?.summary
            }
        }
    }
}

/// Large planned time with the realtime time below, colored by delay.
struct TimeStack: View {
    let time: TimeInfo
    var cancelled = false
    var alignment: HorizontalAlignment = .leading
    var font: Font = .title3.weight(.semibold)

    /// Live data confirms it's on schedule: the planned time itself turns green instead of repeating below.
    private var liveOnTime: Bool { time.actual != nil && time.delayMinutes == 0 }

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(time.planned.timeString)
                .font(font)
                .monospacedDigit()
                .strikethrough(cancelled, color: .heavyDelay)
                .foregroundStyle(cancelled ? .secondary : liveOnTime ? delayColor(0) : .primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if cancelled {
                Text("Ausfall")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.heavyDelay)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else if let actual = time.actual, !liveOnTime {
                Text(actual.timeString)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(delayColor(time.delayMinutes))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
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

/// Warning triangle for a train's current notes from DB (see `TrainMessage`): red when any of them is
/// a delay reason, yellow for other notices. Tapping it lists them with the time DB reported each.
struct TrainMessagesButton: View {
    let messages: [TrainMessage]
    @State private var showList = false

    private var tint: Color { messages.containsDelayReason ? .heavyDelay : .slightDelay }

    var body: some View {
        if !messages.isEmpty {
            Button {
                showList = true
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(tint)
                    .padding(4)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(messages.containsDelayReason ? "Verspätungsgründe" : "Hinweise zum Zug")
            .popover(isPresented: $showList) {
                TrainMessageList(messages: messages)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

struct TrainMessageList: View {
    let messages: [TrainMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aktuelle Informationen")
                .font(.subheadline.weight(.semibold))
            ForEach(messages) { message in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: message.kind == .delay ? "clock.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(message.kind == .delay ? Color.heavyDelay : Color.slightDelay)
                    Text(message.timestamp?.timeString ?? "–")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(message.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .frame(minWidth: 240, maxWidth: 340, alignment: .leading)
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
        InfoChip(text: "Fahrplandaten: Transitous",
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
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
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
