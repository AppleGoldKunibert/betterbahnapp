import Foundation

extension TimetablesCredentials {
    /// The DB Timetables API key BetterBahn ships with, so realtime enrichment works without
    /// anyone having to register their own (Einstellungen → Erweiterte Einstellungen still lets
    /// people swap in their own key). Left empty here as pushed: fill in your own free key from
    /// developers.deutschebahn.com for local builds. This file is registered with
    /// `git update-index --skip-worktree`, so those local edits won't show up in `git status`,
    /// `git diff`, or get committed — every clone starts from this same empty, harmless default.
    public static let shipped = TimetablesCredentials(clientID: "REDACTED-ROTATED", apiKey: "REDACTED-ROTATED")
}
