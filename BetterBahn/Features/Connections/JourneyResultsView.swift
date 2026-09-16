import BetterBahnKit
import SwiftUI

struct JourneyResultsView: View {
    let search: ConnectionSearch

    @Environment(AppModel.self) private var model
    @State private var journeys: [Journey] = []
    @State private var earlierCursor: String?
    @State private var laterCursor: String?
    @State private var hiddenCount = 0
    @State private var source: DataSource?
    @State private var isLoading = false
    @State private var loadingMore = false
    @State private var error: Error?
    @State private var showTrainSheet = false
    @State private var forcedTrain: String?
    @State private var forcedJourney: Journey?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                header

                if let error {
                    ErrorBanner(error: error)
                }

                trainButton

                if let forcedJourney, let forcedTrain {
                    SectionHeader(title: "Mit \(forcedTrain)", systemImage: "pin.fill")
                    NavigationLink {
                        JourneyDetailView(journey: forcedJourney, finalDestination: search.to)
                    } label: {
                        JourneyCard(journey: forcedJourney)
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Color.brand, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    SectionHeader(title: "Alle Verbindungen", systemImage: "list.bullet")
                        .padding(.top, 6)
                }

                if earlierCursor != nil {
                    pageButton("Frühere Verbindungen", systemImage: "chevron.up") {
                        await load(cursor: earlierCursor, prepend: true)
                    }
                }

                ForEach(journeys) { journey in
                    NavigationLink {
                        JourneyDetailView(journey: journey, finalDestination: search.to)
                    } label: {
                        JourneyCard(journey: journey)
                    }
                    .buttonStyle(.plain)
                }

                if laterCursor != nil {
                    pageButton("Spätere Verbindungen", systemImage: "chevron.down") {
                        await load(cursor: laterCursor, prepend: false)
                    }
                }

                VStack(spacing: 8) {
                    if hiddenCount > 0 {
                        InfoChip(text: "\(hiddenCount) ohne BC100-Gültigkeit ausgeblendet", systemImage: "eye.slash.fill")
                    }
                    if source == .transitous {
                        SourceNotice()
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .tabBarSafePadding()
        .background { AppBackground() }
        .overlay {
            if isLoading, journeys.isEmpty {
                ProgressView("Suche Verbindungen …")
            } else if !isLoading, journeys.isEmpty, error == nil {
                ContentUnavailableView("Keine Verbindungen", systemImage: "tram.fill",
                                       description: Text("Versuche eine andere Uhrzeit oder schalte Filter aus."))
            }
        }
        .navigationTitle("Verbindungen")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTrainSheet) {
            TrainNumberSheet(search: search, suggestions: trainSuggestions) { name, journey in
                withAnimation(.snappy) {
                    forcedTrain = name
                    forcedJourney = journey
                }
            }
        }
        .task { await load(cursor: nil, prepend: false) }
        .refreshable { await load(cursor: nil, prepend: false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(search.from.name).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(search.to.name).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                InfoChip(text: search.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                         systemImage: search.isArrival ? "arrow.down.right" : "arrow.up.right")
                if search.onlyBC100 {
                    InfoChip(text: "BC100", systemImage: "creditcard.fill", tint: .brand)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private var trainButton: some View {
        HStack(spacing: 10) {
            Button {
                showTrainSheet = true
            } label: {
                Label(forcedTrain.map { "Zug: \($0)" } ?? "Bestimmten Zug wählen", systemImage: "number")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(.brand)

            if forcedTrain != nil {
                Button {
                    withAnimation(.snappy) {
                        forcedTrain = nil
                        forcedJourney = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Zug entfernen")
            }
        }
    }

    /// Long-distance trains from the loaded results, as quick picks.
    private var trainSuggestions: [String] {
        var names: [String] = []
        for leg in journeys.flatMap(\.transitLegs) where leg.line?.product.isTrain == true {
            if let name = leg.line?.name, !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(12))
    }

    private func pageButton(_ title: String, systemImage: String, action: @escaping () async -> Void) -> some View {
        Button {
            loadingMore = true
            Task {
                await action()
                loadingMore = false
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(loadingMore)
    }

    private func load(cursor: String?, prepend: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await model.provider.journeys(JourneyQuery(
                from: search.from, to: search.to, date: search.date, isArrival: search.isArrival, cursor: cursor))
            var result = page.journeys
            if search.onlyBC100 {
                let rules = model.bc100Rules
                let before = result.count
                result = result.filter(rules.isValid)
                hiddenCount += before - result.count
            }
            source = page.source
            if cursor == nil {
                journeys = result
                earlierCursor = page.earlierCursor
                laterCursor = page.laterCursor
            } else if prepend {
                journeys = result + journeys
                earlierCursor = page.earlierCursor
            } else {
                journeys += result
                laterCursor = page.laterCursor
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }
}

struct JourneyCard: View {
    let journey: Journey

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    if let departure = journey.departure {
                        TimeStack(time: departure, cancelled: journey.isCancelled, font: .title2.weight(.bold))
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        if let duration = journey.duration {
                            Text(duration.compactDuration)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let arrival = journey.arrival {
                        TimeStack(time: arrival, cancelled: journey.isCancelled, alignment: .trailing, font: .title2.weight(.bold))
                    }
                }

                JourneySegmentBar(journey: journey)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(journey.transitLegs.enumerated()), id: \.element.id) { index, leg in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            LineBadge(line: leg.line)
                        }
                    }
                }
                .scrollClipDisabled()

                HStack(spacing: 8) {
                    InfoChip(text: journey.transfers == 0 ? "Direkt" : "\(journey.transfers) Umstieg\(journey.transfers == 1 ? "" : "e")",
                             systemImage: journey.transfers == 0 ? "arrow.right" : "arrow.triangle.swap")
                    if let platform = journey.transitLegs.first?.departurePlatform?.best {
                        InfoChip(text: "Gleis \(platform)", systemImage: "signpost.right.fill",
                                 tint: journey.transitLegs.first?.departurePlatform?.hasChanged == true ? .heavyDelay : .secondary)
                    }
                    Spacer()
                    if journey.isCancelled {
                        InfoChip(text: "Fällt aus", systemImage: "xmark.octagon.fill", tint: .heavyDelay)
                    } else if journey.connectionIssues().contains(where: \.isBlocking) {
                        InfoChip(text: "Anschluss weg", systemImage: "exclamationmark.triangle.fill", tint: .heavyDelay)
                    } else if !journey.connectionIssues().isEmpty {
                        InfoChip(text: "Knapp", systemImage: "exclamationmark.triangle.fill", tint: .slightDelay)
                    } else if journey.legs.contains(where: { !$0.remarks.isEmpty }) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.slightDelay)
                    }
                }
            }
        }
    }
}

/// Enter a train number after searching; finds a journey with exactly that train.
struct TrainNumberSheet: View {
    let search: ConnectionSearch
    let suggestions: [String]
    let onFound: (String, Journey) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var train = ""
    @State private var isSearching = false
    @State private var error: Error?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                IconTile(systemImage: "number", color: .brand, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Zugnummer").font(.headline)
                                    Text("\(search.from.name) → \(search.to.name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            TextField("z. B. ICE 423 oder 423", text: $train)
                                .font(.title3.weight(.semibold))
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .focused($focused)
                                .onSubmit(find)
                                .padding(12)
                                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
                        }
                    }

                    if !suggestions.isEmpty {
                        SectionHeader(title: "Züge aus den Ergebnissen", systemImage: "tram.fill")
                        FlowChips(items: suggestions) { name in
                            train = name
                            find()
                        }
                    }

                    if let error {
                        ErrorBanner(error: error)
                    }

                    Button(action: find) {
                        Group {
                            if isSearching {
                                ProgressView()
                            } else {
                                Label("Verbindung mit diesem Zug suchen", systemImage: "magnifyingglass")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .controlSize(.large)
                    .disabled(train.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
                .padding()
            }
            .background { AppBackground() }
            .navigationTitle("Bestimmter Zug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func find() {
        let name = train.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                let journey = try await model.trainPicker.journey(
                    withTrain: name, from: search.from, to: search.to, date: search.date.addingTimeInterval(-30 * 60))
                onFound(journey.transitLegs.first?.line?.name ?? name.uppercased(), journey)
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}

/// Wrapping row of tappable line chips.
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        ChipFlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Text(item)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.card, in: .capsule)
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

#Preview("Ergebniskarten") {
    ScrollView {
        VStack(spacing: 12) {
            JourneyCard(journey: PreviewData.journey)
            JourneyCard(journey: PreviewData.directJourney)
            JourneyCard(journey: PreviewData.regionalJourney)
        }
        .padding()
    }
    .background { AppBackground() }
}
