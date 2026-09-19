import BetterBahnKit
import SwiftUI

/// A journey pushed onto a tab's navigation stack. Pushed by value (instead of an inline
/// `NavigationLink`) so the stack's path knows a journey is open and the tab bar can be hidden
/// from the stack itself — hiding it from inside the pushed view made it come back late after a swipe-back.
struct JourneyRoute: Hashable {
    var journey: Journey
    var finalDestination: Station
    var readOnly = false
    var title = "Reiseplan"
}

enum ConnectionsRoute: Hashable {
    case search(ConnectionSearch)
    case journey(JourneyRoute)
    case pastTrips
}

struct ConnectionSearch: Hashable {
    var from: Station
    var to: Station
    var via: [ViaWaypoint] = []
    var date: Date
    var isArrival: Bool
    var onlyBC100: Bool
}

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var from: Station?
    @State private var to: Station?
    @State private var viaRows: [ViaRow] = []
    @State private var date = Date.now
    @State private var useNow = true
    @State private var isArrival = false
    @State private var onlyBC100 = false
    @FocusState private var focused: Field?
    @State private var path: [ConnectionsRoute] = []
    @State private var swapRotation = 0.0

    /// Up to this many intermediate stops can be added to a single search.
    private static let maxViaPoints = 4

    enum Field: Hashable {
        case from, to, via(UUID)
    }

    /// UI-side row for an in-progress via point: it needs a stable identity before a station has
    /// even been picked, which `ViaWaypoint` (identified by station id) can't provide.
    struct ViaRow: Identifiable {
        let id = UUID()
        var station: Station?
        var minStayMinutes = 0
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 20) {
                    routeCard
                    optionsCard
                    searchButton
                    UpcomingTripsSection()
                    if !model.recentSearches.isEmpty {
                        recentSection
                    }
                    NavigationLink(value: ConnectionsRoute.pastTrips) {
                        Label("Vergangene Fahrten", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .tabBarSafePadding()
            .background { AppBackground() }
            .navigationTitle("Verbindungen")
            .navigationDestination(for: ConnectionsRoute.self) { route in
                switch route {
                case .search(let search):
                    JourneyResultsView(search: search)
                case .journey(let journey):
                    JourneyDetailView(journey: journey.journey, finalDestination: journey.finalDestination,
                                      readOnly: journey.readOnly, title: journey.title)
                case .pastTrips:
                    PastTripsView()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { onlyBC100 = model.settings.onlyBC100ByDefault }
        }
        .toolbar(showsJourney ? .hidden : .automatic, for: .tabBar)
    }

    private var showsJourney: Bool {
        if case .journey = path.last { return true }
        return false
    }

    // MARK: Route

    private var routeCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                StationInput(label: "Start", placeholder: "Von wo?", systemImage: "circle.circle.fill",
                             iconColor: .primary, station: $from, focus: $focused, focusValue: .from)

                // The swap button always sits right below Start, so it never drifts onto (and
                // covers) a via row's own remove button as the card grows with more stops.
                routeDivider(showAdd: viaRows.isEmpty, showSwap: true)

                ForEach($viaRows) { $row in
                    ViaRowView(row: $row, focus: $focused) {
                        withAnimation(.snappy) { viaRows.removeAll { $0.id == row.id } }
                    }
                    routeDivider(showAdd: row.id == viaRows.last?.id, showSwap: false)
                }

                StationInput(label: "Ziel", placeholder: "Wohin?", systemImage: "mappin.circle.fill",
                             station: $to, focus: $focused, focusValue: .to)
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
    }

    /// A divider row between two stops, optionally carrying the leading "add via point" button
    /// and/or the trailing "swap" button (both hidden while any field is focused).
    private func routeDivider(showAdd: Bool, showSwap: Bool) -> some View {
        ZStack {
            Divider().padding(.leading, 54).padding(.trailing, focused == nil && showSwap ? 72 : 0)
            if focused == nil {
                if showAdd, viaRows.count < Self.maxViaPoints {
                    HStack {
                        addViaButton.padding(.leading, 20)
                        Spacer()
                    }
                }
                if showSwap {
                    HStack {
                        Spacer()
                        swapButton
                    }
                }
            }
        }
    }

    private var swapButton: some View {
        Button {
            withAnimation(.spring(duration: 0.4)) {
                swap(&from, &to)
                swapRotation += 180
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.headline)
                .rotationEffect(.degrees(swapRotation))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .padding(.trailing, 14)
        .disabled(from == nil && to == nil)
        .accessibilityLabel("Start und Ziel tauschen")
        .transition(.opacity)
    }

    private var addViaButton: some View {
        Button {
            withAnimation(.snappy) {
                viaRows.append(ViaRow())
            }
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.brand)
        .accessibilityLabel("Zwischenhalt hinzufügen")
    }

    // MARK: Options

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Picker("Zeit", selection: $isArrival) {
                        Label("Abfahrt", systemImage: "arrow.up.right").tag(false)
                        Label("Ankunft", systemImage: "arrow.down.right").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .disabled(!viaRows.isEmpty)

                    Spacer()

                    TimeSelector(date: $date, useNow: $useNow)
                }

                if !viaRows.isEmpty {
                    Label("Mit Zwischenhalten wird immer ab der gewählten Zeit gesucht.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle(isOn: $onlyBC100) {
                    optionLabel("Nur BahnCard 100", subtitle: "FlixTrain & Co. ausblenden", icon: "creditcard.fill", color: .brand)
                }
                .tint(.brand)

            }
        }
    }

    private func optionLabel(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Search

    private var searchButton: some View {
        Button(action: search) {
            Label("Verbindungen suchen", systemImage: "magnifyingglass")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(.brand)
        .controlSize(.large)
        .disabled(from == nil || to == nil || viaRows.contains { $0.station == nil })
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Zuletzt gesucht", systemImage: "clock.arrow.circlepath")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(model.recentSearches.enumerated()), id: \.element.id) { index, recent in
                        if index > 0 { Divider().padding(.leading, 60) }
                        Button {
                            withAnimation {
                                from = recent.from
                                to = recent.to
                                viaRows = []
                            }
                        } label: {
                            HStack(spacing: 14) {
                                IconTile(systemImage: "arrow.triangle.swap", color: .secondary.opacity(0.6), size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recent.from.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.turn.down.right").font(.caption2)
                                        Text(recent.to.name).lineLimit(1)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Entfernen", systemImage: "trash", role: .destructive) {
                                model.recentSearches.removeAll { $0.id == recent.id }
                            }
                        }
                    }
                }
            }
        }
    }

    private func search() {
        guard let from, let to else { return }
        let via = viaRows.compactMap { row in row.station.map { ViaWaypoint(station: $0, minStayMinutes: row.minStayMinutes) } }
        model.remember(from: from, to: to)
        // Via routing only supports "depart at" — an arrival deadline doesn't compose with per-stop minimum stays.
        path.append(.search(ConnectionSearch(from: from, to: to, via: via, date: useNow ? .now : date,
                                     isArrival: via.isEmpty ? isArrival : false, onlyBC100: onlyBC100)))
    }
}

