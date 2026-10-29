import BetterBahnKit
import LinkPresentation
import SwiftUI
import UIKit

/// The share button in `JourneyDetailView`: uploads the journey for a short link (falls back to the
/// long `betterbahn://share` link offline) and then opens the share sheet. `ShareLink` can't wait for
/// the upload, hence the menu and `UIActivityViewController`. "Ankunft teilen" (#317) shares a link to a
/// web page with the last train's live arrival and platform, for whoever picks the user up.
struct JourneyShareButton: View {
    let journey: Journey
    let title: String
    @State private var isPreparing = false
    /// The link made for the journey's current payload, so sharing again doesn't upload it again.
    @State private var lastLink: (payload: String, url: URL)?
    @State private var arrivalFailed = false

    var body: some View {
        Menu {
            Button("Reise teilen", systemImage: "square.and.arrow.up") {
                Task { await share() }
            }
            if ArrivalShare.canShare(journey) {
                Button {
                    Task { await shareArrival() }
                } label: {
                    Label("Ankunft teilen", systemImage: "figure.wave")
                    Text("Zum Abholen: Ankunftszeit und Gleis live")
                }
            }
        } label: {
            Group {
                if isPreparing {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(width: 40, height: 40)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .resetsWhenMenusCloseOnScroll()
        .disabled(isPreparing)
        .accessibilityLabel("Teilen")
        .alert("Ankunft konnte nicht geteilt werden", isPresented: $arrivalFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Prüf deine Internetverbindung und versuch es noch einmal.")
        }
    }

    private func share() async {
        guard let payload = JourneyShareLink.payload(for: journey) else { return }
        let url: URL
        if let lastLink, lastLink.payload == payload {
            url = lastLink.url
        } else {
            isPreparing = true
            let shared = await ShortShareLinkClient().shareURL(forPayload: payload)
            isPreparing = false
            guard let shared else { return }
            // Only short links are remembered: after a fallback the next tap tries the Worker again.
            if shared.scheme == "https" { lastLink = (payload, shared) }
            url = shared
        }
        ShareSheet.present(JourneyLinkItem(url: url, title: title, icon: .appIcon))
    }

    private func shareArrival() async {
        guard let leg = ArrivalShare.leg(of: journey) else { return }
        isPreparing = true
        defer { isPreparing = false }
        // EVA numbers let the page find the stops in DB's live data; bahn.de's ID of the train is its fallback.
        let bahnDe = BahnDeClient()
        async let journeyId = bahnDe.journeyId(for: leg)
        var evaNumbers: [String: String] = [:]
        for station in ArrivalShare.stationsNeedingEVA(in: journey) {
            if let eva = try? await bahnDe.evaNumber(for: station) { evaNumbers[station.id] = eva }
        }
        guard let arrival = ArrivalShare(journey: journey, journeyId: await journeyId, evaNumbers: evaNumbers) else { return }
        do {
            let url = try await ShortShareLinkClient().arrivalURL(for: journey, arrival: arrival)
            ShareSheet.present(JourneyLinkItem(url: url, title: "Ankunft in \(leg.destination.displayName)", icon: .appIcon))
        } catch {
            arrivalFailed = true
        }
    }
}

/// Presents a `UIActivityViewController` on top of whatever is on screen (sheets included).
@MainActor
enum ShareSheet {
    static func present(_ item: JourneyLinkItem) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        // On the iPad and the Mac the sheet is a popover: centred, as its button isn't known here.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

/// The shared link with the preview the share sheet and Messages show (title and app icon).
final class JourneyLinkItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let icon: UIImage?

    init(url: URL, title: String, icon: UIImage?) {
        self.url = url
        self.title = title
        self.icon = icon
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        if let icon { metadata.iconProvider = NSItemProvider(object: icon) }
        return metadata
    }
}
