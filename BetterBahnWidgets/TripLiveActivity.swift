import ActivityKit
import BetterBahnKit
import SwiftUI
import WidgetKit

private let brand = Color(red: 0.86, green: 0.09, blue: 0.19)

private func delayColor(_ minutes: Int) -> Color {
    minutes >= 6 ? Color(red: 1.0, green: 0.35, blue: 0.35) : minutes >= 1 ? .orange : .green
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProductBadge(state: state, compact: false)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let platform = state.platform {
                        PlatformChip(platform: platform)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.isDeparture ? "Abfahrt" : "Ankunft")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let transfer = state.transfer {
                            TransferRowView(transfer: transfer, outgoingLine: state.lineName, outgoingTime: state.expectedTime,
                                            outgoingDelayMinutes: state.delayMinutes, outgoingPlatform: state.platform)
                                .foregroundStyle(.primary)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Label(state.nextStopName, systemImage: state.isDeparture ? "arrow.up.right.circle.fill" : "mappin.circle.fill")
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                                Text(state.expectedTime, style: .time)
                                    .font(.title3.weight(.bold))
                                    .monospacedDigit()
                            }
                        }
                        ProgressView(timerInterval: state.progressStart...state.progressEnd, countsDown: false) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .tint(state.product.color)
                        HStack {
                            Label {
                                Text(timerInterval: Date.now...max(state.expectedTime, .now), countsDown: true)
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: "timer")
                            }
                            Spacer()
                            DelayText(state: state)
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: state.product.symbolName)
                        .foregroundStyle(state.product.color)
                    if let platform = state.platform {
                        Text(platform).font(.caption.weight(.bold)).monospacedDigit()
                    }
                }
            } compactTrailing: {
                Text(timerInterval: Date.now...max(state.expectedTime, .now), countsDown: true)
                    .monospacedDigit()
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.delayMinutes > 0 ? delayColor(state.delayMinutes) : .white)
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: state.product.symbolName)
                    .foregroundStyle(state.product.color)
            }
            .keylineTint(state.product.color)
        }
    }
}

