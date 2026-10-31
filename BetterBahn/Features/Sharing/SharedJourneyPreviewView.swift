import BetterBahnKit
import SwiftUI

/// Shown when the app is opened via a `betterbahn://share` link from another user (or with a
/// connection shared from the DB Navigator / bahn.de, see `ImportedJourneyView`), so the received
/// journey can be reviewed before it's added to "Meine Reisen".
struct SharedJourneyPreviewView: View {
    let journey: Journey
    var note: LocalizedStringKey = "Von einem anderen Nutzer geteilt"
    var noteIcon = "person.2.wave.2.fill"
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    noteLabel
                    JourneyCard(journey: journey)
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .readableWidth()
            }
            .background { AppBackground() }
            .navigationTitle("Geteilte Reise")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { saved = model.isSaved(journey) }
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
