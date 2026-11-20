import BetterBahnKit
import SwiftUI

/// Shown when the app is opened via a `betterbahn://share` link from another user (or with a
/// connection shared from the DB Navigator / bahn.de, see `ImportedJourneyView`), so the received
/// journey can be reviewed before it's added to "Meine Reisen". Tapping the journey opens it as after a
/// search (stops, live data, map), and "Auf Karte zeigen" shows its route (#573).
struct SharedJourneyPreviewView: View {
    let journey: Journey
    var note: LocalizedStringKey = "Von einem anderen Nutzer geteilt"
    var noteIcon = "person.2.wave.2.fill"
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @State private var saved = false
    @State private var showMap = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    noteLabel
                    if let destination {
                        NavigationLink(value: ConnectionsRoute.journey(JourneyRoute(journey: journey, finalDestination: destination))) {
                            JourneyCard(journey: journey)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Zeigt die ganze Reise mit allen Halten")
                        Button {
                            showMap = true
                        } label: {
                            Label("Auf Karte zeigen", systemImage: "map.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .pageButtonStyle()
                    } else {
                        JourneyCard(journey: journey)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .readableWidth()
            }
            .background { AppBackground() }
            .navigationTitle("Geteilte Reise")
            .navigationBarTitleDisplayMode(.inline)
            // Also when coming back from the journey, where it may have been saved.
            .onAppear { saved = model.isSaved(journey) }
            .navigationDestination(for: ConnectionsRoute.self) { route in
                // The journey and, once saved and changed, its older plans.
                switch route {
                case .journey(let shown):
                    JourneyDetailView(journey: shown.journey, finalDestination: shown.finalDestination,
                                      readOnly: shown.readOnly, title: shown.title, search: shown.search)
                default:
                    EmptyView()
                }
            }
            .sheet(isPresented: $showMap) {
                if let destination { JourneyMapView(journey: journey, finalDestination: destination) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.save(journey)
                    saved = true
                } label: {
                    Label(saved ? "Reise gespeichert" : "Reise speichern",
                          systemImage: saved ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentTransition(.symbolEffect(.replace))
                }
                .pageButtonStyle(.prominent)
                .tint(saved ? Color.punctual : Color.brand)
                .controlSize(.large)
                .disabled(saved)
                .sensoryFeedback(.success, trigger: saved)
                .padding()
                .readableWidth()
            }
        }
    }

    private var destination: Station? { journey.legs.last?.destination }

    /// Where the journey comes from. Fahrkarte: a small label in capitals, like on a ticket.
    @ViewBuilder
    private var noteLabel: some View {
        if design == .fahrkarte {
            Label(note, systemImage: noteIcon)
                .font(.caption.weight(.semibold))
                .fontDesign(.rounded)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else {
            Label(note, systemImage: noteIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}
