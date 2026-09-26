import BetterBahnKit
import SwiftUI

/// Text shared into the app from the DB Navigator or bahn.de (via the share extension).
struct DBShareText: Identifiable {
    let id = UUID()
    let text: String
}

/// Looks up a connection shared from the DB Navigator / bahn.de in the app's own timetable data and
/// then shows it like any other shared journey – or says why it couldn't.
struct ImportedJourneyView: View {
    let text: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var journey: Journey?
    @State private var errorMessage: String?

    var body: some View {
        if let journey {
            SharedJourneyPreviewView(journey: journey, note: "Von bahn.de / DB Navigator übernommen",
                                     noteIcon: "square.and.arrow.down.fill")
        } else {
            NavigationStack {
                Group {
                    if let errorMessage {
                        ContentUnavailableView {
                            Label("Verbindung nicht übernommen", systemImage: "exclamationmark.triangle.fill")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Erneut versuchen") { Task { await load() } }
                        }
                    } else {
                        ProgressView("Verbindung wird gesucht …")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { AppBackground() }
                .navigationTitle("Geteilte Reise")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen") { dismiss() }
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            journey = try await model.dbShareImporter.journey(fromShared: text)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
