import Foundation

/// A user-configured tag suggestion shown as a quick-add chip in the check-in sheet. Sent to
/// Träwelling as a `key`/`value` status tag once the checkin succeeds.
public struct QuickTag: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var key: String
    /// Fixed value sent when the tag is toggled on. `nil` asks the user to type a value instead
    /// (e.g. a seat number).
    public var value: String?
    public var systemImage: String

    public init(id: String = UUID().uuidString, label: String, key: String, value: String? = nil, systemImage: String = "tag.fill") {
        self.id = id
        self.label = label
        self.key = key
        self.value = value
        self.systemImage = systemImage
    }

    public static let defaults: [QuickTag] = [
        QuickTag(label: "Sitzplatz", key: "trwl:seat", systemImage: "chair.fill"),
        QuickTag(label: "Wagen", key: "trwl:wagon", systemImage: "train.side.front.car"),
        QuickTag(label: "Ticket", key: "trwl:ticket", systemImage: "ticket.fill"),
        QuickTag(label: "Reiseklasse", key: "trwl:travel_class", systemImage: "star.fill"),
        QuickTag(label: "Baureihe", key: "trwl:locomotive_class", systemImage: "tram.fill"),
    ]
}
