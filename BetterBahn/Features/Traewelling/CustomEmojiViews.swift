import BetterBahnKit
import SwiftUI
import UIKit

/// Loaded Mastodon emoji pictures, shrunk to text size, shared by every view showing them.
@MainActor @Observable
final class CustomEmojiImages {
    static let shared = CustomEmojiImages()
    /// Point size the pictures are drawn at, about one line of body text.
    nonisolated static let size: CGFloat = 20

    private(set) var images: [URL: UIImage] = [:]
    @ObservationIgnored private var loading: Set<URL> = []

    func load(_ urls: some Sequence<URL>) {
        for url in urls where images[url] == nil && loading.insert(url).inserted {
            Task {
                defer { loading.remove(url) }
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.setValue(HTTPClient.identifyingUserAgent, forHTTPHeaderField: "User-Agent")
                guard let response = try? await URLSession.shared.data(for: request),
                      let image = await Self.shrunk(response.0) else { return }
                images[url] = image
            }
        }
    }

    /// Decodes and scales the picture off the main thread; zug.network's are up to a few hundred pixels.
    @concurrent nonisolated private static func shrunk(_ data: Data) async -> UIImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = size / max(image.size.width, image.size.height)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// A status text with its `:shortcode:` emojis drawn as pictures (plain shortcode until loaded).
struct EmojiText: View {
    let text: String
    let emojis: [CustomEmoji]

    private var images: CustomEmojiImages { .shared }

    /// Text puts a picture on the baseline, which leaves the descenders' room below it and makes it sit
    /// high; moved down by this, its middle meets the middle of the capitals, as Mastodon draws it.
    /// Both places showing it use `.subheadline`.
    private var emojiBaselineOffset: CGFloat {
        (UIFont.preferredFont(forTextStyle: .subheadline).capHeight - CustomEmojiImages.size) / 2
    }

    var body: some View {
        let segments = CustomEmojiText.segments(of: text, emojis: emojis)
        segments.reduce(Text(verbatim: "")) { (result: Text, segment) -> Text in
            switch segment {
            case .text(let string):
                Text("\(result)\(Text(verbatim: string))")
            case .emoji(let emoji):
                if let image = images.images[emoji.url] {
                    Text("\(result)\(Text(Image(uiImage: image)).baselineOffset(emojiBaselineOffset))")
                } else {
                    Text("\(result)\(Text(verbatim: ":\(emoji.shortcode):"))")
                }
            }
        }
        .task(id: text) {
            images.load(segments.compactMap { segment -> URL? in
                if case .emoji(let emoji) = segment { emoji.url } else { nil }
            })
        }
    }
}

/// The check-in text field: typing `:ic` offers matching emojis of the Mastodon instance, and once
/// the text holds one, a preview below shows it the way Mastodon will.
struct EmojiMessageField: View {
    @Binding var message: String
    let emojis: [CustomEmoji]
    var placeholder = "Was geht ab? (optional)"

    private var suggestions: [CustomEmoji] {
        guard let query = CustomEmojiText.query(in: message) else { return [] }
        return CustomEmojiText.suggestions(for: query, in: emojis)
    }

    private var showsPreview: Bool {
        CustomEmojiText.segments(of: message, emojis: emojis).contains { if case .emoji = $0 { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemImage: "text.bubble.fill", color: .blue, size: 32)
                TextField(placeholder, text: $message, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(.top, 5)
            }
            if !suggestions.isEmpty {
                EmojiSuggestionBar(suggestions: suggestions) { emoji in
                    message = CustomEmojiText.complete(message, with: emoji)
                }
                .transition(.opacity)
            }
            if showsPreview {
                EmojiText(text: message, emojis: emojis)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
            }
            if !message.isEmpty {
                Text("\(message.count)/280")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(message.count > 280 ? Color.heavyDelay : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .animation(.snappy, value: suggestions.map(\.shortcode))
    }
}

/// Matching emojis, picture and shortcode, in a row to tap.
struct EmojiSuggestionBar: View {
    let suggestions: [CustomEmoji]
    let onPick: (CustomEmoji) -> Void

    private var images: CustomEmojiImages { .shared }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { emoji in
                    Button { onPick(emoji) } label: {
                        HStack(spacing: 6) {
                            Group {
                                if let image = images.images[emoji.url] {
                                    Image(uiImage: image)
                                } else {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            .frame(width: CustomEmojiImages.size, height: CustomEmojiImages.size)
                            Text(emoji.shortcode)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.brand)
                        .background(Color.brand.opacity(0.12), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: ":\(emoji.shortcode):"))
                }
            }
        }
        .task(id: suggestions.map(\.shortcode)) { images.load(suggestions.map(\.url)) }
    }
}
