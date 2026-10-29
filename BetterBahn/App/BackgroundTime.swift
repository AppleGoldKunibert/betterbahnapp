import UIKit

/// Asks iOS for time to finish work that must not be cut off when the app goes to the background,
/// such as a Träwelling token refresh (`TraewellingClient.KeepAlive`).
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    /// Starts a background task and hands back what ends it; iOS ending it early ends it too.
    static func begin(named name: String) -> @Sendable () async -> Void {
        let time = BackgroundTime()
        time.id = UIApplication.shared.beginBackgroundTask(withName: name) { time.end() }
        return { await time.end() }
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