struct LockScreenView: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Line + platform
            HStack(spacing: 8) {
                if state.transfer != nil {
                    Label("Umstieg in \(state.nextStopName)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                } else {
                    ProductBadge(state: state, compact: true)
                    Spacer(minLength: 4)
                    if let platform = state.platform {
                        PlatformChip(platform: platform)
                    }
                }
            }

            if let transfer = state.transfer {
                TransferRowView(transfer: transfer, outgoingLine: state.lineName, outgoingTime: state.expectedTime,
                                outgoingDelayMinutes: state.delayMinutes, outgoingPlatform: state.platform)
                    .foregroundStyle(.white)
            } else {
                // Countdown + time
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(state.isDeparture ? "Abfahrt" : "Ankunft") \(state.nextStopName)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Text(timerInterval: Date.now...max(state.expectedTime, .now), countsDown: true)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state.expectedTime, style: .time)
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        DelayText(state: state).font(.caption2.weight(.semibold))
                    }
                }
            }

            // Progress + route
            VStack(spacing: 4) {
                ProgressView(timerInterval: state.progressStart...state.progressEnd, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(state.product.color == .gray ? .white : state.product.color)
                if let warning = state.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.35))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 4) {
                        Text(attributes.originName).lineLimit(1)
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.right").font(.caption2)
                        Spacer(minLength: 6)
                        Text(attributes.destinationName).lineLimit(1)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        // Enough inset that nothing sits under the card's rounded corners.
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

struct ProductBadge: View {
    let state: TripActivityAttributes.ContentState
    var compact: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.product.symbolName)
            Text(state.lineName).lineLimit(1)
        }
        .font((compact ? Font.caption : Font.subheadline).weight(.bold))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .foregroundStyle(.white)
        .background(state.product.color.gradient, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

struct PlatformChip: View {
    let platform: String

    var body: some View {
        HStack(spacing: 4) {
            Text("Gleis").font(.caption2.weight(.semibold)).opacity(0.75)
            Text(platform).font(.caption.weight(.bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.18), in: .capsule)
    }
}

struct DelayText: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        if state.cancelled {
            Label("Fällt aus", systemImage: "xmark.octagon.fill").foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
        } else if state.delayMinutes > 0 {
            Label("+\(state.delayMinutes) min", systemImage: "clock.badge.exclamationmark.fill")
                .foregroundStyle(delayColor(state.delayMinutes))
        } else {
            Label("pünktlich", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

/// Once a transfer is within 10 minutes: shows the incoming train's arrival and the outgoing train's
/// departure side by side, each with its own delay and platform.
struct TransferRowView: View {
    let transfer: TripActivityAttributes.TransferDetails
    let outgoingLine: String
    let outgoingTime: Date
    let outgoingDelayMinutes: Int
    let outgoingPlatform: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TransferSideView(title: "Ankunft", line: transfer.incomingLine, time: transfer.incomingExpectedArrival,
                              delayMinutes: transfer.incomingDelayMinutes, platform: transfer.incomingPlatform)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
                .opacity(0.5)
                .padding(.top, 14)
            TransferSideView(title: "Abfahrt", line: outgoingLine, time: outgoingTime,
                              delayMinutes: outgoingDelayMinutes, platform: outgoingPlatform, alignment: .trailing)
        }
    }
}

private struct TransferSideView: View {
    let title: String
    let line: String
    let time: Date
    let delayMinutes: Int
    let platform: String?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).opacity(0.6)
            Text(line).font(.caption.weight(.bold)).lineLimit(1)
            HStack(spacing: 4) {
                Text(time, style: .time).font(.caption.monospacedDigit())
                if delayMinutes != 0 {
                    Text(delayMinutes > 0 ? "+\(delayMinutes)" : "\(delayMinutes)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(delayColor(delayMinutes))
                }
                if let platform {
                    Text("Gl. \(platform)").font(.caption2.weight(.bold)).opacity(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

extension TripActivityAttributes.ContentState {
    static let previewDeparture = Self(
        lineName: "ICE 645", nextStopName: "Köln Hbf",
        plannedTime: .now.addingTimeInterval(8 * 60), expectedTime: .now.addingTimeInterval(12 * 60),
        platform: "5", isDeparture: true, cancelled: false,
        progressStart: .now.addingTimeInterval(-20 * 60), progressEnd: .now.addingTimeInterval(12 * 60), product: .highSpeed)

    static let previewRiding = Self(
        lineName: "RE 1", nextStopName: "Düsseldorf Hbf",
        plannedTime: .now.addingTimeInterval(14 * 60), expectedTime: .now.addingTimeInterval(14 * 60),
        platform: "16", isDeparture: false, cancelled: false,
        progressStart: .now.addingTimeInterval(-10 * 60), progressEnd: .now.addingTimeInterval(14 * 60), product: .regionalExpress)

    static let previewTransfer = Self(
        lineName: "ICE 849", nextStopName: "Hannover Hbf",
        plannedTime: .now.addingTimeInterval(8 * 60), expectedTime: .now.addingTimeInterval(8 * 60),
        platform: "11", isDeparture: true, cancelled: false,
        progressStart: .now.addingTimeInterval(-12 * 60), progressEnd: .now.addingTimeInterval(8 * 60), product: .highSpeed,
        transfer: TripActivityAttributes.TransferDetails(
            incomingLine: "ICE 645", incomingPlannedArrival: .now.addingTimeInterval(-1 * 60),
            incomingExpectedArrival: .now.addingTimeInterval(3 * 60), incomingPlatform: "8"))
}

private let previewAttributes = TripActivityAttributes(originName: "Köln Hbf", destinationName: "Berlin Hbf", journeyID: "preview")

#Preview("Sperrbildschirm", as: .content, using: previewAttributes) {
    TripLiveActivity()
} contentStates: {
    TripActivityAttributes.ContentState.previewDeparture
    TripActivityAttributes.ContentState.previewRiding
    TripActivityAttributes.ContentState.previewTransfer
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: previewAttributes) {
    TripLiveActivity()
} contentStates: {
    TripActivityAttributes.ContentState.previewDeparture
}

#Preview("Dynamic Island kompakt", as: .dynamicIsland(.compact), using: previewAttributes) {
    TripLiveActivity()
} contentStates: {
    TripActivityAttributes.ContentState.previewDeparture
}
