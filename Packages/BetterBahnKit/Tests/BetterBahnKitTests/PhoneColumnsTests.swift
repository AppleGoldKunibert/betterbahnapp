import Testing
@testable import BetterBahnKit

/// Which phone windows show two columns (#464).
@Suite struct PhoneColumnsTests {
    @Test func phonesStayOneColumn() {
        #expect(!PhoneColumns.fit(width: 402, height: 874)) // iPhone 17 Pro
        #expect(!PhoneColumns.fit(width: 440, height: 956)) // iPhone 17 Pro Max
        #expect(!PhoneColumns.fit(width: 956, height: 440)) // iPhone 17 Pro Max, sideways
    }

    @Test func foldedDuoStaysOneColumn() {
        #expect(!PhoneColumns.fit(width: 466, height: 678))
        #expect(!PhoneColumns.fit(width: 678, height: 466))
    }

    @Test func unfoldedDuoShowsColumns() {
        #expect(PhoneColumns.fit(width: 669, height: 951)) // upright
        #expect(PhoneColumns.fit(width: 951, height: 669)) // sideways
        #expect(PhoneColumns.width(width: 951, height: 669) == .regular)
    }

    /// Next to another app the window is too narrow for two columns, also where iOS calls it wide (#579).
    @Test func unfoldedDuoNextToAnotherAppIsNarrow() {
        #expect(PhoneColumns.width(width: 469, height: 669) == .compact) // sideways, half the screen
        #expect(PhoneColumns.width(width: 402, height: 874) == .compact) // iPhone 17 Pro
    }

    /// Wide but short windows keep what iOS says, like the folded Duo held sideways.
    @Test func wideShortWindowsKeepTheSystemWidth() {
        #expect(PhoneColumns.width(width: 678, height: 466) == .system)
        #expect(PhoneColumns.width(width: 669, height: 475) == .system) // upright, one app above the other
    }
}
