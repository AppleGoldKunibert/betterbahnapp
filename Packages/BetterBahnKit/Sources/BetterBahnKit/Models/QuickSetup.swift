import Foundation

/// The steps of the quick setup at the top of Settings (#547), in order. It asks only for the settings most
/// people want to choose once; everything else stays in the settings' menus.
public enum QuickSetupStep: String, CaseIterable, Hashable, Sendable {
    /// Ticket, travel class and whether the search shows only trains it is valid in.
    case ticket
    /// Bike and step-free travel.
    case travel
    /// Warnings, exit reminders and the Live Activity.
    case notifications
    /// Saved journeys in the calendar.
    case calendar
    /// Design and accent color.
    case design

    /// The step after this one; nil for the last.
    public var next: QuickSetupStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), all.index(after: index) < all.endIndex else { return nil }
        return all[all.index(after: index)]
    }

    /// 1 for the first step.
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public static var count: Int { allCases.count }
}

public enum QuickSetup {
    /// Whether the quick setup opens by itself when the app starts: once, on a fresh install. Someone who used
    /// the app before this version (saved journeys, favourites or recent searches on the device) has set it up
    /// already and only finds it in Settings.
    public static func opensOnLaunch(seen: Bool, hasUsedApp: Bool) -> Bool {
        !seen && !hasUsedApp
    }
}
