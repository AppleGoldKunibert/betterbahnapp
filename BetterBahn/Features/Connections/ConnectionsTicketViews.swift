import BetterBahnKit
import SwiftUI

// The connection search drawn as a ticket (#504): the search itself, the saved journeys and the recent
// searches. Only used on the first page of the Verbindungen tab.

// MARK: - Shapes

/// A ticket: rounded corners and a round notch on both sides at each `notches` position (y in the
/// shape's frame), where a perforation parts it.
nonisolated struct TicketShape: Shape {
    static let defaultNotchRadius: CGFloat = 10
    var notches: [CGFloat]
    var notchRadius: CGFloat = TicketShape.defaultNotchRadius
    var cornerRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let r = notchRadius
        let c = cornerRadius
        // Notches that would run into a corner (while the layout settles) are left out.
        let ys = notches.filter { $0 - r > rect.minY + c && $0 + r < rect.maxY - c }.sorted()
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: c)
        for y in ys {
            path.addLine(to: CGPoint(x: rect.maxX, y: y - r))
            path.addRelativeArc(center: CGPoint(x: rect.maxX, y: y), radius: r,
                                startAngle: .degrees(-90), delta: .degrees(-180))
        }
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: c)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: c)
        for y in ys.reversed() {
            path.addLine(to: CGPoint(x: rect.minX, y: y + r))
            path.addRelativeArc(center: CGPoint(x: rect.minX, y: y), radius: r,
                                startAngle: .degrees(90), delta: .degrees(-180))
        }
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: c)
        path.closeSubpath()
        return path
    }
}

/// The ticket's top part: rounded top corners and half of each side notch at the bottom, to clip the
/// route (and its suggestions) to.
nonisolated struct TicketTopShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = TicketShape.defaultNotchRadius
        let c: CGFloat = 22
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addRelativeArc(center: CGPoint(x: rect.minX, y: rect.maxY), radius: r,
                            startAngle: .degrees(0), delta: .degrees(-90))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: c)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: c)
        path.addRelativeArc(center: CGPoint(x: rect.maxX, y: rect.maxY), radius: r,
                            startAngle: .degrees(-90), delta: .degrees(-90))
        path.closeSubpath()
        return path
    }
}

/// A line along the middle of its frame, stroked dashed for the perforation.
nonisolated private struct PerforationLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// Where the perforations of a ticket sit, so its outline can put the notches there.
struct TicketNotchKey: PreferenceKey {
    static let defaultValue: [Anchor<CGPoint>] = []
    static func reduce(value: inout [Anchor<CGPoint>], nextValue: () -> [Anchor<CGPoint>]) {
        value += nextValue()
    }
}

/// The dashed line between two parts of a ticket; `ticketBackground` puts the notches at its ends.
struct TicketPerforation: View {
    var notchRadius: CGFloat = TicketShape.defaultNotchRadius

    var body: some View {
        PerforationLine()
            .stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
            .frame(height: 1.5)
            .padding(.horizontal, notchRadius + 8)
            .anchorPreference(key: TicketNotchKey.self, value: .center) { [$0] }
            .accessibilityHidden(true)
    }
}

extension View {
    /// The ticket surface behind this view, notched at each `TicketPerforation` inside it, with an outline.
    func ticketBackground(notchRadius: CGFloat = TicketShape.defaultNotchRadius, cornerRadius: CGFloat = 22,
                          outline: Color = .hairline, outlineWidth: CGFloat = 1) -> some View {
        backgroundPreferenceValue(TicketNotchKey.self) { anchors in
            GeometryReader { proxy in
                let shape = TicketShape(notches: anchors.map { proxy[$0].y }, notchRadius: notchRadius,
                                        cornerRadius: cornerRadius)
                shape.fill(Color.ticket)
                    .overlay(shape.stroke(outline, lineWidth: outlineWidth))
            }
        }
    }
}

// MARK: - Fields

