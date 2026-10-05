import Foundation

/// Waits a little for live data before showing anything, so a screen doesn't first show the plain
/// timetable and then jump to the delays a second later — but never leaves it empty for long.
public enum LoadingDeadline {
    /// How long a journey or train run may load its live data before the timetable shows anyway.
    public static let liveData: Duration = .seconds(4)

    /// Runs `work` and returns its result. If it takes longer than `limit`, `whileWaiting` runs once
    /// (e.g. to show what is already there) while `work` goes on; it never runs after `work` finished,
    /// so whatever `work` returns is always applied last.
    public static func run<T: Sendable>(_ work: @escaping @Sendable () async -> T, showingAfter limit: Duration,
                                        whileWaiting: @escaping @MainActor @Sendable () -> Void) async -> T {
        await withTaskGroup(of: Outcome<T>.self) { group in
            group.addTask { .done(await work()) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .waited
            }
            while let outcome = await group.next() {
                switch outcome {
                case .done(let value):
                    group.cancelAll()
                    return value
                case .waited:
                    await whileWaiting()
                }
            }
            // Both children always finish with an outcome, and `.done` returns above.
            preconditionFailure("work finished without a result")
        }
    }

    private enum Outcome<T: Sendable>: Sendable { case done(T), waited }
}
