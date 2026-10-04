import BetterBahnKit
import Foundation
import os
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
        log.info("Loading \(url.absoluteString, privacy: .public) in the web view")
        let page = WebPage()
        page.load(URLRequest(url: url))
        let deadline = Date.now.addingTimeInterval(25)
        while Date.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if let html = try? await page.callJavaScript(htmlScript) as? String, !VagonwebClient.isChallenge(html) {
                log.info("Web view loaded \(html.count) characters")
                return html
            }
        }
        let state = (try? await page.callJavaScript(stateScript) as? String) ?? "no answer"
        log.error("Web view gave up: \(state, privacy: .public)")
        // Still Cloudflare's check (or no answer): counts as blocked, so vagonweb isn't asked for a while.
        throw TransitError.rateLimited
    }

    static let log = Logger(subsystem: "de.goldkunibert.BetterBahn", category: "vagonweb")

    /// What the page shows when it never got to vagonweb's own page, for the log.
    private static let stateScript = """
        return document.readyState + ' | ' + location.href + ' | ' + document.title + ' | '
            + (document.body ? document.body.innerText.slice(0, 200) : '')
        """

    /// The page's HTML once vagonweb's own page has loaded (it has the `stred0` content column,
    /// Cloudflare's check doesn't). On a first visit vagonweb shows only an "anzeigen" link; then the
    /// scheduled compositions are fetched inside the page, as its own "all planned" button does
    /// (`VagonwebClient.plannedCompositionsRequest`).
    private static let htmlScript = """
        if (document.readyState !== 'complete' || !document.getElementById('stred0')) return null;
        if (document.getElementById('planovane_razeni')) return document.documentElement.outerHTML;
        const query = new URLSearchParams(location.search);
        const year = query.get('rok') || '';
        const form = new URLSearchParams({rok: year, zeme: query.get('zeme') || 'DB', cislo: query.get('cislo') || '',
            nazev: '_n_', styl: 'r', aktualni_rok: year, cislo_vozu: '', od: '', do_x: '', virtualni_vlak: '',
            cislo_alias: '', vsechny_planovane: '1'});
        const response = await fetch('/razeni/ajax_dalsi_razeni_vlak.php', {method: 'POST', body: form,
            headers: {'X-Requested-With': 'XMLHttpRequest'}});
        const part = await response.text();
        // Nothing there either: the page as it is, which the client reads as vagonweb not answering.
        return part.includes('color-z') ? part : document.documentElement.outerHTML;
        """
}
