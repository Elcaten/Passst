import XCTest
@testable import Passst

final class ClipboardSearchFiltersTests: XCTestCase {
    func testRemoveTrailingFilterFollowsChipDisplayOrder() {
        let source = ClipboardSourceFilter(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari"
        )
        var filters = ClipboardSearchFilters(
            kinds: [.text],
            source: source,
            date: .today
        )

        XCTAssertTrue(filters.removeTrailingFilter())
        XCTAssertNil(filters.date)
        XCTAssertEqual(filters.source, source)
        XCTAssertEqual(filters.kinds, [.text])

        XCTAssertTrue(filters.removeTrailingFilter())
        XCTAssertNil(filters.source)
        XCTAssertEqual(filters.kinds, [.text])

        XCTAssertTrue(filters.removeTrailingFilter())
        XCTAssertTrue(filters.kinds.isEmpty)

        XCTAssertFalse(filters.removeTrailingFilter())
    }
}
