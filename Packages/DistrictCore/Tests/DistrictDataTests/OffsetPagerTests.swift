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

    // MARK: - A reset racing an in-flight window

    /// ⛔ THE REPRO FOR THE SKIPPED ROWS. Scroll to the end (window 50 in flight),
    /// pull to refresh (reset, rows 0 to 49), and the stale window then lands.
    /// Before the generation guard it advanced the reset pager to offset 100, so
    /// the next scroll skipped rows 50 to 99 with no error anywhere.
    func testAWindowInFlightAcrossAResetIsDiscardedAndDoesNotAdvanceTheNewFeed() async {
        let hold = HeldFetch()
        let pager = Self.rowPager(holdingOffset: 50, on: hold)
        _ = await pager.loadNext(limit: 50)

        let stale = Task { await pager.loadNext(limit: 50) }
        await hold.waitUntilHeld()
        await pager.reset()
        let refreshed = await pager.loadNext(limit: 50)
        await hold.release()
        let staleSlice = await stale.value

        XCTAssertEqual(refreshed.successOnly?.items.first, "row-0")
        XCTAssertEqual(refreshed.successOnly?.items.count, 50)
        XCTAssertEqual(staleSlice.successOnly?.isDiscarded, true)
        XCTAssertEqual(staleSlice.successOnly?.items, [])
        XCTAssertEqual(staleSlice.successOnly?.isEnd, false, "a discarded window is not the end")
        let offset = await pager.offset
        XCTAssertEqual(offset, 50, "the next scroll must ask for row 50, not row 100")
    }

    /// ⛔ A STALE FAILURE IS DISCARDED TOO, so a refreshed feed never shows a "Could
    /// not load more" footer for a request it did not make.
    func testAFailureInFlightAcrossAResetIsDiscardedRatherThanSurfaced() async {
        let hold = HeldFetch()
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in
                await hold.hold()
                return .failure(.http(status: 503, message: "unavailable"))
            }
        )

        let stale = Task { await pager.loadNext(limit: 10) }
        await hold.waitUntilHeld()
        await pager.reset()
        await hold.release()
        let slice = await stale.value

        XCTAssertNil(slice.failureOnly)
        XCTAssertEqual(slice.successOnly?.isDiscarded, true)
    }

    // MARK: - One non-empty window

    /// ⛔ AN EMPTY SLICE THAT IS NOT THE END IS FETCHED THROUGH, so a fully
    /// duplicated window never strands the list's last-row trigger.
    func testAWindowLoopFetchesThroughFullyDuplicatedWindows() async {
        let pages = [["a", "b"], ["a", "b"], ["c", "d"]]
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, offset in .success(OffsetPage(items: pages[offset / 2], total: nil)) }
        )
        _ = await pager.loadNext(limit: 2)

        let slice = await pager.loadNonEmptyWindow(limit: 2, maxEmptyWindows: 4)

        XCTAssertEqual(slice.successOnly?.items, ["c", "d"])
        XCTAssertEqual(slice.successOnly?.isDiscarded, false)
    }

    /// ⚠️ BOUNDED. A feed that only ever repeats itself costs the ceiling and no
    /// more, and the answer is "empty, not finished" so the footer stays.
    func testAWindowLoopStopsAtItsCeilingWithoutEndingTheFeed() async {
        let calls = Counter()
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in
                await calls.increment()
                return .success(OffsetPage(items: ["x", "y"], total: nil))
            }
        )
        _ = await pager.loadNext(limit: 2)

        let slice = await pager.loadNonEmptyWindow(limit: 2, maxEmptyWindows: 3)

        XCTAssertEqual(slice.successOnly?.items, [])
        XCTAssertEqual(slice.successOnly?.isEnd, false)
        XCTAssertEqual(slice.successOnly?.receivedCount, 2)
        let count = await calls.value
        XCTAssertEqual(count, 4, "one first page plus exactly three windows")
    }

    /// An empty END window is an answer, not a reason to keep fetching.
    func testAWindowLoopStopsAtTheEnd() async {
        let calls = Counter()
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in
                await calls.increment()
                return .success(OffsetPage(items: [], total: nil))
            }
        )

        let slice = await pager.loadNonEmptyWindow(limit: 2, maxEmptyWindows: 4)

        XCTAssertEqual(slice.successOnly?.isEnd, true)
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testAWindowLoopSurfacesAFailure() async {
        let pager = OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .failure(.http(status: 503, message: "unavailable")) }
        )

        let slice = await pager.loadNonEmptyWindow(limit: 2, maxEmptyWindows: 4)

        XCTAssertEqual(slice.failureOnly, .http(status: 503, message: "unavailable"))
    }

    /// ⛔ A RESET DURING THE LOOP ENDS IT AS DISCARDED rather than letting the
    /// next window start on the new feed and hand its rows to the old one.
    func testAWindowLoopInFlightAcrossAResetIsDiscarded() async {
        let hold = HeldFetch()
        let pager = Self.rowPager(holdingOffset: 0, on: hold)

        let stale = Task { await pager.loadNonEmptyWindow(limit: 50, maxEmptyWindows: 4) }
        await hold.waitUntilHeld()
        await pager.reset()
        await hold.release()
        let slice = await stale.value

        XCTAssertEqual(slice.successOnly?.isDiscarded, true)
        let offset = await pager.offset
        XCTAssertEqual(offset, 0)
    }

    /// Rows `row-<offset>` onward, one window per call; the window at
    /// `holdingOffset` waits on `hold` the first time it is asked for.
    private static func rowPager(holdingOffset: Int, on hold: HeldFetch) -> OffsetPager<String> {
        OffsetPager<String>(
            identify: { $0 },
            fetch: { limit, offset in
                if offset == holdingOffset {
                    await hold.holdOnce()
                }
                return .success(OffsetPage(items: (offset ..< offset + limit).map { "row-\($0)" }, total: nil))
            }
        )
    }
}

/// A fetch that parks until the test releases it, so a test can interleave a
/// ``OffsetPager/reset()`` with a window that is genuinely in flight.
actor HeldFetch {
    private var parked: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var arrived = false
    private var used = false

    /// Park the calling fetch.
    func hold() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        await withCheckedContinuation { parked = $0 }
    }

    /// Park only the first caller; later ones pass straight through.
    func holdOnce() async {
        guard !used else { return }
        used = true
        await hold()
    }

    func waitUntilHeld() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func release() {
        parked?.resume()
        parked = nil
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
