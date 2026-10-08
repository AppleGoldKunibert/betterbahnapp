import Foundation
import Synchronization
import Testing
@testable import BetterBahnKit

@Suite struct CustomEmojiTests {
    private static func emoji(_ code: String, picker: Bool = true) -> CustomEmoji {
        CustomEmoji(shortcode: code, url: URL(string: "https://zug.network/\(code).png")!, visibleInPicker: picker)
    }

    /// The shape zug.network's `/api/v1/custom_emojis` returns.
    @Test func decodesMastodonResponse() throws {
        let json = """
        [{"shortcode":"at_s","url":"https://zug.network/original/a.png","static_url":"https://zug.network/static/a.png",
          "visible_in_picker":true,"category":"2.1 Zuggattungen","featured":false}]
        """
        let emojis = try JSONDecoder().decode([CustomEmoji].self, from: Data(json.utf8))
        #expect(emojis == [CustomEmoji(shortcode: "at_s", url: URL(string: "https://zug.network/static/a.png")!,
                                       visibleInPicker: true, category: "2.1 Zuggattungen")])
    }

    @Test func instanceFromTraewellingMastodonURL() {
        #expect(CustomEmojiText.instance(fromMastodonURL: "https://zug.network/@alfred") == "zug.network")
        #expect(CustomEmojiText.instance(fromMastodonURL: "chaos.social/@someone") == "chaos.social")
        #expect(CustomEmojiText.instance(fromMastodonURL: nil) == nil)
        #expect(CustomEmojiText.instance(fromMastodonURL: "") == nil)
    }

    @Test func queryOnlyForAnUnfinishedShortcodeAtTheEnd() {
        #expect(CustomEmojiText.query(in: "Toller :ic") == "ic")
        #expect(CustomEmojiText.query(in: ":ice3") == "ice3")
        #expect(CustomEmojiText.query(in: "(:db_") == "db_")
        #expect(CustomEmojiText.query(in: "Toller :i") == nil)      // too short
        #expect(CustomEmojiText.query(in: "Ab 12:30") == nil)       // a time
        #expect(CustomEmojiText.query(in: "Toller :ice: ") == nil)  // already finished
        #expect(CustomEmojiText.query(in: "Toller :ice:") == nil)
        #expect(CustomEmojiText.query(in: "Hallo") == nil)
    }

    @Test func completeReplacesTheTypedShortcode() {
        #expect(CustomEmojiText.complete("Toller :ic", with: Self.emoji("ice3neo")) == "Toller :ice3neo: ")
        #expect(CustomEmojiText.complete("Hallo", with: Self.emoji("ice")) == "Hallo")
    }

    @Test func suggestionsPreferPrefixAndShortCodes() {
        let emojis = ["db_ice", "ice3neo", "ice", "rj", "ice_hidden"].map { Self.emoji($0, picker: $0 != "ice_hidden") }
        #expect(CustomEmojiText.suggestions(for: "ICE", in: emojis).map(\.shortcode) == ["ice", "ice3neo", "db_ice"])
        #expect(CustomEmojiText.suggestions(for: "ice", in: emojis, limit: 1).map(\.shortcode) == ["ice"])
    }

    @Test func segmentsShowKnownShortcodesAsEmojis() {
        let ice = Self.emoji("ice")
        let segments = CustomEmojiText.segments(of: "Ab 12:30 mit :ice: und :unbekannt:!", emojis: [ice])
        #expect(segments == [.text("Ab 12:30 mit "), .emoji(ice), .text(" und :unbekannt:!")])
        #expect(CustomEmojiText.segments(of: ":ice::ice:", emojis: [ice]) == [.emoji(ice), .emoji(ice)])
        #expect(CustomEmojiText.segments(of: "Kein Emoji", emojis: [ice]) == [.text("Kein Emoji")])
        #expect(CustomEmojiText.segments(of: "", emojis: [ice]).isEmpty)
    }

    /// Downloads once, then serves the disk copy; an unreachable instance falls back to an old copy.
    @Test func clientCachesOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmojiProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config))

        let first = try await CustomEmojiClient(http: http, cacheDirectory: directory).emojis(instance: "emoji.test")
        #expect(first.map(\.shortcode) == ["ice"])
        // A new client (as after an app restart) reads the file instead of asking again.
        let second = try await CustomEmojiClient(http: http, cacheDirectory: directory).emojis(instance: "emoji.test")
        #expect(second == first)
        #expect(EmojiProtocol.requests.withLock { $0 } == 1)

        await #expect(throws: (any Error).self) {
            try await CustomEmojiClient(http: http, cacheDirectory: directory).emojis(instance: "down.test")
        }
    }
}

private final class EmojiProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard url.host == "emoji.test", url.path == "/api/v1/custom_emojis" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Self.requests.withLock { $0 += 1 }
        let body = #"[{"shortcode":"ice","static_url":"https://emoji.test/ice.png","visible_in_picker":true}]"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
