import BetterBahnKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Puts BetterBahn into the share sheet. A connection shared from the DB Navigator or bahn.de is
/// handed over to the app (which looks it up and shows it); anything else gets an error right here.
final class ShareViewController: UIViewController {
    private var host: UIHostingController<ShareStatusView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        show(.loading)
        Task { await handleSharedItems() }
    }

    private func handleSharedItems() async {
        let text = await sharedText()
        guard DBShare.isConnection(text), let url = DBShare.appURL(for: text), openApp(url) else {
            show(.notAConnection)
            return
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Everything shared, in one string: DB Navigator shares the text and its "Verbindung ansehen"
    /// link as separate items, bahn.de (or Safari) sometimes just the link.
    private func sharedText() async -> String {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        var parts: [String] = []
        for item in items {
            if let content = item.attributedContentText?.string, !content.isEmpty { parts.append(content) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await load(URL.self, from: provider) {
                    parts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let string = await load(String.self, from: provider) {
                    parts.append(string)
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    private func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { @Sendable value, _ in continuation.resume(returning: value) }
        }
    }

    /// Share extensions can't open URLs through their extension context, so this goes through the
    /// hosting app's `UIApplication` found up the responder chain instead.
    private func openApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func show(_ state: ShareStatusView.State) {
        let view = ShareStatusView(state: state) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        if let host {
            host.rootView = view
            return
        }
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
    }
}

struct ShareStatusView: View {
    enum State {
        case loading
        case notAConnection
    }

    let state: State
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView()
                case .notAConnection:
                    ContentUnavailableView {
                        Label("Keine Verbindung", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text("BetterBahn kann nur Verbindungen öffnen, die aus dem DB Navigator oder von bahn.de geteilt wurden.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("BetterBahn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", action: close)
                }
            }
        }
    }
}
