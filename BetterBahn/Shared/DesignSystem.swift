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
    /// Page background of the calm design: a warm off-white, near-black in dark mode.
    static let canvas = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
            : UIColor(red: 0.96, green: 0.955, blue: 0.945, alpha: 1)
    })
    /// Thin outline of flat cards.
    static let hairline = Color.primary.opacity(0.08)
}

nonisolated private struct CalmDesignKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The calm design (flat cards, no glow, plain section titles), switched on page by page while it is
    /// rolled out. Set with `calmDesign()` at a page's root.
    nonisolated var calmDesign: Bool {
        get { self[CalmDesignKey.self] }
        set { self[CalmDesignKey.self] = newValue }
    }
}

nonisolated private struct RouteMapDesignKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The route-map look of the connection search: stops as rings on a red line, options as chips.
    /// Set with `routeMapDesign()`; other pages using the same fields keep their look.
    nonisolated var routeMapDesign: Bool {
        get { self[RouteMapDesignKey.self] }
        set { self[RouteMapDesignKey.self] = newValue }
    }
}

extension View {
    /// Draws this page and its cards, section headers and background in the calm design.
    func calmDesign() -> some View {
        environment(\.calmDesign, true)
    }

    /// Draws this page's station fields and time button in the route-map look.
    func routeMapDesign() -> some View {
        environment(\.routeMapDesign, true)
    }
}

/// A stop on a route map: a ring sitting on the line, smaller for intermediate stops.
struct RouteStopMarker: View {
    var isIntermediate = false
    @ScaledMetric(relativeTo: .title3) private var terminusSize: CGFloat = 19
    @ScaledMetric(relativeTo: .title3) private var stopSize: CGFloat = 13

    var body: some View {
        Circle()
            .fill(Color.card)
            .overlay {
                Circle().strokeBorder(isIntermediate ? Color.brand : Color.primary, lineWidth: isIntermediate ? 3 : 4.5)
            }
            .frame(width: isIntermediate ? stopSize : terminusSize, height: isIntermediate ? stopSize : terminusSize)
            .accessibilityHidden(true)
    }
}

/// Capsule behind a route-map option chip: plain at its default, tinted once something is set.
struct ChipBackground: View {
    var isActive: Bool

    var body: some View {
        ZStack {
            Capsule().fill(isActive ? Color.brand.opacity(0.12) : Color.card)
            Capsule().strokeBorder(isActive ? Color.brand.opacity(0.45) : Color.hairline, lineWidth: 1)
        }
    }
}

extension TicketType {
    /// Title of the "only valid with this ticket" filter toggle.
    var filterTitle: String { String(localized: "Nur \(displayName)") }

    var filterSubtitle: String {
        switch self {
        case .deutschlandticket: String(localized: "ICE, IC & Co. ausblenden")
        case .bahnCard100: String(localized: "FlixTrain & Co. ausblenden")
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
    @Environment(\.calmDesign) private var calm

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: .rect(cornerRadius: 22, style: .continuous))
            // The calm design separates cards from the page by their outline alone.
            .shadow(color: .black.opacity(calm ? 0 : 0.06), radius: 12, y: 4)
            .overlay {
                // Subtle edge so cards stay visible on dark backgrounds.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(calm ? Color.hairline : Color.primary.opacity(0.06), lineWidth: calm ? 1 : 0.5)
            }
    }
}

