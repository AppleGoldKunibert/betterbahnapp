import BetterBahnKit
import Foundation
import os
import WebKit

/// Asks bahn.de's web API from a hidden web view on bahn.de, for when bahn.de's bot protection blocks
/// our shared Worker (`BahnDeBrowserFallback`): a real browser engine on the phone's own connection gets
/// through, like bahn.de in Safari. The page starts loading as soon as the Worker is blocked (`prepare`)
/// and is reused for at most half an hour; each request is a `fetch` inside it, so bahn.de sees the
/// cookies its page set. It is let go once the Worker answers again (`release`) or after 5 minutes
/// without a request, so it doesn't sit in memory and wake up for nothing.
@MainActor
final class BahnDeBrowser {
    static let shared = BahnDeBrowser()

    /// Where the hidden page starts: bahn.de's timetable search, the page whose API the app uses.
    private static let startURL = URL(string: "https://www.bahn.de/buchung/fahrplan/suche")!
    private static let pageLifetime: TimeInterval = 30 * 60
    private static let idleTime: Duration = .seconds(5 * 60)

    private var page: Task<WebPage, Error>?
    private var pageLoaded: Date?
    /// Lets the page go once nothing asked for `idleTime`.
    private var idleRelease: Task<Void, Never>?

    /// Starts loading the page in the background (bahn.de just blocked the Worker).
    func prepare() {
        _ = pageTask()
        releaseWhenIdle()
    }

    /// The Worker answers again: no page needed.
    func release() {
        guard page != nil else { return }
        Self.log.info("Releasing the bahn.de web view")
        page = nil
        pageLoaded = nil
        idleRelease?.cancel()
        idleRelease = nil
    }

    func fetch(_ url: URL) async throws -> (status: Int, body: Data) {
        releaseWhenIdle()
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
        let load = pageTask()
        do {
            return try await load.value
        } catch {
            if page == load { page = nil }
            throw error
        }
    }

    /// The page being loaded or loaded, a new load when there is none or it is old.
    private func pageTask() -> Task<WebPage, Error> {
        if let page, let pageLoaded, Date.now.timeIntervalSince(pageLoaded) < Self.pageLifetime { return page }
        let load = Task { try await Self.load() }
        page = load
        pageLoaded = .now
        return load
    }

    private func releaseWhenIdle() {
        idleRelease?.cancel()
        idleRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTime)
            guard !Task.isCancelled else { return }
            self?.release()
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