/// One field of the ticket's options: a small upper-case label over its value, with a symbol showing that a
/// tap opens something. Values that differ from the default are red, so a changed option stands out at a glance.
struct TicketFieldLabel: View {
    let title: String
    let value: String
    var changed = false
    /// Menus show up-down chevrons, popovers a down chevron; nil leaves room for a button laid over the field.
    var indicator: String? = "chevron.up.chevron.down"

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    // Fixed colors: a menu would tint its label otherwise.
                    .foregroundStyle(Color.secondary)
                Text(value)
                    .font(.headline)
                    .foregroundStyle(changed ? Color.brand : Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            if let indicator {
                Image(systemName: indicator)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            } else {
                Color.clear.frame(width: 28, height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

// MARK: - Your journeys

/// The upcoming saved journeys as small tickets, one below the other, with the followed check-ins above.
struct TripTicketsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let upcoming = model.upcomingJourneys
        VStack(alignment: .leading, spacing: 10) {
            FollowedCheckinsSection()
            SectionHeader(title: String(localized: "Deine Reisen"), systemImage: "bookmark.fill",
                          trailing: upcoming.isEmpty ? nil : "\(upcoming.count)")
            if upcoming.isEmpty {
                Text("Hier erscheinen deine gespeicherten Reisen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, entry in
                    TripTicket(entry: entry, isNext: index == 0)
                }
            }
        }
    }
}

/// A saved journey as a small ticket: the day, the times, start → destination and what needs attention.
/// Opens the journey like `SavedJourneyRow`.
private struct TripTicket: View {
    let entry: SavedJourney
    var isNext = false
    @Environment(AppModel.self) private var model
    @State private var journeyToRemove: Journey?

    private static let notchRadius: CGFloat = 7
    private static let cornerRadius: CGFloat = 18

    var body: some View {
        let journey = entry.journey
        let blocking = entry.issues.first(where: \.isBlocking)
        let claim = model.passengerRightsClaim(for: entry)
        RouteLink(value: ConnectionsRoute.journey(entry.route())) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 9)
                TicketPerforation(notchRadius: Self.notchRadius)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let departure = journey.departure {
                                TimeStack(time: departure, cancelled: journey.isCancelled, font: .title3.weight(.bold))
                            }
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                            if let arrival = journey.arrival {
                                TimeStack(time: arrival, cancelled: journey.isCancelled, font: .title3.weight(.bold))
                            }
                        }
                        if let first = journey.legs.first, let last = journey.legs.last {
                            Text("\(first.origin.displayName) → \(last.destination.displayName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let blocking {
                            Label(blocking.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.heavyDelay)
                        }
                        if let claim {
                            PassengerRightsBadge(claim: claim)
                                .padding(.horizontal, -6)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }
            .fontDesign(.rounded)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ticketBackground(notchRadius: Self.notchRadius, cornerRadius: Self.cornerRadius,
                              outline: blocking != nil ? Color.heavyDelay : (highlightsAsNext ? Color.brand : Color.hairline),
                              outlineWidth: blocking != nil || highlightsAsNext ? 2 : 1)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reise löschen", systemImage: "trash", role: .destructive) {
                model.remove(entry.journey, askingToCheckOut: &journeyToRemove)
            }
        }
        .checkoutPrompt($journeyToRemove)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text(dayLabel)
                .tracking(0.5)
                .textCase(.uppercase)
            if isNext, model.liveActivities.isActive(entry.journey) {
                Image(systemName: "bolt.badge.clock.fill").foregroundStyle(Color.brand)
            }
            let tickets = model.tickets(for: entry)
            if !tickets.isEmpty {
                let onlyReservations = tickets.allSatisfy(\.ticket.isReservationOnly)
                Image(systemName: onlyReservations ? "carseat.right.fill" : "ticket.fill").foregroundStyle(Color.brand)
                    .accessibilityLabel(onlyReservations ? "Reservierung gespeichert" : "Ticket gespeichert")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    /// Like `SavedJourneyRow`: the next journey is only framed once it departs within 24 hours.
    private var highlightsAsNext: Bool {
        guard isNext, let departure = entry.journey.departure?.best else { return false }
        return departure <= Date.now.addingTimeInterval(24 * 3600)
    }

    private var dayLabel: String {
        guard let date = entry.journey.departure?.planned else { return "" }
        if Calendar.current.isDateInToday(date) { return String(localized: "Heute") }
        if Calendar.current.isDateInTomorrow(date) { return String(localized: "Morgen") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Links

/// A plain row at the end of the page ("Vergangene Fahrten", "Sammlung").
struct LinkRowLabel: View {
    let title: String
    let systemImage: String
    /// A red count after the title, like "3" new items.
    var badge: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.brand, in: .capsule)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}
