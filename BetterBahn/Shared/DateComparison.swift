import Foundation

// The iOS 27.2 SDK gives `Date` its own `<=` and `>=`, back-deployed before 27.2: from 27.2 on, the
// app calls the system's copy. Early iOS 27.2 betas say 27.2 but don't have it, so the first date
// comparison jumped to address 0 and the app and widgets crashed at launch. A module's own
// declaration shadows Foundation's only inside that module, so the app, widget, share and Kit test
// targets each have a copy of this file (`DateComparison.swift`). Check after building:
// `nm -m <binary> | grep 'DateV2[gl]eoiy'` should find nothing.
nonisolated extension Date {
    static func <= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
    }

    static func >= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
    }
}
