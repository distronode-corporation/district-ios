import DistrictData
import DistrictModel
import Foundation
import Observation

/// What a paged feed is showing.
///
/// ⛔ `empty` IS REACHABLE ONLY AFTER A SUCCESSFUL FIRST PAGE, and that ordering is
/// the point of having it as a separate case. "We could not look" and "there is
/// nothing" read to a paying operator as data loss when confused; see the ⛔ on
/// ``FailureText``.
///
/// ⛔ AN APPEND FAILURE STAYS INSIDE `content`. A failed extra page must never
/// replace rows the user is already reading, which is the mistake the other client
/// avoids by reading only the REFRESH load state for the whole screen.
enum PagedFeedState<Row> {
    case loading

    /// - Parameters:
    ///   - isEnd: the feed has reported its end, so there is no footer to draw.
    ///   - appending: a further window is in flight.
    ///   - appendFailure: the last append failed. Rows above it are still valid.
    case content(rows: [Row], isEnd: Bool, appending: Bool, appendFailure: FailureText?)

    case empty
    case failed(FailureText)
}

/// One offset-paged list: the first page, pull to refresh, and append on scroll.
///
/// ⛔ ONE STATE MACHINE FOR EVERY PAGED LIST, BECAUSE THE CALL LOG AND CONTACTS HAD
/// TWO IDENTICAL COPIES OF IT and an end-of-feed fix reached one of them only. The
/// paging rules themselves live in ``OffsetPager``; this owns only what the screen
/// shows.
///
/// ⚠️ THE PAGER IS FIXED FOR THE LIFETIME OF THIS MODEL. ``OffsetPager``'s offsets and
/// its dedup set are only meaningful within one tenant, so a workspace switch must
/// build a new model rather than re-point this one; the screens enforce it with
/// `.id(workspaceId)`.
@MainActor
@Observable
final class PagedFeedModel<Row: Sendable> {
    /// ⚠️ Under 100, which the server clamps to, and well over its default of 10.
    /// A non-positive limit quietly yields ten rows and a first page that looks like
    /// the whole feed. See ``OffsetPager/loadNext(limit:)``.
    static var pageSize: Int {
        30
    }

    /// ⚠️ A CEILING ON CONSECUTIVE FULLY-DEDUPLICATED WINDOWS, not a page limit. See
    /// ``OffsetPager/loadNonEmptyWindow(limit:maxEmptyWindows:)``.
    static var maxEmptyWindows: Int {
        4
    }

    private(set) var state: PagedFeedState<Row> = .loading

    private let pager: OffsetPager<Row>
    private var rows: [Row] = []

    /// How many restarts (a first load or a refresh) are in flight.
    ///
    /// ⛔ AN APPEND IS REFUSED WHILE ONE IS. Both would read the same pager
    /// generation, so an append landing first would mark the refreshed first page as
    /// already seen, and the refresh would then skip it as duplicates. A count rather
    /// than a flag, so the first of two overlapping refreshes finishing cannot unlock
    /// appends while the second is still out.
    private var restartsInFlight = 0

    init(pager: OffsetPager<Row>) {
        self.pager = pager
    }

    /// The first page, from a clean pager.
    ///
    /// ⚠️ RESETS BEFORE FETCHING so it is idempotent: a second call (a retry, or a
    /// re-appearance of the view) starts from offset 0 with an empty dedup set rather
    /// than continuing wherever the last one stopped.
    func loadFirst() async {
        state = .loading
        await restart()
    }

    /// Pull to refresh.
    ///
    /// ⚠️ DOES NOT SET `loading`, so the rows stay on screen while the request runs.
    /// Replacing a populated list with a spinner throws away what the user was
    /// reading; see the ⚠️ on ``LoadingView``.
    func refresh() async {
        await restart()
    }

    /// One more window, appended.
    ///
    /// ⚠️ GUARDED THREE TIMES: never while an append is already in flight (a scroll
    /// can fire the trigger repeatedly), never once the feed has reported its end, and
    /// never while a restart is in flight (see ``restartsInFlight``).
    func loadMore() async {
        guard restartsInFlight == 0 else { return }
        guard case let .content(rows, isEnd, appending, _) = state else { return }
        guard !isEnd, !appending else { return }
        state = .content(rows: rows, isEnd: isEnd, appending: true, appendFailure: nil)

        switch await pager.loadNonEmptyWindow(limit: Self.pageSize, maxEmptyWindows: Self.maxEmptyWindows) {
        case let .success(slice):
            // ⛔ A REFRESH STARTED WHILE THIS WAS IN FLIGHT, AND IT OWNS THE LIST NOW.
            // Appending this window would put the old feed's rows under the new one.
            guard !slice.isDiscarded else { return }
            self.rows.append(contentsOf: slice.items)
            state = .content(rows: self.rows, isEnd: slice.isEnd, appending: false, appendFailure: nil)
        case let .failure(error):
            // ⛔ THE ROWS SURVIVE. Only the footer reports this.
            state = .content(
                rows: self.rows,
                isEnd: isEnd,
                appending: false,
                appendFailure: FailureText.from(error)
            )
        }
    }

    // MARK: - Internals

    private func restart() async {
        restartsInFlight += 1
        defer { restartsInFlight -= 1 }
        await pager.reset()
        switch await pager.loadNonEmptyWindow(limit: Self.pageSize, maxEmptyWindows: Self.maxEmptyWindows) {
        case let .success(slice):
            // ⚠️ A NEWER RESTART OWNS THE LIST. It reset the pager after this one did.
            guard !slice.isDiscarded else { return }
            rows = slice.items
            state = rows.isEmpty
                ? .empty
                : .content(rows: rows, isEnd: slice.isEnd, appending: false, appendFailure: nil)
        case let .failure(error):
            // ⛔ THE ROWS ARE DROPPED ON PURPOSE. The pager has just been reset, so
            // keeping them would leave the accumulator and the pager's offsets
            // describing different feeds, and the next append would duplicate.
            rows = []
            state = .failed(FailureText.from(error))
        }
    }
}