/// One intermediate stop in the route card: a station field plus its minimum-stay control.
private struct ViaRowView: View {
    @Binding var row: ConnectionsView.ViaRow
    let focus: FocusState<ConnectionsView.Field?>.Binding
    let onRemove: () -> Void

    @State private var showStayPopover = false

    var body: some View {
        VStack(spacing: 0) {
            StationInput(label: "Zwischenhalt", placeholder: "Über welchen Ort?", systemImage: "smallcircle.filled.circle",
                         iconColor: .secondary, station: $row.station, focus: focus, focusValue: .via(row.id))

            HStack(spacing: 10) {
                Button {
                    showStayPopover = true
                } label: {
                    Label(row.minStayMinutes > 0 ? "Mind. \(row.minStayMinutes) Min." : "Mindestaufenthalt",
                          systemImage: "clock.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.minStayMinutes > 0 ? Color.brand : Color.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showStayPopover) { stayPopover }

                Spacer()

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Zwischenhalt entfernen")
            }
            .padding(.leading, 54)
            .padding(.trailing, 16)
            .padding(.bottom, 12)
        }
    }

    private var stayPopover: some View {
        VStack(spacing: 14) {
            Text("Mindestaufenthalt in \(row.station?.displayName ?? "diesem Ort")")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Stepper("\(row.minStayMinutes) Minuten", value: $row.minStayMinutes, in: 0...120, step: 5)
                .fixedSize()
            Button("Fertig") { showStayPopover = false }
                .buttonStyle(.glassProminent)
                .tint(.brand)
        }
        .padding()
        .frame(minWidth: 260)
        .presentationCompactAdaptation(.popover)
    }
}

#Preview {
    ConnectionsView()
        .environment(AppModel())
}
