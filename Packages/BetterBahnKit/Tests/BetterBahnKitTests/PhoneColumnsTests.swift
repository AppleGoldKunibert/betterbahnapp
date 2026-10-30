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
    }
}
