import BetterBahnKit
import SwiftUI

/// Adds a stop the train made outside its timetable – e.g. the doors were opened at a station
/// during a disruption so passengers could change trains – so the exit can be moved there (#207).
struct ManualStopSheet: View {
    /// The train's departure where the user boarded; the stop can't be before it.
    let earliest: Date
    let onAdd: (Station, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var station: Station?
    @State private var time: Date
    @FocusState private var focused: Field?

    enum Field: Hashable { case station }

    init(earliest: Date, onAdd: @escaping (Station, Date) -> Void) {
        self.earliest = earliest
        self.onAdd = onAdd
        _time = State(initialValue: max(.now, earliest))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Card(padding: 0) {
                        StationInput(label: "Halt", placeholder: "Wo hält der Zug?", systemImage: "mappin.circle.fill",
                                     station: $station, focus: $focused, focusValue: .station)
                            .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    }
                    Card {
                        DatePicker(selection: $time, in: earliest..., displayedComponents: .hourAndMinute) {
                            OptionLabel(title: "Ankunft", subtitle: "Wann der Zug dort hält", icon: "clock")
                        }
                    }
                    Text("Für Halte, die nicht im Fahrplan stehen, z. B. wenn bei einer Störung die Türen geöffnet werden. Der Halt wird nach der Ankunftszeit in die Halteliste einsortiert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background { AppBackground() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Halt hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen", systemImage: "checkmark") {
                        guard let station else { return }
                        onAdd(station, time)
                        dismiss()
                    }
                    .disabled(station == nil)
                }
            }
        }
    }
}
