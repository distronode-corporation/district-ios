@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

final class OffsetPagerTests: XCTestCase {
    /// ⛔ THE SAME ROW ARRIVING ON TWO PAGES IS THE ORDINARY CASE, NOT AN EDGE ONE.
    /// A call arriving mid-scroll shifts every window down, so the row at the old
    /// boundary is served again — reproduced against the real server on the Kotlin
    /// client, not theorised.
    func testABoundaryRowServedTwiceIsEmittedOnce() async {
        let pages = [
            ["a", "b"],
            ["b", "c"],
        ]
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, offset in .success(OffsetPage(items: pages[offset / 2], total: nil)) }
        )

        let first = await pager.loadNext(limit: 2)
        let second = await pager.loadNext(limit: 2)

        XCTAssertEqual(first.successOnly?.items, ["a", "b"])
        XCTAssertEqual(second.successOnly?.items, ["c"], "the repeated boundary row is dropped")
    }

    /// ⛔ THE OFFSET ADVANCES BY THE RAW PAGE SIZE, NOT THE DEDUPLICATED ONE.
    /// Skipping ahead by the smaller number re-requests exactly the rows just
    /// dropped, which are dropped again, forever — a list that never ends and
    /// never stops fetching.
    func testTheOffsetAdvancesByRowsReceivedNotRowsKept() async {
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .success(OffsetPage(items: ["dup", "dup"], total: nil)) }
        )

        let slice = await pager.loadNext(limit: 2)

        XCTAssertEqual(slice.successOnly?.items, ["dup"])
        XCTAssertEqual(slice.successOnly?.receivedCount, 2)
        let offset = await pager.offset
        XCTAssertEqual(offset, 2)
    }

    /// ⚠️ AN EMPTY SLICE WITH `isEnd == false` IS A REAL STATE — every row in that
    /// window had been seen. A caller that stops on an empty slice truncates the
    /// feed.
    func testAFullyDuplicateFullPageIsNotTheEnd() async {
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .success(OffsetPage(items: ["x", "y"], total: nil)) }
        )
        _ = await pager.loadNext(limit: 2)

        let second = await pager.loadNext(limit: 2)

        XCTAssertEqual(second.successOnly?.items, [])
        XCTAssertEqual(second.successOnly?.isEnd, false)
    }

    /// ⛔ WITH NO TOTAL, A SHORT PAGE IS THE ONLY END-OF-LIST SIGNAL — the calls
    /// feed reports no total, no `hasMore` and no cursor.
    func testWithNoTotalAShortPageEndsTheList() async {
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .success(OffsetPage(items: ["only"], total: nil)) }
        )

        let slice = await pager.loadNext(limit: 25)

        XCTAssertEqual(slice.successOnly?.isEnd, true)
        let ended = await pager.isEnd
        XCTAssertTrue(ended)
    }

    /// ⚠️ WITH A REAL TOTAL THE END IS KNOWN, so a full final page costs no extra
    /// request. Contacts reports one; calls does not.
    func testWithATotalAFullFinalPageStillEndsTheList() async {
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .success(OffsetPage(items: ["a", "b"], total: 2)) }
        )

        let slice = await pager.loadNext(limit: 2)

        XCTAssertEqual(slice.successOnly?.isEnd, true)
    }

    func testAFinishedPagerIssuesNoFurtherRequests() async {
        let calls = Counter()
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in
                await calls.increment()
                return .success(OffsetPage(items: [], total: nil))
            }
        )

        _ = await pager.loadNext(limit: 10)
        let second = await pager.loadNext(limit: 10)

        XCTAssertEqual(second.successOnly?.isEnd, true)
        XCTAssertEqual(second.successOnly?.receivedCount, 0)
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    /// ⛔ A FAILURE IS SURFACED, NEVER RENDERED AS AN EMPTY PAGE. "Nothing here"
    /// for a degraded region or an expired session is a lie the user cannot act
    /// on.
    func testAFailureIsSurfacedRatherThanBecomingAnEmptyPage() async {
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .failure(.http(status: 503, message: "unavailable")) }
        )

        let slice = await pager.loadNext(limit: 10)

        XCTAssertEqual(slice.failureOnly, .http(status: 503, message: "unavailable"))
        let ended = await pager.isEnd
        XCTAssertFalse(ended, "a failure is not the end of the feed")
    }

    /// ⛔ A PULL-TO-REFRESH CLEARS THE DEDUP SET. Sharing it across refreshes
    /// would filter out the very rows just fetched and present an empty list.
    func testResetClearsTheSeenSetSoARefreshShowsTheSameRowsAgain() async {
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .success(OffsetPage(items: ["a", "b"], total: nil)) }
        )
        _ = await pager.loadNext(limit: 2)

        await pager.reset()
        let afterRefresh = await pager.loadNext(limit: 2)

        XCTAssertEqual(afterRefresh.successOnly?.items, ["a", "b"])
        let offset = await pager.offset
        XCTAssertEqual(offset, 2)
    }

    /// ⚠️ A ROW WHOSE ID CANNOT BE READ IS KEPT. Collapsing every id-less row onto
    /// one key would silently drop real data, which is worse than showing a
    /// duplicate.
    func testRowsWithNoIdAreNeverDeduplicated() async {
        let pager = OffsetPager<String>(
            identify: { _ in nil },
            fetch: { _, _ in .success(OffsetPage(items: ["same", "same"], total: nil)) }
        )

        let slice = await pager.loadNext(limit: 2)

        XCTAssertEqual(slice.successOnly?.items, ["same", "same"])
    }
}

/// A counter an escaping `@Sendable` fetch closure can safely touch.
actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

extension Result {
    var successOnly: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }

    var failureOnly: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
