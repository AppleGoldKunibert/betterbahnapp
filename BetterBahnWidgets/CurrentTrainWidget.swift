import BetterBahnKit
import SwiftUI
import WidgetKit

struct CurrentTrainProvider: TimelineProvider {
    func placeholder(in context: Context) -> JourneyWidgetEntry {
        JourneyWidgetEntry(date: .now, state: .preview, journeyID: nil, updatedAt: .now, countdown: .nextConnection)
    }

    func getSnapshot(in context: Context, completion: @escaping (JourneyWidgetEntry) -> Void) {
        let entries = JourneyWidgetProvider.entries(countdown: .nextConnection, now: .now, showsTimer: false)
        completion(context.isPreview && entries.first?.state == nil ? placeholder(in: context) : entries[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JourneyWidgetEntry>) -> Void) {
        let entries = JourneyWidgetProvider.entries(countdown: .nextConnection, now: .now, showsTimer: false)
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// The train ridden now (or boarded next): its next stops with delays and where to get off.
struct CurrentTrainWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.currentTrainWidgetKind, provider: CurrentTrainProvider()) { entry in
            CurrentTrainWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.journeyID.map { LiveActivityLink.url(journeyID: $0) })
        }
        .configurationDisplayName("Aktueller Zug")
        .description("Dein Zug mit den nächsten Halten, Verspätungen und deinem Ausstieg.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CurrentTrainWidgetView: View {
    let entry: JourneyWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state, state.phase != .arrived {
            VStack(alignment: .leading, spacing: 4) {
                header(state)
                Spacer(minLength: 0)
                if state.isWaitingToBoard {
                    departure(state)
                } else if family == .systemMedium {
                    ForEach(state.upcomingStops, id: \.self) { stop in
                        StopRow(name: stop.name, time: stop.time, delay: stop.delayMinutes, cancelled: stop.cancelled)
                    }
                } else if let next = state.upcomingStops.first {
                    StopRow(name: next.name, time: next.time, delay: next.delayMinutes, cancelled: next.cancelled)
                }
                Spacer(minLength: 0)
                exit(state)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "tram.fill").font(.title2).foregroundStyle(.secondary)
                Text(entry.state == nil ? "Keine Reise geplant" : "Angekommen").font(.subheadline.weight(.semibold))
            }
        }
    }

    private func header(_ state: JourneyWidgetState) -> some View {
        HStack(spacing: 6) {
            TrainBadge(name: state.trainName, product: state.product, nightTrain: state.isNightTrain)
            if family == .systemMedium, let direction = state.direction {
                Text("→ \(direction)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            DelayBadge(minutes: state.nextStopDelayMinutes, cancelled: state.cancelled)
        }
    }

    /// Before boarding: when and where the train leaves.
    private func departure(_ state: JourneyWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.phase == .beforeDeparture ? "Nächste Reise" : "Abfahrt")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(state.nextStopName).font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Text(state.nextStopTime, style: .time).font(.caption.weight(.semibold)).monospacedDigit()
                if let platform = state.platform {
                    Text("Gl. \(platform)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Where to get off, highlighted at the bottom.
    private func exit(_ state: JourneyWidgetState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "figure.walk.departure").font(.caption2)
            Text(state.exitName).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            Text(state.exitTime, style: .time).font(.caption.weight(.semibold)).monospacedDigit()
            if let platform = state.exitPlatform, family == .systemMedium {
                Text("Gl. \(platform)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(state.product.color.opacity(0.15), in: .rect(cornerRadius: 6))
    }
}

/// One upcoming stop: name, expected time and delay.
private struct StopRow: View {
    let name: String
    let time: Date
    let delay: Int?
    let cancelled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().frame(width: 5, height: 5).foregroundStyle(.secondary)
            Text(name).font(.caption).lineLimit(1).strikethrough(cancelled)
            Spacer(minLength: 2)
            Text(time, style: .time).font(.caption.weight(.semibold)).monospacedDigit()
            DelayBadge(minutes: delay, cancelled: cancelled)
        }
    }
}

#Preview(as: .systemMedium) {
    CurrentTrainWidget()
} timeline: {
    JourneyWidgetEntry(date: .now, state: .preview, journeyID: nil, updatedAt: .now, countdown: .nextConnection)
}
