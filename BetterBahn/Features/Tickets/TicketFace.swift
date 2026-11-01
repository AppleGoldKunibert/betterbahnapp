import BetterBahnKit
import SwiftUI
import UIKit

/// One line of a ticket's details: "Klasse" – "2. Klasse".
struct TicketDetail {
    let label: String
    let value: String
}

/// A ticket or pass ready for a ticket check (#504): its name and route, notes, the barcode and the details.
/// Minimal shows the barcode on its own and the details in a card below; Fahrkarte draws one ticket, the
/// barcode between two perforations and the details as small capitals above their values.
struct TicketFace<Notes: View, Code: View>: View {
    let title: String
    var subtitle: String?
    let details: [TicketDetail]
    /// False when there is nothing to show between the perforations (no barcode could be drawn).
    var hasCode = true
    @ViewBuilder var notes: Notes
    @ViewBuilder var code: Code

    @Environment(\.appDesign) private var design
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if design == .fahrkarte {
            VStack(alignment: .leading, spacing: 16) {
                notes
                ticket
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                header
                notes
                code
                if !details.isEmpty {
                    Card { detailList }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.bold))
                .fontDesign(design == .fahrkarte ? .rounded : nil)
            if let subtitle {
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Fahrkarte

    private var ticket: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            if hasCode {
                TicketPerforation()
                code
                    .padding(16)
            }
            if !details.isEmpty {
                TicketPerforation()
                detailGrid
                    .padding(20)
            }
        }
        .ticketBackground()
        .environment(\.cardSurface, Color.ticket)
    }

    /// Two columns of label over value; one at the large accessibility sizes.
    private var detailGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            // By position: two details can read the same (two seats alike).
            ForEach(details.indices, id: \.self) { index in
                let detail = details[index]
                VStack(alignment: .leading, spacing: 4) {
                    TicketFieldLabel(title: detail.label)
                    Text(detail.value)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Minimal

    private var detailList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(details.indices, id: \.self) { index in
                let detail = details[index]
                LabeledContent(detail.label) {
                    Text(detail.value).multilineTextAlignment(.trailing)
                }
            }
        }
        .font(.subheadline)
    }
}

/// The barcode on white, as scanners need it.
struct TicketBarcode: View {
    let image: UIImage
    @Environment(\.appDesign) private var design

    var body: some View {
        // On the ticket the code sits inside the ticket's frame, so it needs less margin and a smaller radius.
        let inTicket = design == .fahrkarte
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .padding(inTicket ? 16 : 20)
            .frame(maxWidth: .infinity)
            .background(.white, in: .rect(cornerRadius: inTicket ? 14 : 22, style: .continuous))
            .overlay {
                if inTicket {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1)
                }
            }
            .accessibilityLabel("Ticket-Barcode")
    }
}

/// A short note on the ticket page in a softly tinted box ("Abgelaufen", "Zugbindung aufgehoben").
struct TicketNote: View {
    let text: String
    let systemImage: String
    /// Semantic color of the note; nil for a neutral one.
    var color: Color?
    /// Bold text in the note's color, for what the traveller must not miss.
    var emphasized = false

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(emphasized ? .subheadline.weight(.semibold) : .callout)
            .foregroundStyle(emphasized ? (color ?? .primary) : .primary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((color ?? .secondary).opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }
}
