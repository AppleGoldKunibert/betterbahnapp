import BetterBahnKit
import Foundation
import WebKit

/// Loads vagonweb.cz pages in a hidden web view, for when Cloudflare's bot check in front of
/// vagonweb turns the plain request away (`VagonwebClient.browserLoader`): a real browser engine
/// passes the check, and the cookie it gets keeps later loads quick. One page at a time.
@MainActor
final class VagonwebBrowser {
    static let shared = VagonwebBrowser()

    /// The load before this one; each waits for the previous to finish.
    private var previous: Task<Void, Never>?

    func html(at url: URL) async throws -> String {
        let before = previous
        let load = Task { () async throws -> String in
            await before?.value
            return try await Self.load(url)
        }
        previous = Task { _ = try? await load.value }
        return try await load.value
    }

    /// A fresh page per load, so nothing of the previous train's page can be read by mistake.
    private static func load(_ url: URL) async throws -> String {
        let page = WebPage()
        page.load(URLRequest(url: url))
        let deadline = Date.now.addingTimeInterval(25)
        while Date.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if let html = try? await page.callJavaScript(htmlScript) as? String, !VagonwebClient.isChallenge(html) {
                return html
            }
        }
        // Still Cloudflare's check (or no answer): counts as blocked, so vagonweb isn't asked for a while.
        throw TransitError.rateLimited
    }

    /// The page's HTML once vagonweb's own page has loaded (it has the `stred0` content column,
    /// Cloudflare's check doesn't).
    private static let htmlScript = """
        return document.readyState === 'complete' && document.getElementById('stred0')
            ? document.documentElement.outerHTML : null
        """
}
