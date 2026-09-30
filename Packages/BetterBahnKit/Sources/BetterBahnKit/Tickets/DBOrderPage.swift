import Foundation

/// bahn.de's own "Auftragssuche" page, which the app loads in a hidden web view to fetch a ticket.
///
/// bahn.de's bot protection turns away order requests that don't come from its page in a real
/// browser, so the app can't ask the API directly. Instead `fillScript` types the order number and
/// name the traveller entered in the app into bahn.de's form and submits it. Once the page shows the
/// order, `fetchScript` fetches the order and its ticket PDFs with the page's own session, the same
/// requests bahn.de's "Ticket herunterladen" makes. If bahn.de asks for more (e.g. a captcha), the
/// app shows the page so the traveller can finish there. Nothing is sent anywhere else, and the
/// session token is never kept.
public enum DBOrderPage {
    public static let searchURL = URL(string: "https://www.bahn.de/buchung/meine-reisen")!

    /// The order number once the page shows an order (`/buchung/reise?auftragsnummer=…`).
    public static func orderNumber(in url: URL?) -> String? {
        guard let url, url.host()?.hasSuffix("bahn.de") == true, url.path().hasPrefix("/buchung/reise"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let number = components.queryItems?.first(where: { $0.name == "auftragsnummer" })?.value,
              !number.isEmpty else { return nil }
        return number
    }

    /// Body of an async JavaScript function taking `orderNumber` and `lastName`: types them into the
    /// page's search form and submits it, exactly as if the traveller had done it on bahn.de.
    /// Returns `"submitted"`, or `"noForm"` while the page hasn't rendered its form yet.
    public static let fillScript = """
        const number = document.querySelector('input[name="auftragsnummer-input"]');
        const name = document.querySelector('input[name="nachname-input"]');
        if (!number || !name || !number.form) return 'noForm';
        // bahn.de's page is a Vue app: set the value the way typing does, so it notices.
        const setValue = (input, value) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            input.dispatchEvent(new Event('blur', { bubbles: true }));
        };
        // One field at a time: each field hands the form its whole model, built from what the form
        // had before, so setting both at once would overwrite the order number with the old, empty one.
        const settle = () => new Promise(resolve => setTimeout(resolve, 200));
        setValue(number, orderNumber);
        await settle();
        setValue(name, lastName);
        await settle();
        const button = number.form.querySelector('button[type="submit"]');
        if (button) button.click(); else number.form.requestSubmit();
        return 'submitted';
        """

    /// Body of a JavaScript function returning the error bahn.de shows after a search (e.g. wrong
    /// order number or name), or null.
    public static let errorScript = """
        const main = document.querySelector('main');
        if (!main) return null;
        // `_errorMessage` is where bahn.de's search card shows server errors such as "not found".
        const selectors = '._errorMessage, [role="alert"], [class*="notification"][class*="error"], [aria-invalid="true"]';
        for (const element of main.querySelectorAll(selectors)) {
            const text = (element.innerText || '').trim();
            if (text) return text;
            const described = element.getAttribute('aria-describedby');
            const hint = described && document.getElementById(described)?.innerText?.trim();
            if (hint) return hint;
        }
        return null;
        """

    /// Body of an async JavaScript function (for `WKWebView.callAsyncJavaScript`) taking
    /// `orderNumber`. Returns `{state, status?, order?, pdfs?}`.
    public static let fetchScript = """
        try {
            const vuex = JSON.parse(sessionStorage.getItem('vuex') || '{}');
            const token = vuex?.tokenState?.auftragAuthenticationToken?.accessToken;
            if (!token) return { state: 'noToken' };
            const headers = { Authorization: 'Bearer ' + token, Accept: 'application/json' };
            const orderResponse = await fetch('/web/api/buchung/auftrag/' + encodeURIComponent(orderNumber), { headers });
            if (!orderResponse.ok) return { state: 'error', status: orderResponse.status };
            const order = await orderResponse.text();
            let infos = [];
            try { infos = JSON.parse(order).ticketMaterialisierungsInfos || []; } catch (e) {}
            const pdfs = {};
            for (const info of infos) {
                if (info.multiDokument) continue;
                // One ticket that can't be fetched (e.g. only valid in the DB Navigator) mustn't stop the others.
                try {
                    const ticket = await fetch('/web/api/buchung/ticket', {
                        method: 'POST',
                        headers: { ...headers, 'Content-Type': 'application/json' },
                        body: JSON.stringify({ ticketMaterialisierungsInfo: info }),
                    });
                    if (!ticket.ok) continue;
                    const data = (await ticket.json())?.data;
                    if (typeof data === 'string') pdfs[info.leistungsbuendelId] = data;
                } catch (e) {}
            }
            return { state: 'ok', order, pdfs };
        } catch (e) {
            return { state: 'error', status: 0, message: String(e) };
        }
        """

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        /// The page hasn't finished opening the order yet.
        case notReady
        case blocked
        case notFound
        case http(Int)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .notReady: "Die Buchung wird noch geladen."
            case .blocked: "bahn.de hat die Anfrage blockiert. Bitte versuch es später noch mal."
            case .notFound: "Zu dieser Auftragsnummer und diesem Namen wurde keine Buchung gefunden."
            case .http(let status): "bahn.de hat mit einem Fehler geantwortet (\(status))."
            case .unreadable: "Die Antwort von bahn.de konnte nicht gelesen werden."
            }
        }
    }

    public struct Result: Sendable {
        /// The order JSON.
        public var order: Data
        /// Ticket PDFs by "leistungsbuendelId".
        public var pdfs: [String: Data]
    }

    /// Reads what `fetchScript` returned.
    public static func result(from value: Any?) throws -> Result {
        guard let dictionary = value as? [String: Any], let state = dictionary["state"] as? String else {
            throw Failure.unreadable
        }
        switch state {
        case "ok":
            guard let order = (dictionary["order"] as? String)?.data(using: .utf8) else { throw Failure.unreadable }
            let encoded = dictionary["pdfs"] as? [String: Any] ?? [:]
            let pdfs = encoded.compactMapValues { ($0 as? String).flatMap { Data(base64Encoded: $0) } }
            return Result(order: order, pdfs: pdfs)
        case "noToken":
            throw Failure.notReady
        default:
            let status = (dictionary["status"] as? NSNumber)?.intValue ?? 0
            switch status {
            case 401, 404: throw Failure.notFound
            case 403, 429: throw Failure.blocked
            default: throw Failure.http(status)
            }
        }
    }
}
