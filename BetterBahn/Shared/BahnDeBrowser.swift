import BetterBahnKit
import Foundation
import os
import WebKit

/// Asks bahn.de's web API from a hidden web view on bahn.de, for when bahn.de's bot protection blocks
/// our shared Worker (`BahnDeBrowserFallback`): a real browser engine on the phone's own connection gets
/// through, like bahn.de in Safari. The page is loaded once and reused for half an hour; each request is
/// a `fetch` inside it, so bahn.de sees the cookies its page set.
@MainActor
final class BahnDeBrowser {
    static let shared = BahnDeBrowser()

    /// Where the hidden page starts: bahn.de's timetable search, the page whose API the app uses.
    private static let startURL = URL(string: "https://www.bahn.de/buchung/fahrplan/suche")!
    private static let pageLifetime: TimeInterval = 30 * 60

    private var page: Task<WebPage, Error>?
    private var pageLoaded: Date?

    func fetch(_ url: URL) async throws -> (status: Int, body: Data) {
        let page = try await readyPage()
        let answer = try await page.callJavaScript(Self.fetchScript, arguments: ["url": url.absoluteString])
        guard let parts = answer as? [Any], parts.count == 2, let text = parts[1] as? String,
              let status = (parts[0] as? Int) ?? (parts[0] as? Double).map(Int.init) else {
            Self.log.error("Web view gave no answer for \(url.path(), privacy: .public)")
            throw TransitError.decoding("Keine Antwort aus der Webansicht")
        }
        Self.log.info("Web view: \(status) for \(url.path(), privacy: .public)")
        // Blocked: a fresh page next time, in case its cookies are what bahn.de refuses.
        if status == 403 { self.page = nil }
        return (status, Data(text.utf8))
    }

    /// The loaded bahn.de page, loading a new one first when there is none or it is old.
    private func readyPage() async throws -> WebPage {
        if let page, let pageLoaded, Date.now.timeIntervalSince(pageLoaded) < Self.pageLifetime {
            return try await page.value
        }
        let load = Task { try await Self.load() }
        page = load
        pageLoaded = .now
        do {
            return try await load.value
        } catch {
            page = nil
            throw error
        }
    }

    private static func load() async throws -> WebPage {
        log.info("Loading bahn.de in the web view")
        let page = WebPage()
        page.load(URLRequest(url: startURL))
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            if (try? await page.callJavaScript(readyScript) as? Bool) == true { return page }
        }
        log.error("bahn.de did not load in the web view")
        throw TransitError.timeout
    }

    static let log = Logger(subsystem: "de.goldkunibert.BetterBahn", category: "bahnde")

    /// bahn.de's own page has loaded (not an error page elsewhere).
    private static let readyScript = """
        return document.readyState === 'complete' && location.hostname === 'www.bahn.de';
        """

    /// The API request inside the page, as bahn.de's own scripts make it.
    private static let fetchScript = """
        const response = await fetch(url, {headers: {'Accept': 'application/json'}, credentials: 'include'});
        return [response.status, await response.text()];
        """
}
