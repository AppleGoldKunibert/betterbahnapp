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

    /// Files (coach drawings) fetched inside vagonweb's site, once the web view has passed
    /// Cloudflare's check there; the ones it got, by URL.
    func files(at urls: [URL]) async throws -> [URL: Data] {
        guard !urls.isEmpty else { return [:] }
        let before = previous
        let load = Task { () async throws -> [URL: Data] in
            await before?.value
            return try await Self.loadFiles(urls)
        }
        previous = Task { _ = try? await load.value }
        return try await load.value
    }

    private static func loadFiles(_ urls: [URL]) async throws -> [URL: Data] {
        log.info("Loading \(urls.count) drawings in the web view")
        let page = WebPage()
        page.load(URLRequest(url: VagonwebClient.baseURL))
        let deadline = Date.now.addingTimeInterval(25)
        while Date.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            let answer = try? await page.callJavaScript(filesScript, arguments: ["urls": urls.map(\.absoluteString)])
            if let encoded = answer as? [String: Any] {
                var files: [URL: Data] = [:]
                for (key, value) in encoded {
                    if let url = URL(string: key), let base64 = value as? String, let data = Data(base64Encoded: base64) { files[url] = data }
                }
                log.info("Web view loaded \(files.count) of \(urls.count) drawings")
                return files
            }
        }
        log.error("Web view gave up on the drawings")
        throw TransitError.rateLimited
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

    /// Once vagonweb's start page has loaded (not Cloudflare's check), each of `urls` fetched there,
    /// base64-encoded by URL; those that failed are left out.
    private static let filesScript = """
        if (document.readyState !== 'complete' || document.title === 'Just a moment...'
            || document.documentElement.outerHTML.includes('_cf_chl_opt')) return null;
        const files = {};
        for (const url of urls) {
            try {
                const response = await fetch(url);
                if (!response.ok) continue;
                const bytes = new Uint8Array(await response.arrayBuffer());
                let binary = '';
                for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
                files[url] = btoa(binary);
            } catch (error) {}
        }
        return files;
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
