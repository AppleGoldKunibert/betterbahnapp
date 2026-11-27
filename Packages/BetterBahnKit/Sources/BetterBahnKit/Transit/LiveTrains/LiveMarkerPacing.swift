import Foundation

/// How often the live train markers on a map move on, and whether they glide there (#609). A glide keeps
/// the map drawing every frame until the next step: with dozens of markers on a 120 Hz display that ran the
/// battery down, so many markers (or Low Power Mode) jump instead, and steps come every few seconds.
public struct LiveMarkerPacing: Sendable, Equatable {
    /// Time between two steps.
    public var interval: Duration
    /// How long the markers glide to their next spot; nil jumps there.
    public var glide: TimeInterval?

    /// Time between two steps of the markers.
    public static let stepInterval: Duration = .seconds(5)
    /// Up to this many markers glide; more jump.
    public static let maxGlidingMarkers = 20

    public init(interval: Duration, glide: TimeInterval?) {
        self.interval = interval
        self.glide = glide
    }

    /// The pacing for `markerCount` markers on screen.
    public static func forMarkers(_ markerCount: Int, lowPower: Bool) -> LiveMarkerPacing {
        let glides = !lowPower && markerCount <= maxGlidingMarkers
        let seconds = Double(stepInterval.components.seconds)
        return LiveMarkerPacing(interval: stepInterval, glide: glides ? seconds : nil)
    }
}
