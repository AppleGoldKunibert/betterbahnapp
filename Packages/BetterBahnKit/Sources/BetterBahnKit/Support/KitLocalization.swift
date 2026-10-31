import Foundation

/// Language of the UI texts BetterBahnKit builds (`String(kit:)`). German is the base language and the key
/// of every entry in `Resources/Localizable.xcstrings`; the app and its extensions follow the device
/// language, tests and tools always get German.
public enum KitLocalization {
    /// The `.lproj` folder of the app's language, nil for German (the keys themselves).
    static let languagePath: String? = {
        guard ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension),
              let language = Bundle.main.preferredLocalizations.first, language != "de" else { return nil }
        return Bundle.module.path(forResource: language, ofType: "lproj")
            ?? Bundle.module.path(forResource: "en", ofType: "lproj")
    }()

    /// Whether Kit texts are German (the app runs in German, or outside the app).
    public static var isGerman: Bool { languagePath == nil }

    /// The language our servers write their notifications in ("de", "en"): iOS translates a notification's keys
    /// in the device's language, not in one chosen for the app alone.
    public static var notificationLanguage: String { isGerman ? "de" : "en" }

    /// Locale for dates and numbers inside Kit texts: German while the texts are German, else the device's.
    public static var locale: Locale { isGerman ? Locale(identifier: "de_DE") : .current }

    /// The translation of `key`, or `key` itself when there is none.
    static func lookUp(_ key: String) -> String {
        guard let languagePath, let bundle = Bundle(path: languagePath) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Fills `%@`, `%lld`, `%d`, `%f`, `%lf` (also positional, `%2$@`) in order with `arguments`; `%%` is a
    /// percent sign. Done by hand so that it works the same on Linux and with any argument type.
    static func format(_ template: String, _ arguments: [Any]) -> String {
        guard !arguments.isEmpty || template.contains("%%") else { return template }
        var result = ""
        var next = 0
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            index = template.index(after: index)
            guard character == "%", index < template.endIndex else {
                result.append(character)
                continue
            }
            if template[index] == "%" {
                result.append("%")
                index = template.index(after: index)
                continue
            }
            // Optional position ("2$"), then the specifier up to and including its conversion letter.
            var cursor = index
            var digits = ""
            while cursor < template.endIndex, template[cursor].isNumber {
                digits.append(template[cursor])
                cursor = template.index(after: cursor)
            }
            var position: Int?
            if !digits.isEmpty, cursor < template.endIndex, template[cursor] == "$" {
                position = Int(digits).map { $0 - 1 }
                cursor = template.index(after: cursor)
            } else {
                cursor = index
            }
            while cursor < template.endIndex, "lhq.0123456789".contains(template[cursor]) {
                cursor = template.index(after: cursor)
            }
            guard cursor < template.endIndex, "@dDiuUxXfFeEgGs".contains(template[cursor]) else {
                result.append(character)
                continue
            }
            let argumentIndex = position ?? next
            if position == nil { next += 1 }
            if arguments.indices.contains(argumentIndex) {
                result += String(describing: arguments[argumentIndex])
            }
            index = template.index(after: cursor)
        }
        return result
    }
}

extension String {
    /// UI text from BetterBahnKit's string catalog: `key` is the German text with `%@`/`%lld` placeholders,
    /// `arguments` fill them in order, e.g. `String(kit: "Gleis %@", platform)`.
    init(kit key: String, _ arguments: Any...) {
        self = KitLocalization.format(KitLocalization.lookUp(key), arguments)
    }
}
