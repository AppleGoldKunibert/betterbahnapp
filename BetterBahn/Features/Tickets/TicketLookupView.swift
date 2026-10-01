import BetterBahnKit
import SwiftUI
import WebKit

/// Fetches a ticket by order number and last name.
///
/// bahn.de only answers from its own page in a real browser, so its "Auftragssuche" is loaded in a
/// hidden web view: what the traveller types here is filled into bahn.de's form and submitted there
/// (see `DBOrderPage`). Once bahn.de shows the order, its order data and ticket PDFs are fetched
/// inside the page and saved. If bahn.de asks for more (e.g. a captcha), the page is shown so the
/// traveller can finish there.
struct TicketLookupView: View {
    /// Called with the imported tickets before the sheet closes.
    var onImport: ([SavedTicket]) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = WebPage()
    @State private var orderNumber = ""
    @State private var lastName = ""
    @State private var state: LoadState = .idle
    @State private var isFetching = false
    @FocusState private var focus: Field?

    enum Field { case orderNumber, lastName }

    enum LoadState: Equatable {
        case idle
        case searching
        /// bahn.de wants something the app can't answer (e.g. a captcha): its page is shown.
        case needsPage
        case failed(String)
    }

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
                    Label("bahn.de möchte die Suche bestätigen. Bitte schließ sie auf der Seite ab, danach lädt BetterBahn dein Ticket.",
                          systemImage: "hand.raised.fill")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
            .navigationTitle("Ticket abrufen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
            }
            // Loaded right away, so bahn.de's page is ready by the time the form is filled in.
            .task { page.load(URLRequest(url: DBOrderPage.searchURL)) }
            .onChange(of: page.url) { _, url in
                guard let number = DBOrderPage.orderNumber(in: url), !isFetching else { return }
                Task { await fetch(number) }
            }
        }
    }

    private var canSearch: Bool {
        !orderNumber.trimmingCharacters(in: .whitespaces).isEmpty && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
            && state != .searching
    }

    private var form: some View {
        Form {
            Section {
                TextField("Auftragsnummer", text: $orderNumber)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .orderNumber)
                    .submitLabel(.next)
                    .onSubmit { focus = .lastName }
                TextField("Nachname der reisenden Person", text: $lastName)
                    .textContentType(.familyName)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .lastName)
                    .submitLabel(.search)
                    .onSubmit { if canSearch { Task { await search() } } }
            } footer: {
                Text("Die Auftragsnummer steht in der Buchungsbestätigung und auf dem Ticket unter dem Barcode. Auftragsnummer und Name gehen nur an bahn.de, das Ticket wird nur auf diesem Gerät gespeichert.")
            }

            if case .failed(let message) = state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.heavyDelay)
                }
            }

            Section {
                Button {
                    Task { await search() }
                } label: {
                    HStack {
                        Spacer()
                        if state == .searching {
                            ProgressView()
                            Text("Ticket wird geladen …").padding(.leading, 6)
                        } else {
                            Text("Ticket abrufen").font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(!canSearch)
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .onAppear { focus = .orderNumber }
    }

    /// Fills bahn.de's form and waits for it to open the order (handled in `onChange(of: page.url)`),
    /// an error message, or – after a while without either – shows the page.
    private func search() async {
        focus = nil
        state = .searching
        if page.url?.path().hasPrefix("/buchung/meine-reisen") != true {
            page.load(URLRequest(url: DBOrderPage.searchURL))
        }
        let arguments: [String: Any] = [
            "orderNumber": orderNumber.trimmingCharacters(in: .whitespaces).uppercased(),
            "lastName": lastName.trimmingCharacters(in: .whitespaces),
        ]
        // The page renders its form a moment after loading.
        var submitted = false
        for _ in 0..<30 {
            if let result = try? await page.callJavaScript(DBOrderPage.fillScript, arguments: arguments) as? String,
               result == "submitted" {
                submitted = true
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard submitted else {
            state = .needsPage
            return
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            guard state == .searching, !isFetching else { return }
            if let message = try? await page.callJavaScript(DBOrderPage.errorScript) as? String, !message.isEmpty {
                state = .failed(message)
                return
            }
        }
        if state == .searching, !isFetching { state = .needsPage }
    }

    /// The page may still be storing its session when the URL changes, so a missing token is retried briefly.
    private func fetch(_ number: String) async {
        isFetching = true
        defer { isFetching = false }
        state = .searching
        for attempt in 0..<10 {
            do {
                let value = try await page.callJavaScript(DBOrderPage.fetchScript, arguments: ["orderNumber": number])
                let result = try DBOrderPage.result(from: value)
                let imported = try await model.importTickets(result, orderNumber: number)
                onImport(imported)
                dismiss()
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
