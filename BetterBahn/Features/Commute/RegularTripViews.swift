import BetterBahnKit
import SwiftUI

/// Round button next to "Gespeichert" on a saved journey: sets it up as a regular trip (#397), or edits the
/// one it belongs to.
struct RegularTripButton: View {
    let journey: Journey
    @Environment(AppModel.self) private var model
    @State private var editedTrip: RegularTrip?

    var body: some View {
        let existing = model.regularTrip(for: journey)
        Button {
            editedTrip = existing ?? RegularTrip(journey: journey)
        } label: {
            Image(systemName: existing == nil ? "repeat" : "repeat.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .modifier(RoundButtonSurface())
        .tint(.brandText)
        .accessibilityLabel(existing == nil ? "Regelmäßig fahren" : "Regelmäßige Fahrt bearbeiten")
        .sheet(item: $editedTrip) { trip in
            RegularTripEditor(trip: trip, isNew: existing == nil)
        }
    }
}

/// Minimal: a flat circle on the card surface, like the page's other round buttons. Fahrkarte: Liquid Glass (#504).
private struct RoundButtonSurface: ViewModifier {
    @Environment(\.appDesign) private var design

    func body(content: Content) -> some View {
        if design == .fahrkarte {
            content.glassEffect(.regular, in: .circle)
        } else {
            content
                .background(Color.card, in: .circle)
                .overlay { Circle().strokeBorder(Color.hairline, lineWidth: 1) }
                .contentShape(.circle)
        }
    }
}

/// Fahrkarte: the form on the design's warm page instead of the grouped background (#504).
private struct FormBackground: ViewModifier {
    @Environment(\.appDesign) private var design

    func body(content: Content) -> some View {
        if design == .fahrkarte {
            content
                .scrollContentBackground(.hidden)
                .background { AppBackground() }
        } else {
            content
        }
    }
}

/// Days, question time, delay threshold and pause of a regular trip.
struct RegularTripEditor: View {
    @State var trip: RegularTrip
    let isNew: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    @Environment(\.appDesign) private var design

    private var rounded: Font.Design? { design == .fahrkarte ? .rounded : nil }

    private static let leads = [15, 30, 45, 60]
    private static let thresholds = [3, 5, 10, 15]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trip.template.transitLegs.compactMap { $0.line?.displayName }.joined(separator: ", "))
                            .font(.headline)
                        Text(trip.route)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fontDesign(rounded)
                }

                Section {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { day in
                            weekdayButton(day)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } header: {
                    Text("Ich fahre am")
                }

                Section {
                    Picker("Nachfragen", selection: $trip.questionLead) {
                        ForEach(Self.leads, id: \.self) { Text("\($0) Min. vor Abfahrt").tag($0) }
                    }
                    Picker("Verspätung melden ab", selection: $trip.delayThreshold) {
                        ForEach(Self.thresholds, id: \.self) { Text("\($0) Min.").tag($0) }
                    }
                } footer: {
                    Text("An diesen Tagen fragen wir kurz vor der Abfahrt, ob du fährst. Sagst du Ja, wird die Fahrt gespeichert und meldet sich nur bei Problemen.")
                }

                Section {
                    Toggle("Pausieren", isOn: Binding(
                        get: { trip.pausedUntil != nil },
                        set: { trip.pausedUntil = $0 ? Calendar.current.date(byAdding: .day, value: 7, to: .now) : nil }
                    ))
                    .tint(.brandText)
                    if let pausedUntil = trip.pausedUntil {
                        DatePicker("Bis einschließlich", selection: Binding(get: { pausedUntil }, set: { trip.pausedUntil = $0 }),
                                   in: Date.now..., displayedComponents: .date)
                    }
                } footer: {
                    Text("Zum Beispiel im Urlaub: Bis dahin fragen wir nicht.")
                }

                if !isNew {
                    Section {
                        Button("Regelmäßige Fahrt löschen", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .modifier(FormBackground())
            .navigationTitle("Regelmäßig fahren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        model.saveRegularTrip(trip)
                        dismiss()
                    }
                    .disabled(trip.weekdays.isEmpty)
                }
            }
            .confirmationDialog("Regelmäßige Fahrt löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    model.removeRegularTrip(trip)
                    dismiss()
                }
            } message: {
                Text("Schon gespeicherte Fahrten bleiben.")
            }
        }
    }

    private func weekdayButton(_ day: Int) -> some View {
        let selected = trip.weekdays.contains(day)
        return Button {
            if selected { trip.weekdays.remove(day) } else { trip.weekdays.insert(day) }
        } label: {
            Text(RegularTrip.weekdayNames[day - 1])
                .font(.subheadline.weight(.semibold))
                .fontDesign(rounded)
                .frame(width: 38, height: 38)
                .foregroundStyle(selected ? Color.onBrandText : Color.primary)
                .background(selected ? Color.brandText : Color.secondary.opacity(0.15), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Settings → Regelmäßige Fahrten: every regular trip, to edit, pause or delete.
struct RegularTripsView: View {
    @Environment(AppModel.self) private var model
    @State private var editedTrip: RegularTrip?
    @Environment(\.appDesign) private var design

    var body: some View {
        List {
            ForEach(model.regularTrips) { trip in
                Button { editedTrip = trip } label: { row(trip) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for trip in offsets.map({ model.regularTrips[$0] }) { model.removeRegularTrip(trip) }
            }
        }
        .overlay {
            if model.regularTrips.isEmpty {
                ContentUnavailableView("Keine regelmäßigen Fahrten", systemImage: "repeat",
                                       description: Text("Öffne eine gespeicherte Reise und tippe auf „Regelmäßig fahren“."))
            }
        }
        .modifier(FormBackground())
        .navigationTitle("Regelmäßige Fahrten")
        .sheet(item: $editedTrip) { RegularTripEditor(trip: $0, isNew: false) }
    }

    private func row(_ trip: RegularTrip) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trip.summary)
                .font(.subheadline.weight(.semibold))
                .fontDesign(design == .fahrkarte ? .rounded : nil)
            Text(details(trip))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func details(_ trip: RegularTrip) -> String {
        if let pausedUntil = trip.pausedUntil, trip.isPaused(on: .now) {
            return String(localized: "\(trip.weekdaysDescription) · pausiert bis \(pausedUntil.formatted(.dateTime.day().month()))")
        }
        return String(localized: "\(trip.weekdaysDescription) · Frage \(trip.questionLead) Min. vorher")
    }
}

extension View {
    /// "Fährst du heute?" in the app, after the question's notification was tapped (#397).
    func commuteQuestionAlert() -> some View {
        modifier(CommuteQuestionAlert())
    }
}

private struct CommuteQuestionAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let question = model.commuteQuestionToAsk
        let trip = question.flatMap { question in model.regularTrips.first { $0.id == question.tripID } }
        content.alert("Fährst du heute?", isPresented: Binding(get: { question != nil },
                                                               set: { if !$0 { model.commuteQuestionToAsk = nil } })) {
            Button("Ja, ich fahre") {
                guard let question else { return }
                Task { await model.confirmCommute(question, open: true) }
            }
            Button("Heute nicht", role: .cancel) {}
        } message: {
            if let trip, let question, let day = RegularTrip.day(forKey: question.dayKey), let departure = trip.departure(on: day) {
                Text(trip.questionBody(departure: departure))
            }
        }
    }
}
