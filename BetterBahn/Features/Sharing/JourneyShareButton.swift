import BetterBahnKit
import LinkPresentation
import SwiftUI
import UIKit

/// The share button in `JourneyDetailView`: uploads the journey for a short link (falls back to the
/// long `betterbahn://share` link offline) and then opens the share sheet. `ShareLink` can't wait for
/// the upload, hence the button and `UIActivityViewController`.
struct JourneyShareButton: View {
    let journey: Journey
    let title: String
    @State private var isPreparing = false
    /// The link made for the journey's current payload, so sharing again doesn't upload it again.
    @State private var lastLink: (payload: String, url: URL)?

    var body: some View {
        Button {
            Task { await share() }
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
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .disabled(isPreparing)
        .accessibilityLabel("Reise teilen")
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
        controller.popoverPresentationController?.sourceView = top.view
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
