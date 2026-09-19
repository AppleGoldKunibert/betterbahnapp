import BetterBahnKit
import SwiftUI

/// Shown when the app is opened via a `betterbahn://share` link from another user, so the
/// received journey can be reviewed before it's added to "Meine Reisen".
struct SharedJourneyPreviewView: View {
    let journey: Journey
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Label("Von einem anderen Nutzer geteilt", systemImage: "person.2.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    JourneyCard(journey: journey)
                }
                .padding()
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
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .tint(saved ? Color.punctual : Color.brand)
                .controlSize(.large)
                .disabled(saved)
                .sensoryFeedback(.success, trigger: saved)
                .padding()
            }
        }
    }
}
