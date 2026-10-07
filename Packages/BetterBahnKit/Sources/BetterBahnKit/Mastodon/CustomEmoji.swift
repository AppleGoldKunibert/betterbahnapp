import Foundation

/// A Mastodon instance's own emoji (`:shortcode:`), e.g. zug.network's train emojis, which
/// Träwelling check-ins shared to Mastodon show as pictures.
public struct CustomEmoji: Codable, Sendable, Hashable, Identifiable {
    public var shortcode: String
    /// The still image (`static_url`); animated ones would only move in Mastodon anyway.
    public var url: URL
    public var visibleInPicker: Bool
    public var category: String?

    public var id: String { shortcode }

    public init(shortcode: String, url: URL, visibleInPicker: Bool = true, category: String? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.visibleInPicker = visibleInPicker
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case shortcode, category
        case url = "static_url"
        case visibleInPicker = "visible_in_picker"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcode = try container.decode(String.self, forKey: .shortcode)
        url = try container.decode(URL.self, forKey: .url)
        visibleInPicker = try container.decodeIfPresent(Bool.self, forKey: .visibleInPicker) ?? true
        category = try container.decodeIfPresent(String.self, forKey: .category)
    }
}

/// Finding, completing and showing `:shortcode:` emojis in a status text.
public enum CustomEmojiText {
    /// Used when the Träwelling account has no Mastodon account connected.
    public static let defaultInstance = "zug.network"

    /// One piece of a status text: plain text, or an emoji to show as a picture.
    public enum Segment: Sendable, Hashable {
        case text(String)
        case emoji(CustomEmoji)
    }

    /// The Mastodon instance's host from Träwelling's `mastodonUrl` (e.g. "https://zug.network/@name").
    public static func instance(fromMastodonURL string: String?) -> String? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        let withScheme = string.contains("://") ? string : "https://\(string)"
        guard let host = URL(string: withScheme)?.host, host.contains(".") else { return nil }
        return host.lowercased()
    }

    /// The shortcode being typed at the end of `text` (`"Toller :ic"` → `"ic"`), or `nil` when the
    /// text doesn't end in an unfinished `:shortcode`. Needs two letters, so a plain colon or a
    /// time like "12:3" doesn't open the suggestions.
    public static func query(in text: String) -> String? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let query = text[text.index(after: colon)...]
        guard query.count >= 2, query.allSatisfy(isShortcodeCharacter) else { return nil }
        // "12:30" or "a:bc": the colon must start a word.
        if colon > text.startIndex {
            let before = text[text.index(before: colon)]
            guard before.isWhitespace || before.isPunctuation && before != ":" else { return nil }
        }
        return String(query)
    }

    /// `text` with the shortcode being typed at its end replaced by the full `:shortcode: `.
    public static func complete(_ text: String, with emoji: CustomEmoji) -> String {
        guard query(in: text) != nil, let colon = text.lastIndex(of: ":") else { return text }
        return String(text[..<colon]) + ":\(emoji.shortcode): "
    }

    /// Emojis matching `query`: shortcodes starting with it first, then those containing it,
    /// each group shortest first, so `ice` offers `ice` before `ice3neo` before `db_ice`.
    public static func suggestions(for query: String, in emojis: [CustomEmoji], limit: Int = 30) -> [CustomEmoji] {
        let query = query.lowercased()
        var prefix: [CustomEmoji] = [], contains: [CustomEmoji] = []
        for emoji in emojis where emoji.visibleInPicker {
            let code = emoji.shortcode.lowercased()
            if code.hasPrefix(query) { prefix.append(emoji) } else if code.contains(query) { contains.append(emoji) }
        }
        let byLength: (CustomEmoji, CustomEmoji) -> Bool = {
            ($0.shortcode.count, $0.shortcode) < ($1.shortcode.count, $1.shortcode)
        }
        return Array((prefix.sorted(by: byLength) + contains.sorted(by: byLength)).prefix(limit))
    }

    /// Splits `text` into plain text and the `:shortcode:`s `emojis` knows. Unknown shortcodes stay text.
    public static func segments(of text: String, emojis: [CustomEmoji]) -> [Segment] {
        guard !emojis.isEmpty, text.contains(":") else { return text.isEmpty ? [] : [.text(text)] }
        let byCode = Dictionary(emojis.map { ($0.shortcode, $0) }, uniquingKeysWith: { first, _ in first })
        var segments: [Segment] = []
        var plain = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: ":") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: ":") else { break }
            let code = rest[afterOpen..<close]
            if !code.isEmpty, code.allSatisfy(isShortcodeCharacter), let emoji = byCode[String(code)] {
                plain += rest[..<open]
                if !plain.isEmpty { segments.append(.text(plain)); plain = "" }
                segments.append(.emoji(emoji))
                rest = rest[rest.index(after: close)...]
            } else {
                // Not an emoji: keep the first colon as text and try again from the second one,
                // which may open the next shortcode ("Abfahrt 12:30 :ice:").
                plain += rest[...open]
                rest = rest[afterOpen...]
            }
        }
        plain += rest
        if !plain.isEmpty { segments.append(.text(plain)) }
        return segments
    }

    private static func isShortcodeCharacter(_ character: Character) -> Bool {
        character == "_" || character.isASCII && (character.isLetter || character.isNumber)
    }
}

/// Loads a Mastodon instance's custom emojis (`/api/v1/custom_emojis`, no login needed) and keeps
/// them on disk for a day, since zug.network alone has over 3000 of them.
public actor CustomEmojiClient {
    let http: HTTPClient
    let cacheDirectory: URL?
    static let maxAge: TimeInterval = 24 * 3600
    private var loaded: [String: [CustomEmoji]] = [:]
    private var running: [String: Task<[CustomEmoji], Error>] = [:]

    public init(http: HTTPClient = HTTPClient(timeout: 30),
                cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        self.http = http
        self.cacheDirectory = cacheDirectory?.appending(path: "CustomEmojis")
    }

    /// The instance's emojis, from memory, the day-old disk copy, or the network. An older disk copy
    /// is still used when the instance can't be reached.
    public func emojis(instance: String) async throws -> [CustomEmoji] {
        if let cached = loaded[instance] { return cached }
        if let fresh = readCache(instance, maxAge: Self.maxAge) {
            loaded[instance] = fresh
            return fresh
        }
        if let task = running[instance] { return try await task.value }
        let http = http
        let task = Task<[CustomEmoji], Error> {
            guard let url = URL(string: "https://\(instance)/api/v1/custom_emojis") else { return [] }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data = try await http.sendRaw(request)
            do {
                return try JSONDecoder().decode([CustomEmoji].self, from: data)
            } catch {
                throw TransitError.decoding(String(describing: error))
            }
        }
        running[instance] = task
        defer { running[instance] = nil }
        do {
            let emojis = try await task.value
            loaded[instance] = emojis
            writeCache(emojis, instance: instance)
            return emojis
        } catch {
            if let stale = readCache(instance, maxAge: .infinity) {
                loaded[instance] = stale
                return stale
            }
            throw error
        }
    }

    private func cacheFile(_ instance: String) -> URL? {
        cacheDirectory?.appending(path: "\(instance).json")
    }

    private func readCache(_ instance: String, maxAge: TimeInterval) -> [CustomEmoji]? {
        guard let file = cacheFile(instance),
              let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([CustomEmoji].self, from: data)
    }

    private func writeCache(_ emojis: [CustomEmoji], instance: String) {
        guard let directory = cacheDirectory, let file = cacheFile(instance),
              let data = try? JSONEncoder().encode(emojis) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
