import BetterBahnKit
import CoreImage.CIFilterBuiltins
import PassKit
import PDFKit
import SwiftUI

/// The tickets of a saved journey, ready for a ticket check: barcode as large as possible with the
/// screen at full brightness, plus the PDF and "Add to Apple Wallet".
struct TicketView: View {
    let tickets: [SavedTicket]
    /// The saved journey, for the "Zugbindung aufgehoben" note.
    var journey: Journey?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(tickets) { saved in
                    ScrollView {
                        TicketPage(ticket: saved.ticket, journey: journey)
                            .padding()
                    }
                    .tag(Optional(saved.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: tickets.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background { AppBackground() }
            .navigationTitle(tickets.count > 1 ? "Tickets" : "Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .fullBrightness()
    }
}

private struct TicketPage: View {
    let ticket: DBTicket
    let journey: Journey?
    @State private var showPDF = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.offerName).font(.title2.weight(.bold))
                Text(ticket.routeDescription).font(.headline).foregroundStyle(.secondary)
            }

            if ticket.isPartnerDocument {
                partnerNotice
            } else if ticket.isReservationOnly {
                Label("Nur Sitzplatzreservierung. Deine Fahrkarte (z. B. BahnCard 100 oder Ticket) zeigst du bei der Kontrolle separat vor.",
                      systemImage: "carseat.right.fill")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
            } else {
                barcode
            }

            if ticket.isTrainBound, let journey, Self.trainBindingLifted(journey) {
                Label("Zugbindung aufgehoben: Bei mindestens 20 Minuten erwarteter Verspätung am Ziel darfst du auch andere Züge nehmen.",
                      systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.punctual)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.punctual.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
            }

            Card { details }

            if !ticket.isPartnerDocument {
                if TicketStore.pdf(for: ticket.id) != nil {
                    Button { showPDF = true } label: {
                        Label("PDF anzeigen", systemImage: "doc.richtext")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                AddToWalletButton(payload: WalletPassPayload(ticket: ticket))
            }
        }
        .sheet(isPresented: $showPDF) {
            NavigationStack {
                PDFKitView(data: TicketStore.pdf(for: ticket.id))
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Ticket-PDF")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showPDF = false }
                        }
                    }
            }
        }
    }

    /// DB lifts the train binding when the expected delay at the destination is 20 minutes or more,
    /// or a connection is missed.
    static func trainBindingLifted(_ journey: Journey) -> Bool {
        if (journey.arrival?.delayMinutes ?? 0) >= 20 { return true }
        return journey.connectionIssues().contains(where: \.isBlocking)
    }

    @ViewBuilder private var barcode: some View {
        if let image = ticket.barcode?.uiImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(.white, in: .rect(cornerRadius: 22, style: .continuous))
                .accessibilityLabel("Ticket-Barcode")
        } else {
            Label("Auf dem Ticket-PDF wurde kein Barcode gefunden. Zeig bei der Kontrolle das PDF vor.",
                  systemImage: "barcode.viewfinder")
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.slightDelay.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    private var partnerNotice: some View {
        Label("Dieses Ticket stellt \(ticket.issuer?.capitalized ?? "ein Partner der Bahn") selbst aus. Du findest es in der Buchungsbestätigung oder auf bahn.de.",
              systemImage: "info.circle.fill")
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let travelClass = ticket.classDescription {
                LabeledContent("Klasse", value: travelClass)
            }
            if !ticket.travellers.isEmpty {
                LabeledContent("Reisende") {
                    Text(ticket.travellers.map(\.displayName).joined(separator: "\n")).multilineTextAlignment(.trailing)
                }
            }
            if let from = ticket.validFrom, let until = ticket.validUntil {
                LabeledContent("Gültig") {
                    Text("\(from.formatted(date: .abbreviated, time: .shortened)) –\n\(until.formatted(date: .abbreviated, time: .shortened))")
                        .multilineTextAlignment(.trailing)
                }
            }
            if !ticket.legs.isEmpty {
                LabeledContent(ticket.isTrainBound ? "Zugbindung" : "Züge") {
                    Text(ticket.legs.map { "\($0.displayName) · \($0.departure.formatted(date: .omitted, time: .shortened))" }
                        .joined(separator: "\n"))
                        .multilineTextAlignment(.trailing)
                }
            }
            ForEach(ticket.seats.map(SeatReservation.init)) { reservation in
                LabeledContent("Sitzplatz") {
                    Text("\(reservation.trainName)\n\(reservation.description)").multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Auftragsnummer", value: ticket.orderNumber)
        }
        .font(.subheadline)
    }

}

extension DBTicket.Barcode {
    /// The code as cut out of DB's PDF or a screenshot; if only its bytes are known, the same bytes
    /// drawn again.
    var uiImage: UIImage? {
        if let image, let uiImage = UIImage(data: image) { return uiImage }
        guard let payload else { return nil }
        let filter = CIFilter.aztecCodeGenerator()
        filter.message = payload
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Adds a ticket or pass to Apple Wallet. The pass is signed by the `Cloudflare/pass-signer` Worker
/// and carries the original barcode bytes; nil (no readable barcode) shows nothing.
struct AddToWalletButton: View {
    let payload: WalletPassPayload?
    @State private var pass: PKPass?
    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        if PKAddPassesViewController.canAddPasses(), let payload {
            VStack(spacing: 8) {
                WalletButton { Task { await add(payload) } }
                    .frame(height: 50)
                    .disabled(isLoading)
                    .overlay { if isLoading { ProgressView() } }
                if let error { ErrorBanner(error: error) }
            }
            .sheet(item: $pass) { AddPassSheet(pass: $0).ignoresSafeArea() }
        }
    }

    private func add(_ payload: WalletPassPayload) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await WalletPassClient().signedPass(payload)
            pass = try PKPass(data: data)
            error = nil
        } catch {
            self.error = error
        }
    }
}

extension PKPass: @retroactive Identifiable {
    public var id: String { serialNumber }
}

private struct WalletButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> PKAddPassButton {
        let button = PKAddPassButton(addPassButtonStyle: .black)
        button.addAction(UIAction { _ in context.coordinator.action() }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: PKAddPassButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

private struct AddPassSheet: UIViewControllerRepresentable {
    let pass: PKPass

    func makeUIViewController(context: Context) -> UIViewController {
        PKAddPassesViewController(pass: pass) ?? UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct PDFKitView: UIViewRepresentable {
    let data: Data?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = data.flatMap(PDFDocument.init(data:))
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

private struct FullBrightness: ViewModifier {
    @State private var previous: CGFloat?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let screen = Self.screen else { return }
                previous = screen.brightness
                screen.brightness = 1
            }
            .onDisappear {
                if let previous { Self.screen?.brightness = previous }
            }
    }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
}

extension View {
    /// Turns the screen up to full brightness while shown (for scanning a barcode).
    func fullBrightness() -> some View { modifier(FullBrightness()) }
}
