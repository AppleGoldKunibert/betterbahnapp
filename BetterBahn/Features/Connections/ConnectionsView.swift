import BetterBahnKit
import SwiftUI

struct ConnectionSearch: Hashable {
    var from: Station
    var to: Station
    var date: Date
    var isArrival: Bool
    var onlyBC100: Bool
}

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var from: Station?
    @State private var to: Station?
    @State private var date = Date.now
    @State private var useNow = true
    @State private var isArrival = false
    @State private var onlyBC100 = false
    @FocusState private var focused: Field?
    @State private var path: [ConnectionSearch] = []
    @State private var swapRotation = 0.0

    enum Field: Hashable {
        case from, to
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
                    NavigationLink {
                        PastTripsView()
                    } label: {
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
            .navigationDestination(for: ConnectionSearch.self) { JourneyResultsView(search: $0) }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { onlyBC100 = model.settings.onlyBC100ByDefault }
        }
    }

    // MARK: Route

    private var routeCard: some View {
        Card(padding: 0) {
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    StationInput(label: "Start", placeholder: "Von wo?", systemImage: "circle.circle.fill",
                                 iconColor: .primary, station: $from, focus: $focused, focusValue: .from)
                    Divider().padding(.leading, 54).padding(.trailing, focused == .from || focused == .to ? 0 : 72)
                    StationInput(label: "Ziel", placeholder: "Wohin?", systemImage: "mappin.circle.fill",
                                 station: $to, focus: $focused, focusValue: .to)
                }

                if focused != .from, focused != .to {
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
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
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

                    Spacer()

                    TimeSelector(date: $date, useNow: $useNow)
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
        .disabled(from == nil || to == nil)
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
        model.remember(from: from, to: to)
        path.append(ConnectionSearch(from: from, to: to, date: useNow ? .now : date, isArrival: isArrival,
                                     onlyBC100: onlyBC100))
    }
}

#Preview {
    ConnectionsView()
        .environment(AppModel())
}
