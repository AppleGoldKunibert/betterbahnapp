import BetterBahnKit
import SwiftUI

/// Settings → Live-Daten-Diagnose: for the last few refreshed journeys, what each live source (Transitous,
/// DB Timetables, bahn.de) answered per train, so a delay that stays stale can be traced to the source that
/// failed or kept an old time. Pull-to-refresh in a journey or the background refresh fills it.
struct RefreshDiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.refreshTraces.isEmpty {
                ContentUnavailableView(
                    "Noch keine Daten",
                    systemImage: "stethoscope",
                    description: Text("Öffne eine gespeicherte Reise und zieh sie nach unten, um sie zu aktualisieren. Danach steht hier, was jede Quelle geliefert hat.")
                )
            } else {
                List {
                    ForEach(model.refreshTraces) { trace in
                        Section {
                            Text(trace.text)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Live-Daten-Diagnose")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.refreshTraces.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: model.refreshTraces.map(\.text).joined(separator: "\n\n———\n\n"))
                }
            }
        }
    }
}

#Preview {
    NavigationStack { RefreshDiagnosticsView() }
        .environment(AppModel())
}
