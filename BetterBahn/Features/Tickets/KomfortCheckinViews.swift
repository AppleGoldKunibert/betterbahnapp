import BetterBahnKit
import SwiftUI
import WebKit

/// "Komfort-Check-in" for a train of a saved ticket (#605), in the ticket and the journey's train card:
/// shown from when bahn.de opens the check-in until the train arrives, then "Eingecheckt: Wagen …".
struct KomfortCheckinRow: View {
    let target: KomfortCheckinTarget

    @Environment(AppModel.self) private var model
    @Environment(\.appDesign) private var design
    @State private var showsSheet = false

    var body: some View {
        let current = model.current(target)
        TimelineView(.everyMinute) { context in
            if current.leg.isOpen(at: context.date) {
                row(current, now: context.date)
            }
        }
        .sheet(isPresented: $showsSheet) { KomfortCheckinView(target: current) }
    }

    private func row(_ current: KomfortCheckinTarget, now: Date) -> some View {
        let status = current.leg.status
        return HStack(spacing: 10) {
            Image(systemName: status.isCheckedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status.isCheckedIn ? Color.punctual : Color.brandText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(status))
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(design == .fahrkarte ? .rounded : nil)
                if !status.isCheckedIn {
                    Text("Check dich ein, dann wird dein Ticket meist nicht mehr kontrolliert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !status.isCheckedIn {
                Button("Einchecken") { showsSheet = true }
                    .font(.caption.weight(.semibold))
                    .compactActionStyle()
            } else if current.leg.canChangeSeat(at: now) {
                Button("Umchecken") { showsSheet = true }
                    .font(.caption.weight(.semibold))
                    .compactActionStyle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(design == .fahrkarte ? Color.clear : Color.brand.opacity(0.1),
                    in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            if design == .fahrkarte {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1)
            }
        }
    }

    private func title(_ status: KomfortCheckin.Status) -> String {
        guard status.isCheckedIn else { return String(localized: "Komfort-Check-in") }
        let seats = status.checkedInSeats.map(\.description).joined(separator: "; ")
        return seats.isEmpty ? String(localized: "Eingecheckt") : String(localized: "Eingecheckt: \(seats)")
    }
}

/// Checks in on bahn.de (#605): like `TicketLookupView`, the order is opened in bahn.de's own page
/// in a hidden web view, and the check-in is sent from there with the page's session.
struct KomfortCheckinView: View {
    let target: KomfortCheckinTarget

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDesign) private var design
    @State private var page = WebPage()
    @State private var coach = ""
    @State private var seat = ""
    @State private var lastName = ""
    @State private var bahnCard = ""
    @State private var state: LoadState = .idle
    @State private var isCheckingIn = false
    @State private var prefilledFromReservation = false

    enum LoadState: Equatable {
        case idle
        case working
        /// bahn.de wants something the app can't answer (e.g. a captcha): its page is shown.
        case needsPage
        case failed(String)
        case done(KomfortCheckin.Status)
    }

    private var isChange: Bool { target.leg.status.isCheckedIn }
    private var needsBahnCard: Bool { target.ticket.ticket.needsBahnCardForCheckin }

    var body: some View {
        NavigationStack {
            ZStack {
                // Kept in the view hierarchy so the page runs like a visible one; only shown when needed.
                WebView(page)
                    .opacity(state == .needsPage ? 1 : 0)
                    .allowsHitTesting(state == .needsPage)
                if state != .needsPage { form }
            }
            .safeAreaInset(edge: .top) {
                if state == .needsPage {
                    Label("bahn.de möchte die Suche bestätigen. Bitte schließ sie auf der Seite ab, danach checkt BetterBahn dich ein.",
                          systemImage: "hand.raised.fill")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
            .navigationTitle(isChange ? String(localized: "Umchecken") : String(localized: "Komfort-Check-in"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = state {
                        Button("Fertig") { dismiss() }
                    } else {
                        Button("Abbrechen", role: .cancel) { dismiss() }
                    }
                }
            }
            .task {
                prefill()
                page.load(URLRequest(url: DBOrderPage.searchURL))
            }
            .onChange(of: page.url) { _, url in
                guard DBOrderPage.orderNumber(in: url) != nil, !isCheckingIn,
                      state == .working || state == .needsPage else { return }
                Task { await checkIn() }
            }
        }
    }

    private var canSubmit: Bool {
        !coach.trimmed.isEmpty && !seat.trimmed.isEmpty && !lastName.trimmed.isEmpty
            && (!needsBahnCard || KomfortCheckin.isValidBahnCardNumber(bahnCard))
            && state != .working
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("Zug", value: target.leg.trainName)
                if isChange, !target.leg.status.checkedInSeats.isEmpty {
                    LabeledContent("Eingecheckt", value: target.leg.status.checkedInSeats.map(\.description).joined(separator: "; "))
                }
            }

            if case .done(let status) = state {
                Section {
                    Label(status.checkedInSeats.isEmpty
                          ? String(localized: "Du bist eingecheckt.")
                          : String(localized: "Du bist eingecheckt: \(status.checkedInSeats.map(\.description).joined(separator: "; "))."),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.punctual)
                } footer: {
                    if status.spotCheck == true {
                        Text("Dein Ticket kann trotzdem stichprobenartig kontrolliert werden.")
                    }
                }
            } else {
                Section {
                    TextField("Wagen", text: $coach)
                        .keyboardType(.numberPad)
                    TextField("Platz", text: $seat)
                        .keyboardType(.numberPad)
                } header: {
                    Text(isChange ? String(localized: "Neuer Sitzplatz") : String(localized: "Sitzplatz"))
                } footer: {
                    if prefilledFromReservation {
                        Text("Dein reservierter Platz ist schon eingetragen. Sitzt du woanders, trag diesen Platz ein.")
                    } else {
                        Text("Trag den Platz ein, auf dem du sitzt.")
                    }
                }

                Section {
                    TextField("Nachname der reisenden Person", text: $lastName)
                        .textContentType(.familyName)
                        .autocorrectionDisabled()
                    if needsBahnCard {
                        TextField("BahnCard-Nummer", text: $bahnCard)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                } footer: {
                    Text(needsBahnCard
                         ? String(localized: "Du hast mit BahnCard gebucht, deshalb braucht bahn.de ihre Nummer. Beides bleibt nur auf diesem Gerät.")
                         : String(localized: "Damit öffnet bahn.de deine Buchung. Der Name bleibt nur auf diesem Gerät."))
                }

                if case .failed(let message) = state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.heavyDelay)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if state == .working {
                                ProgressView()
                                Text("Wird eingecheckt …").padding(.leading, 6)
                            } else {
                                Text(isChange ? String(localized: "Umchecken") : String(localized: "Einchecken"))
                                    .font(.headline)
                                    .fontDesign(design == .fahrkarte ? .rounded : nil)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .designedForm()
    }

    /// The seat checked in on, else the reserved one (bahn.de's, else the ticket's), plus the
    /// name and BahnCard number used last time.
    private func prefill() {
        lastName = target.ticket.lastName ?? ""
        bahnCard = TicketStore.bahnCardNumber ?? ""
        let status = target.leg.status
        if let checkedIn = status.checkedInSeats.first {
            (coach, seat) = (checkedIn.coach, checkedIn.seat)
        } else if let reserved = status.reservedSeats.first ?? reservedSeatOnTicket {
            (coach, seat) = (reserved.coach, reserved.seat)
            prefilledFromReservation = true
        }
    }

    private var reservedSeatOnTicket: KomfortCheckin.Seat? {
        target.ticket.ticket.reservedSeat(on: target.leg)
    }

    /// Opens the order on bahn.de's page; `onChange(of: page.url)` checks in once it shows. If
    /// bahn.de neither opens it nor names an error for a while, its page is shown.
    private func submit() async {
        state = .working
        if needsBahnCard { TicketStore.bahnCardNumber = bahnCard.filter(\.isNumber) }
        if page.url?.path().hasPrefix("/buchung/meine-reisen") != true {
            page.load(URLRequest(url: DBOrderPage.searchURL))
        }
        let submitted = await page.submitOrderSearch(orderNumber: target.ticket.ticket.orderNumber, lastName: lastName.trimmed)
        guard submitted else {
            state = .needsPage
            return
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            guard state == .working, !isCheckingIn else { return }
            if let message = await page.orderSearchError() {
                state = .failed(message)
                return
            }
        }
        if state == .working, !isCheckingIn { state = .needsPage }
    }

    /// Sends the check-in from bahn.de's page; the page may still be storing its session when the
    /// order opens, so a missing token is retried briefly.
    private func checkIn() async {
        isCheckingIn = true
        defer { isCheckingIn = false }
        state = .working
        guard let checkin = target.ticket.ticket.komfortCheckin else {
            state = .failed(DBOrderPage.Failure.unreadable.localizedDescription)
            return
        }
        let request = checkin.request(for: target.leg, bundleID: target.ticket.ticket.bundleID,
                                      seats: [KomfortCheckin.Seat(coach: coach.trimmed, seat: seat.trimmed)],
                                      bahnCardNumber: needsBahnCard ? bahnCard : nil,
                                      ticketReservation: reservedSeatOnTicket)
        guard let body = try? request.json() else {
            state = .failed(DBOrderPage.Failure.unreadable.localizedDescription)
            return
        }
        for attempt in 0..<10 {
            do {
                let value = try await page.callJavaScript(DBOrderPage.checkinScript, arguments: ["body": body])
                let status = try DBOrderPage.checkinStatus(from: value)
                model.updateKomfortCheckin(target, status: status, lastName: lastName.trimmed)
                state = .done(status)
                return
            } catch DBOrderPage.Failure.notReady where attempt < 9 {
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                state = .failed(error.localizedDescription)
                // Back to bahn.de's search form for another try.
                page.load(URLRequest(url: DBOrderPage.searchURL))
                return
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
