@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The one paged-feed machine the call log and contacts share.
///
/// ⛔ THE RACES ARE THE POINT. A refresh started while an append is in flight must own
/// the list when both land, whichever lands first; before the pager's generation guard
/// a stale append put the old feed's rows under the new one and skipped a window.
@MainActor
final class PagedFeedModelTests: XCTestCase {
    func testAFirstPageWithRowsIsContent() async {
        let model = PagedFeedModel(pager: Self.rows(count: 30, total: nil))

        await model.loadFirst()

        XCTAssertEqual(Self.rows(of: model).first, "row-0")
        XCTAssertEqual(Self.rows(of: model).count, 30)
    }

    func testAnEmptyFirstPageIsEmptyNotFailed() async {
        let model = PagedFeedModel(pager: Self.rows(count: 0, total: nil))

        await model.loadFirst()

        guard case .empty = model.state else { return XCTFail("got \(model.state)") }
    }

    func testAFailedFirstPageIsAFailure() async {
        let model = PagedFeedModel(pager: OffsetPager<String>(
            identify: { $0 },
            fetch: { _, _ in .failure(.http(status: 503, message: "unavailable")) }
        ))

        await model.loadFirst()

        guard case .failed = model.state else { return XCTFail("got \(model.state)") }
    }

    func testLoadMoreAppendsTheNextWindow() async {
        let model = PagedFeedModel(pager: Self.rows(count: 90, total: nil))
        await model.loadFirst()

        await model.loadMore()

        XCTAssertEqual(Self.rows(of: model).count, 60)
        XCTAssertEqual(Self.rows(of: model).last, "row-59")
    }

    /// ⛔ THE ROWS SURVIVE A FAILED APPEND; only the footer reports it.
    func testAFailedAppendKeepsTheRows() async {
        let calls = AppCounter()
        let model = PagedFeedModel(pager: OffsetPager<String>(
            identify: { $0 },
            fetch: { limit, offset in
                guard await calls.next() == 0 else { return .failure(.http(status: 503, message: "unavailable")) }
                return .success(OffsetPage(items: (offset ..< offset + limit).map { "row-\($0)" }, total: nil))
            }
        ))
        await model.loadFirst()

        await model.loadMore()

        guard case let .content(rows, _, appending, failure) = model.state else {
            return XCTFail("got \(model.state)")
        }
        XCTAssertEqual(rows.count, 30)
        XCTAssertFalse(appending)
        XCTAssertNotNil(failure)
    }

    /// ⛔ THE REPRO, AT THE SCREEN. Append in flight, pull to refresh, the stale append
    /// lands last: the list is the refreshed first page and the next append asks for
    /// row 30, not row 60.
    func testARefreshDuringAnAppendOwnsTheListAndNothingIsSkipped() async {
        let hold = AppHeldFetch()
        let model = PagedFeedModel(pager: Self.rows(count: 300, total: nil, holdingOffset: 30, on: hold))
        await model.loadFirst()

        let append = Task { await model.loadMore() }
        await hold.waitUntilHeld()
        await model.refresh()
        await hold.release()
        await append.value

        guard case let .content(rows, _, appending, failure) = model.state else {
            return XCTFail("got \(model.state)")
        }
        XCTAssertEqual(rows.count, 30, "the stale window must not be appended")
        XCTAssertEqual(rows.first, "row-0")
        XCTAssertFalse(appending)
        XCTAssertNil(failure)

        await model.loadMore()

        XCTAssertEqual(Self.rows(of: model)[30], "row-30", "no window may be skipped")
    }

    /// ⛔ AN APPEND IS REFUSED WHILE A REFRESH IS IN FLIGHT, or it would mark the
    /// refreshed first page as already seen.
    func testAnAppendDuringARefreshIsRefused() async {
        let hold = AppHeldFetch()
        let pager = Self.rows(count: 300, total: nil, holdingOffset: 0, on: hold, skipFirst: true)
        let model = PagedFeedModel(pager: pager)
        await model.loadFirst()

        let refresh = Task { await model.refresh() }
        await hold.waitUntilHeld()
        await model.loadMore()
        await hold.release()
        await refresh.value

        XCTAssertEqual(Self.rows(of: model).count, 30)
        XCTAssertEqual(Self.rows(of: model).first, "row-0")
    }

    // MARK: - Helpers

    private static func rows(of model: PagedFeedModel<String>) -> [String] {
        guard case let .content(rows, _, _, _) = model.state else { return [] }
        return rows
    }

    /// A feed of `row-0` to `row-<count - 1>`. With `hold`, the window at
    /// `holdingOffset` parks once (after `skipFirst` passes, the second time).
    private static func rows(
        count: Int,
        total: Int?,
        holdingOffset: Int = -1,
        on hold: AppHeldFetch? = nil,
        skipFirst: Bool = false
    ) -> OffsetPager<String> {
        let seen = AppCounter()
        return OffsetPager<String>(
            identify: { $0 },
            fetch: { limit, offset in
                if offset == holdingOffset, let hold {
                    let visit = await seen.next()
                    if visit == (skipFirst ? 1 : 0) {
                        await hold.hold()
                    }
                }
                let end = min(offset + limit, count)
                let items = offset < end ? (offset ..< end).map { "row-\($0)" } : []
                return .success(OffsetPage(items: items, total: total))
            }
        )
    }
}

/// A counter an escaping `@Sendable` fetch closure can safely touch.
private actor AppCounter {
    private var value = 0

    /// The count before this call.
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

/// A fetch that parks until the test releases it.
private actor AppHeldFetch {
    private var parked: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var arrived = false

    func hold() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        await withCheckedContinuation { parked = $0 }
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