/// Grouped background with a soft brand glow at the top.
/// In the calm design a plain off-white page instead.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.calmDesign) private var calm

    var body: some View {
        ZStack(alignment: .top) {
            if calm {
                Color.canvas
            } else {
                Color(.systemGroupedBackground)
                LinearGradient(colors: [Color.brand.opacity(colorScheme == .dark ? 0.28 : 0.16), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
            }
        }
        .ignoresSafeArea()
    }
}

/// In the calm design a bold title in sentence case, without the icon.
struct SectionHeader: View {
    let title: String
    let systemImage: String
    var trailing: String?
    @Environment(\.calmDesign) private var calm

    var body: some View {
        if calm {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        } else {
            classic
        }
    }

    private var classic: some View {
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

/// iOS-Settings style colored icon square. With a `logo` (S-Bahn, U-Bahn, #350) the logo itself takes
/// the tile's place, in its own colors and with the tile's rounded corners. The calm design draws only
/// the symbol, in grey.
struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 30
    var logo: TransitLogo? = nil
    @Environment(\.calmDesign) private var calm

    var body: some View {
        if let logo, UIImage(named: logo.assetName) != nil {
            Image(logo.assetName)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        } else if calm {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

struct IconLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    /// Optional short explanation in small grey text under the title (wraps to a second line if needed).
    var subtitle: String? = nil

    var body: some View {
        Label {
            if let subtitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text(title)
            }
        } icon: {
            IconTile(systemImage: systemImage, color: color, size: 28)
        }
    }
}

// MARK: - Transit components

struct LineBadge: View {
    let line: Line?
    var size: ControlSize = .regular
    @ScaledMetric(relativeTo: .caption) private var logoSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var smallLogoSize: CGFloat = 12

    private var badgeFont: Font { size == .small ? Font.caption2.weight(.bold) : Font.caption.weight(.bold) }

    private var hasLogo: Bool { line?.transitLogo.map { UIImage(named: $0.assetName) != nil } ?? false }

    var body: some View {
        if let line {
            HStack(spacing: 4) {
                // S-Bahn and U-Bahn lines show their logo, like their tile (#350).
                if hasLogo, let logo = line.transitLogo {
                    let side = size == .small ? smallLogoSize : logoSize
                    Image(logo.assetName)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                        .clipShape(.rect(cornerRadius: side * 0.28, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: line.symbolName)
                        .font(badgeFont)
                }
                Text(line.displayName)
                    .font(badgeFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, hasLogo ? (size == .small ? 3 : 4) : (size == .small ? 6 : 8))
            .padding(.trailing, size == .small ? 6 : 8)
            .padding(.vertical, size == .small ? 3 : 4)
            .foregroundStyle(.white)
            .background(line.color.gradient, in: .capsule)
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

/// An operator's logo (#166) on a transparent background, exactly as wide as the logo itself so a
/// narrow one like DB's doesn't sit in a wide empty box. Logos wider than 5:1 (SBB, Länderbahn,
/// PKP IC, …) are scaled down to that width, keeping their proportions, instead of being squashed.
/// In dark mode, logos with dark lettering (`OperatorBrand.needsPlateInDarkMode`) get a soft light
/// plate so they stay readable. Nothing for an operator without a logo.
struct OperatorLogo: View {
    let name: String
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let brand = OperatorBrand(operatorName: name), let logo = UIImage(named: brand.assetName), logo.size.height > 0 {
            let plate = colorScheme == .dark && brand.needsPlateInDarkMode
            Image(uiImage: logo)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: min(height * logo.size.width / logo.size.height, height * 5), height: height)
                .padding(.horizontal, plate ? 4 : 0)
                .padding(.vertical, plate ? 2 : 0)
                .background(plate ? Color(white: 0.88) : .clear, in: .rect(cornerRadius: 4, style: .continuous))
                .accessibilityLabel(name)
        }
    }
}

/// The operator of a train (e.g. "DB Fernverkehr AG") with its logo; operators without a logo
/// (`OperatorBrand`) keep the building icon. Some names are shortened ("ODEG", `OperatorBrand.displayName`).
struct OperatorLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            if OperatorBrand(operatorName: name) != nil {
                OperatorLogo(name: name).accessibilityHidden(true)
            } else {
                Image(systemName: "building.2.fill")
            }
            Text(OperatorBrand.displayName(for: name))
        }
    }
}

/// Everyone running the train you ride (#166): bahn.de names the railway per stop, so international
/// trains have several (Berlin → Praha: DB Fernverkehr, then České dráhy), while the feed only ever
/// names one. Several show as their logos next to each other (a name only where there's no logo);
/// shows the feed's operator until bahn.de answered, and keeps it when bahn.de has nothing.
struct TrainOperatorsLabel: View {
    enum Source { case leg(Leg), trip(Trip) }

    let source: Source
    @Environment(AppModel.self) private var model
    @State private var operators: [TrainOperator]?

    private var feedName: String? {
        switch source {
        case .leg(let leg): leg.line?.operatorName
        case .trip(let trip): trip.line?.operatorName
        }
    }

    private var key: String {
        switch source {
        case .leg(let leg): leg.id
        case .trip(let trip): trip.id
        }
    }

    var body: some View {
        Group {
            if let operators, operators.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(operators.enumerated()), id: \.offset) { _, entry in
                        if OperatorBrand(operatorName: entry.name) != nil {
                            OperatorLogo(name: entry.name)
                        } else {
                            Text(OperatorBrand.displayName(for: entry.name))
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(operators.map(\.name).joined(separator: ", "))
            } else if let name = operators?.first?.name ?? feedName {
                OperatorLabel(name: name)
            }
        }
        .task(id: key) {
            guard let bahnDe = model.provider.bahnDe else { return }
            let found: [TrainOperator]?
            switch source {
            case .leg(let leg): found = try? await bahnDe.trainOperators(for: leg)
            case .trip(let trip): found = try? await bahnDe.trainOperators(for: trip)
            }
            if let found { operators = found }
        }
    }
}

/// Triebzug numbers and names of a train (e.g. "Tz 9457 „Bundesrepublik Deutschland“"). bahn.de's
/// coach sequence first (it only has one in the coming hours); bahn.expert as fallback, which
/// has the Tz once its data is live. That bahn.de's current Wagenreihung is missing says `CoachSequenceDisclosure`.
/// A saved journey's leg remembers what was found, so it still shows once neither source answers.
struct TrainFormationLabel: View {
    let request: BahnDeClient.FormationRequest?
    let line: Line?
    let date: Date
    let leg: Leg?

    init(leg: Leg) {
        request = BahnDeClient.formationRequest(for: leg)
        line = leg.line
        date = leg.departure.planned
        self.leg = leg
    }

    init(trip: Trip, savedLeg: Leg? = nil) {
        request = BahnDeClient.formationRequest(for: trip)
        line = trip.line
        date = trip.stopovers.first?.departure?.planned ?? .now
        leg = savedLeg
    }

    @Environment(AppModel.self) private var model
    @State private var formation: TrainFormation?

    var body: some View {
        // A ZStack rather than Group: `.task` never fires on a view that is empty, and this one is
        // empty until the lookup it starts has finished.
        ZStack(alignment: .leading) {
            if let units = formation?.unitDescription {
                Label(units, systemImage: "tram.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fullTextPopup(units, lines: 2)
            }
        }
        .task(id: "\(line?.name ?? "")|\(date)|\(request?.station.id ?? "")") {
            let remembered = leg.flatMap(model.rememberedFormation(for:))
            formation = remembered
            var found: TrainFormation?
            if let request {
                found = try? await model.formation(for: request)
            }
            if found?.unitDescription == nil, let fallback = await model.trainType(for: line, on: date)?.formation,
               fallback.unitDescription != nil {
                found = fallback
            }
            if let found, found.unitDescription != nil || found.isIC1 {
                // An IC 1 has no Tz: hide (and forget) one remembered by an older version.
                formation = found
                if let leg { model.rememberFormation(found, for: leg) }
            }
        }
    }
}

/// "ICE 4" / "ICE 3neo" / "ICE L" … next to a train's name. bahn.de's coach sequence first (the same
/// request `TrainFormationLabel` makes, so it is only sent once); then the planned formation for days
/// ahead from vagonweb.cz, or bahn.expert when vagonweb has none (`AppModel.trainType`).
struct TrainSeriesTag: View {
    let request: BahnDeClient.FormationRequest?
    let line: Line?
    let date: Date
    /// The leg's whole train, asked for when the leg itself has no stop left that bahn.de would
    /// answer for (it is over) and bahn.expert knows no series, as the train may still be running.
    let tripId: String?
    let source: DataSource?
    /// A saved journey's leg, whose remembered formation is shown when nothing answers any more.
    let leg: Leg?

    init(leg: Leg) {
        request = BahnDeClient.formationRequest(for: leg)
        line = leg.line
        date = leg.departure.planned
        tripId = leg.tripId
        source = leg.source
        self.leg = leg
    }

    init(trip: Trip, savedLeg: Leg? = nil) {
        request = BahnDeClient.formationRequest(for: trip)
        line = trip.line
        date = trip.stopovers.lazy.compactMap { $0.departure?.planned ?? $0.arrival?.planned }.first ?? .now
        tripId = nil
        source = nil
        leg = savedLeg
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
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.secondary)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
                    .accessibilityLabel("Baureihe \(family)")
            }
        }
        .task(id: "\(line?.name ?? "")|\(Int(date.timeIntervalSince1970 / 60))|\(request?.station.id ?? "")") {
            family = nil
            if let request, let live = try? await model.formation(for: request), let summary = live.modelSummary {
                family = summary
                if let leg { model.rememberFormation(live, for: leg) }
            } else if let leg, let remembered = model.rememberedFormation(for: leg)?.modelSummary {
                // The trainsets that actually ran (with their Tz) beat the plan, which can't tell a
                // redesigned ICE 3neo apart.
                family = remembered
            } else if let planned = await model.trainType(for: line, on: date), let summary = planned.summary {
                family = summary
                // Kept for the collection's series until a Tz is seen for the ride.
                if let leg { model.rememberFormation(planned.formation, for: leg) }
            } else if request == nil, let tripId, let source,
                      let trip = try? await model.provider.trip(id: tripId, source: source),
                      let later = BahnDeClient.formationRequest(for: trip) {
                family = try? await model.formation(for: later)?.modelSummary
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
    /// Opens the Wagenreihung at this stop. Only used for a platform from the Czech timetable, whose
    /// tap shows where it comes from: the note then offers the Wagenreihung instead.
    var onCoachSequence: (() -> Void)?
    @State private var showsSource = false

    var body: some View {
        if platform?.source == .czechTimetable, platform?.best != nil {
            // Planned only (see `PlatformInfo.Source.czechTimetable`); tapping says so.
            Button {
                showsSource = true
            } label: {
                badge.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Zeigt, woher das Gleis stammt")
            .popover(isPresented: $showsSource) {
                PlannedPlatformNote(onCoachSequence: onCoachSequence.map { open in
                    {
                        showsSource = false
                        // The Wagenreihung sheet only opens once the popover is gone.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            open()
                        }
                    }
                })
                .presentationCompactAdaptation(.popover)
            }
        } else {
            badge
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let best = platform?.best {
            let changed = platform?.hasChanged == true
            VStack(spacing: 0) {
                Text("Gleis")
                    .font(.system(size: 8, weight: .semibold))
                    .textCase(.uppercase)
                    .opacity(0.8)
                // One line: a range like "2 A - D" widens the badge instead of wrapping,
                // and only shrinks when the row has no room left.
                Text(best)
                    .font(prominent ? .headline : .subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // Thin edges inside the usual width: short platforms keep the old size, and a wide one
            // only grows by what its text needs beyond that.
            .padding(.horizontal, 2)
            .frame(minWidth: prominent ? 54 : 46)
            .padding(.vertical, 4)
            .foregroundStyle(changed ? .white : .primary)
            .background(changed ? AnyShapeStyle(Color.heavyDelay.gradient) : AnyShapeStyle(Color.secondary.opacity(0.13)),
                        in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if changed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white, Color.heavyDelay)
                        .offset(x: 5, y: -5)
                } else if platform?.source == .czechTimetable {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white, Color.secondary)
                        .offset(x: 5, y: -5)
                }
            }
        }
    }
}

/// Where a platform from the Czech timetable comes from, shown by tapping its `PlatformBadge`.
struct PlannedPlatformNote: View {
    var onCoachSequence: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Gleis laut Fahrplan", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
            Text("Gleis laut tschechischem Fahrplan. Achte vor Ort auf die Anzeigen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onCoachSequence {
                Button("Wagenreihung anzeigen", systemImage: "train.side.front.car", action: onCoachSequence)
                    .font(.caption.weight(.semibold))
                    .tint(.brand)
                    .padding(.top, 2)
            }
        }
        .padding()
        // A fixed width, so the popover measures the text's height at the width it shows it at
        // (with a width range the last line was cut off).
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// An arrow under the platform badge of the stop where the user gets off (#394): which side of the
/// train the platform is on. Tapping it says so in words ("Ausstieg in Fahrtrichtung links").
struct ExitSideArrow: View {
    let side: ExitSide
    @State private var showsNote = false

    private var symbol: String { side == .left ? "arrow.left.to.line" : "arrow.right.to.line" }

    var body: some View {
        Button {
            showsNote = true
        } label: {
            // Hugs its content: a wider frame would widen the column and push the badge off the
            // other rows' badges.
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(side.displayName)
        .popover(isPresented: $showsNote) {
            Label(side.displayName, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding()
                // A fixed width, centred: the popover is wider than the text's own size anyway.
                .frame(width: 300)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
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

/// DB's occupancy forecast as a small icon (#399): one to three figures, red when exceptionally high.
struct OccupancyIcon: View {
    let level: OccupancyLevel
    var font: Font = .caption

    var body: some View {
        Image(systemName: level.symbolName)
            .font(font)
            .foregroundStyle(level.tint)
            .accessibilityLabel(level.text)
    }
}

/// The occupancy icon of the class travelled in, next to a train's name; a tap shows the forecast in words.
/// Nothing when DB has no forecast for that class.
struct OccupancyButton: View {
    let forecast: OccupancyForecast?
    let travelClass: TravelClass
    @State private var showDetails = false

    var body: some View {
        if let forecast, let level = forecast.level(for: travelClass) {
            Button {
                showDetails = true
            } label: {
                OccupancyIcon(level: level, font: .body)
                    .padding(4)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(level.text), \(travelClass.displayName)")
            .popover(isPresented: $showDetails) {
                OccupancyDetails(forecast: forecast, travelClass: travelClass)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// The forecast in words: the class travelled in first, the other one below it.
struct OccupancyDetails: View {
    let forecast: OccupancyForecast
    let travelClass: TravelClass

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let level = forecast.level(for: travelClass) {
                Label {
                    Text("\(level.text) · \(travelClass.displayName)")
                } icon: {
                    OccupancyIcon(level: level)
                }
            }
            ForEach(forecast.otherLevels(than: travelClass), id: \.travelClass) { other in
                Text("\(other.travelClass.displayName): Auslastung \(other.level.shortText)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

extension OccupancyLevel {
    var tint: Color {
        switch self {
        case .low, .medium: .secondary
        case .high: .slightDelay
        case .exceptional, .exceptionalInBothClasses: .heavyDelay
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
                    Text(message.displayText)
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
        InfoChip(text: String(localized: "Fahrplandaten: Transitous"),
                 systemImage: "point.3.connected.trianglepath.dotted", tint: .secondary)
    }
}

/// Proportional bar of all legs, colored by product, laid out by `Journey.barSpans` (in order, a leg
/// a late train runs into pushed back instead of covered).
struct JourneySegmentBar: View {
    let journey: Journey

    var body: some View {
        GeometryReader { proxy in
            let spans = journey.barSpans
            let start = spans.first?.start ?? .now
            let total = max(spans.last.map { $0.end.timeIntervalSince(start) } ?? 1, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.1)).frame(height: 6)
                ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                    let offset = spans[index].start.timeIntervalSince(start) / total
                    let length = spans[index].duration / total
                    Capsule()
                        .fill(leg.isWalking ? AnyShapeStyle(Color.secondary.opacity(0.3))
                                            : AnyShapeStyle((leg.line?.color ?? .gray).gradient))
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

    /// Keeps a page's cards at a readable width, centred, on the iPad and the Mac; on the iPhone it changes nothing.
    func readableWidth() -> some View {
        frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
}

// MARK: - Full text popup

private struct TextHeightsKey: PreferenceKey {
    static let defaultValue: [Bool: CGFloat] = [:]
    static func reduce(value: inout [Bool: CGFloat], nextValue: () -> [Bool: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct FullTextPopup: ViewModifier {
    let text: String
    let lines: Int
    @State private var shown = false
    @State private var truncated = false

    func body(content: Content) -> some View {
        content
            .lineLimit(lines)
            .background(GeometryReader { Color.clear.preference(key: TextHeightsKey.self, value: [false: $0.size.height]) })
            // Hidden copy without a line limit, to tell whether the visible one is cut.
            .background {
                content
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(GeometryReader { Color.clear.preference(key: TextHeightsKey.self, value: [true: $0.size.height]) })
            }
            .onPreferenceChange(TextHeightsKey.self) { heights in
                guard let full = heights[true], let shownHeight = heights[false] else { return }
                truncated = full > shownHeight + 1
            }
            .contentShape(.rect)
            .onTapGesture { shown = true }
            .allowsHitTesting(truncated)
            .fullScreenCover(isPresented: $shown) {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    Text(text)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .frame(maxWidth: 320)
                        .background(.regularMaterial, in: .rect(cornerRadius: 22))
                        .shadow(radius: 20)
                }
                .contentShape(.rect)
                .onTapGesture { shown = false }
                .presentationBackground(.clear)
            }
    }
}

extension View {
    /// Shortens the text to `lines` lines; tapping it shows the full `text` in a small pop-up in
    /// the middle of the screen, tapping again closes it. Don't use inside a `Button`.
    func fullTextPopup(_ text: String, lines: Int = 1) -> some View {
        modifier(FullTextPopup(text: text, lines: lines))
    }
}

// MARK: - Tap to expand

/// Tapping a shortened ("Frankfurt (Main) Hb…") text shows it in full for 10 s; neighbouring text
/// gives up its space meanwhile. Tapping again collapses it earlier.
private struct ExpandOnTap: ViewModifier {
    let collapsedLines: Int
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .lineLimit(expanded ? nil : collapsedLines)
            .layoutPriority(expanded ? 1 : 0)
            .fixedSize(horizontal: false, vertical: expanded)
            .contentShape(.rect)
            .onTapGesture {
                collapseTask?.cancel()
                withAnimation(.snappy) { expanded.toggle() }
                guard expanded else { return }
                collapseTask = Task {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy) { expanded = false }
                }
            }
            .onDisappear { collapseTask?.cancel() }
    }
}

extension View {
    /// See `ExpandOnTap`. Don't use inside a `Button`, the tap would no longer reach it.
    func expandsOnTap(collapsedLines: Int = 1) -> some View {
        modifier(ExpandOnTap(collapsedLines: collapsedLines))
    }
}

/// A train's name with its series tag next to it. The name is never cut for the tag: if both don't
/// fit side by side, the tag moves below the name, or with `wrapsTag` off stays beside it and is
/// shortened instead.
struct TrainNameRow<Tag: View>: View {
    let name: String
    var font: Font = .headline
    var spacing: CGFloat = 6
    var wrapsTag = true
    @ViewBuilder let tag: Tag

    var body: some View {
        // A layout rather than `ViewThatFits`: that one holds the tag once per branch, so switching
        // branches when the tag appears recreated it empty, and the lookup started over for good.
        NameTagLayout(spacing: spacing, wraps: wrapsTag) {
            Text(name).font(font).lineLimit(1).fullTextPopup(name)
            tag
        }
    }
}

/// Places the second subview (the tag) beside the first (the name) if both fit at their ideal
/// width, otherwise below it – or, without `wraps`, still beside it in the width that is left.
private struct NameTagLayout: Layout {
    var spacing: CGFloat
    var wraps: Bool
    var lineSpacing: CGFloat = 3

    private func sizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (name: CGSize, tag: CGSize, beside: Bool) {
        let width = proposal.width ?? .infinity
        let idealName = subviews[0].sizeThatFits(.unspecified)
        let idealTag = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero
        if idealTag.width == 0 {
            return (subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)), .zero, true)
        }
        if idealName.width + spacing + idealTag.width <= width {
            return (idealName, idealTag, true)
        }
        if !wraps {
            let name = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let tag = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - name.width - spacing), height: nil))
            return (name, tag, true)
        }
        let constrained = ProposedViewSize(width: width, height: nil)
        return (subviews[0].sizeThatFits(constrained), subviews[1].sizeThatFits(constrained), false)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let (name, tag, beside) = sizes(proposal, subviews)
        if tag == .zero { return name }
        return beside
            ? CGSize(width: name.width + spacing + tag.width, height: max(name.height, tag.height))
            : CGSize(width: max(name.width, tag.width), height: name.height + lineSpacing + tag.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let (name, tag, beside) = sizes(ProposedViewSize(width: bounds.width, height: nil), subviews)
        if beside {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(name))
            if subviews.count > 1 {
                subviews[1].place(at: CGPoint(x: bounds.minX + name.width + spacing, y: bounds.midY),
                                  anchor: .leading, proposal: ProposedViewSize(tag))
            }
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(name))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + name.height + lineSpacing),
                              proposal: ProposedViewSize(tag))
        }
    }
}

extension AnyTransition {
    /// Folding something in or out of the page (a stop list, the Wagenreihung, a check-in's details). It only
    /// fades: sliding it up by its own height (`.move(edge: .top)`) took it out of its frame while the rest of
    /// the screen moved up under it, so it was drawn over the text above it (#227, #267).
    static var fold: AnyTransition { .opacity }
}
