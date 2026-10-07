import Foundation

/// Side view of a series, as drawn in DB's "Fahrzeuglexikon" (© Deutsche Bahn AG); shown in the
/// Wagenreihung next to the train type (#167). The app has an image `assetName` for each.
public struct TrainDrawing: Sendable, Hashable {
    /// Asset name in the app, e.g. "Train-401".
    public var assetName: String
    /// "BR 401"; nil where one drawing stands for several series (ICE T: BR 411 and 415; "ICE 3" from
    /// vagonweb and bahn.expert can also be a BR 407).
    public var series: String?

    /// The drawing for a marketing name as in `TrainFormation.Unit.model` ("ICE 4", "ICE 3neo Redesign" …).
    public static func forModel(_ model: String?) -> TrainDrawing? {
        switch model {
        case "ICE 1": TrainDrawing(assetName: "Train-401", series: "BR 401")
        case "ICE 2": TrainDrawing(assetName: "Train-402", series: "BR 402")
        case "ICE 3": TrainDrawing(assetName: "Train-403", series: nil)
        case "ICE 3 Velaro": TrainDrawing(assetName: "Train-407", series: "BR 407")
        case "ICE 3neo", "ICE 3neo Redesign": TrainDrawing(assetName: "Train-408", series: "BR 408")
        case "ICE T": TrainDrawing(assetName: "Train-411", series: nil)
        case "ICE 4": TrainDrawing(assetName: "Train-412", series: "BR 412")
        default: nil
        }
    }
}

extension TrainFormation {
    /// The drawing of the first trainset that has one: the front of the train when several run together.
    public var drawing: TrainDrawing? {
        units.lazy.compactMap { TrainDrawing.forModel($0.model) }.first
    }
}
