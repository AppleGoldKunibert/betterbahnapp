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
    /// Series of the trains still ahead, in order ("ICE 3", "ICE 2", "IC 2 Twindexx").
    @State private var series: [String] = []

    private static let notchRadius: CGFloat = 7
    private static let cornerRadius: CGFloat = 18

    var body: some View {
        let journey = entry.journey
        let blocking = entry.issues.first(where: \.isBlocking)
        let claim = model.passengerRightsClaim(for: entry)
        RouteLink(value: ConnectionsRoute.journey(entry.route())) {
            // Live lines and the trains ahead follow the clock.
            TimelineView(.everyMinute) { context in
                content(status: JourneyLiveStatus.at(context.date, of: journey), now: context.date,
                        blocking: blocking, claim: claim)
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

    private func content(status: JourneyLiveStatus?, now: Date, blocking: ConnectionIssue?,
                         claim: PassengerRightsClaim?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 9)
            TicketPerforation(notchRadius: Self.notchRadius)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let departure = entry.journey.departure {
                            TimeStack(time: departure, cancelled: entry.journey.isCancelled, font: .title3.weight(.bold))
                        }
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                        if let arrival = entry.journey.arrival {
                            TimeStack(time: arrival, cancelled: entry.journey.isCancelled, font: .title3.weight(.bold))
                        }
                    }
                    if let first = entry.journey.legs.first, let last = entry.journey.legs.last {
                        Text("\(first.origin.displayName) → \(last.destination.displayName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let status {
                        liveLines(status, now: now)
                            .padding(.top, 2)
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
        .task(id: status?.upcomingLegs.map(\.id)) {
            series = await model.trainSeries(of: status?.upcomingLegs ?? [])
        }
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
            Spacer(minLength: 8)
            // The trains still ahead, the next one first: a finished ride drops out.
            if !series.isEmpty {
                Text(series.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .accessibilityLabel(String(localized: "Züge: \(series.formatted(.list(type: .and)))"))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: Live

    /// One or two lines of what comes next: the departure, the train being ridden or the transfer
    /// underway, then the change after it.
    private func liveLines(_ status: JourneyLiveStatus, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch status.step {
            case .departure(let leg):
                if leg.cancelled {
                    liveRow(icon: "arrow.up.right", main: lineName(leg), time: String(localized: "Fällt aus"),
                            timeColor: .heavyDelay, platform: nil)
                } else {
                    liveRow(icon: "arrow.up.right", main: lineName(leg), time: when(leg.departure.best, now: now),
                            timeColor: liveColor(leg.departure), platform: platform(leg.departurePlatform))
                }
            case .riding(let leg):
                liveRow(icon: "tram.fill", main: String(localized: "\(lineName(leg)) bis \(leg.destination.displayName)"),
                        time: String(localized: "an \(leg.arrival.best.timeString)"),
                        timeColor: liveColor(leg.arrival), platform: platform(leg.arrivalPlatform))
            case .transfer(_, let next):
                liveRow(icon: "arrow.triangle.swap",
                        main: "\(String(localized: "Umstieg in \(next.origin.displayName)")) · \(lineName(next))",
                        time: next.cancelled ? String(localized: "Fällt aus") : when(next.departure.best, now: now),
                        timeColor: next.cancelled ? .heavyDelay : liveColor(next.departure),
                        platform: platform(next.departurePlatform))
            }
            // Shown from 10 minutes before the arrival (`JourneyLiveStatus.transferLeadTime`).
            if let transfer = status.nextTransfer {
                if transfer.minutes < 0 || transfer.next.cancelled {
                    liveRow(icon: "exclamationmark.triangle.fill", main: transfer.next.origin.displayName,
                            time: String(localized: "Anschluss nicht erreichbar"), timeColor: .heavyDelay, platform: nil)
                } else {
                    liveRow(icon: "arrow.triangle.swap",
                            main: "\(String(localized: "Dann Umstieg in \(transfer.next.origin.displayName)")) · \(lineName(transfer.next))",
                            time: String(localized: "\(transfer.minutes) Min."), timeColor: transferColor(transfer.minutes),
                            platform: platform(transfer.next.departurePlatform))
                }
            }
        }
        .font(.footnote)
    }

    /// Icon, what happens, then the time colored by its delay (or the transfer time by how comfortable it
    /// is) and the platform. The description gives way when the line runs out of room.
    private func liveRow(icon: String, main: String, time: String?, timeColor: Color, platform: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.secondary)
                .frame(width: 14)
                .padding(.trailing, 2)
            Text(main)
                .lineLimit(1)
            if let time {
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text(time)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(timeColor)
                    .fixedSize()
            }
            if let platform {
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text(platform)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Green on time, orange or red when late; plain without live data.
    private func liveColor(_ time: TimeInfo) -> Color {
        time.actual == nil ? .primary : delayColor(time.delayMinutes)
    }

    private func lineName(_ leg: Leg) -> String {
        leg.line?.name ?? String(localized: "Zug")
    }

    private func platform(_ info: PlatformInfo?) -> String? {
        info?.best.map { String(localized: "Gleis \($0)") }
    }

    /// "in 12 Min." within the hour, else "ab 15:20".
    private func when(_ time: Date, now: Date) -> String {
        let minutes = JourneyLiveStatus.minutes(from: now, to: time)
        if minutes >= 0, minutes <= 60 { return String(localized: "in \(minutes) Min.") }
        return String(localized: "ab \(time.timeString)")
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

extension AppModel {
    /// The series of each of `legs` ("ICE 3", "IC 2 Twindexx"): the formation remembered for it, else the
    /// planned one (cached per train and day), else the line ("RE 3").
    func trainSeries(of legs: [Leg]) async -> [String] {
        var names: [String] = []
        for leg in legs {
            if let remembered = rememberedFormation(for: leg)?.modelSummary {
                names.append(remembered)
            } else if let planned = await trainType(for: leg.line, on: leg.departure.planned), let summary = planned.summary {
                names.append(summary)
                // Kept like `TrainSeriesTag` does, for the collection and the next look.
                rememberFormation(planned.formation, for: leg)
            } else if let line = leg.line?.name {
                names.append(line)
            }
        }
        return names
    }
}
