// The iOS app shows every station under `Station.displayName` (DB's name, common short forms), not the feed's
// `name`. Kit models encode only `name`, so each station in an answer gets its `displayName` added before it goes
// to Kotlin. The Kit ignores the extra key when the station comes back.
import BetterBahnKit
import Foundation

enum StationNames {
    static func adding(to json: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: annotated(object), options: [.fragmentsAllowed])
    }

    private static func annotated(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(annotated) }
        guard var dictionary = value as? [String: Any] else { return value }
        for (key, child) in dictionary where child is [Any] || child is [String: Any] {
            dictionary[key] = annotated(child)
        }
        // A station is the only Kit model with all three keys.
        if dictionary["id"] is String, dictionary["name"] is String, dictionary["source"] is String,
           let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let station = try? Methods.decoder.decode(Station.self, from: data) {
            dictionary["displayName"] = station.displayName
        }
        return dictionary
    }
}
