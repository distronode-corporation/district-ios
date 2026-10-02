@testable import DistrictData
import XCTest

final class PageTests: XCTestCase {
    func testHasMoreFollowsTheCursorNotTheItems() {
        // ⚠️ The load-bearing case: an EMPTY page that still has a cursor means
        // "keep going", not "done". Stopping here silently truncates a
        // collection.
        let empty = Page<String>(items: [], nextCursor: "cur_2")
        XCTAssertTrue(empty.hasMore)

        let last = Page(items: ["a", "b"], nextCursor: nil)
        XCTAssertFalse(last.hasMore)
    }

    func testAppendingPreservesOrderAndCarriesTheCursor() {
        let first = Page(items: ["a", "b"], nextCursor: "cur_2")
        let second = Page(items: ["c"], nextCursor: nil)
        let merged = first.appending(second)
        XCTAssertEqual(merged.items, ["a", "b", "c"])
        XCTAssertNil(merged.nextCursor)
        XCTAssertFalse(merged.hasMore)
    }

    func testAppendingAnEmptyPageAdvancesTheCursor() {
        let first = Page(items: ["a"], nextCursor: "cur_2")
        let merged = first.appending(Page(items: [], nextCursor: "cur_3"))
        XCTAssertEqual(merged.items, ["a"])
        XCTAssertEqual(merged.nextCursor, "cur_3")
    }
}
