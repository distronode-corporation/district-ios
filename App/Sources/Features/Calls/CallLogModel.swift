import DistrictData
import DistrictModel
import Foundation
import Observation

/// What the call log is showing.
///
/// ⛔ `empty` IS REACHABLE ONLY AFTER A SUCCESSFUL FIRST PAGE, and that ordering is
/// the point of having it as a separate case. "We could not look" and "there is
/// nothing" read to a paying operator as data loss when confused; see the ⛔ on
/// ``FailureText``.
///
/// ⛔ AN APPEND FAILURE STAYS INSIDE `content`. A failed extra page must never
/// replace rows the user is already reading, which is the mistake the other client
/// avoids by reading only the REFRESH load state for the whole screen.
enum CallLogState {
    case loading

    /// - Parameters:
    ///   - isEnd: the feed has reported its end, so there is no footer to draw.
    ///   - appending: a further window is in flight.
    ///   - appendFailure: the last append failed. Rows above it are still valid.
    case content(rows: [CallSummary], isEnd: Bool, appending: Bool, appendFailure: FailureText?)

    case empty
    case failed(FailureText)
}

/// The paged call log for ONE workspace.
///
/// ⚠️ THE WORKSPACE IS FIXED FOR THE LIFETIME OF THIS MODEL. Switching workspace must
/// build a new one rather than mutate this: ``OffsetPager``'s offsets and its dedup
/// set are only meaningful within one tenant, and reusing them across a switch would
/// mix two workspaces' rows. ``CallLogView`` enforces it with `.id(workspaceId)`.
@MainActor
@Observable
final class CallLogModel {
    /// ⚠️ Under 100, which the server clamps to, and well over its default of 10.
    /// A non-positive limit quietly yields ten rows and a first page that looks like
    /// the whole feed. See ``OffsetPager/loadNext(limit:)``.
    static let pageSize = 30

    /// ⚠️ A CEILING ON CONSECUTIVE FULLY-DEDUPLICATED WINDOWS, not a page limit. See
    /// ``loadWindow()``.
    private static let maxEmptyWindows = 4

    private(set) var state: CallLogState = .loading

    let workspaceId: String

    private let pager: OffsetPager<CallSummary>
    private var rows: [CallSummary] = []

    /// ⚠️ THE PAGER IS BUILT FROM THE CONTAINER'S ONE REPOSITORY, NEVER FROM A
    /// REPOSITORY CONSTRUCTED HERE. A second `CallsRepository` would carry a second
    /// `ApiClient` and reach a second `TokenRefreshCoordinator`; see the ⛔ on
    /// ``AppContainer``.
    init(container: AppContainer, workspaceId: String) {
        self.workspaceId = workspaceId
        pager = container.calls.pager(workspaceId: workspaceId)
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
    /// ⚠️ GUARDED TWICE: never while an append is already in flight (a scroll can
    /// fire the trigger repeatedly), and never once the feed has reported its end.
    func loadMore() async {
        guard case let .content(rows, isEnd, appending, _) = state else { return }
        guard !isEnd, !appending else { return }
        state = .content(rows: rows, isEnd: isEnd, appending: true, appendFailure: nil)

        switch await loadWindow() {
        case let .success(slice):
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
        await pager.reset()
        switch await loadWindow() {
        case let .success(slice):
            rows = slice.items
            state = rows.isEmpty ? .empty : content(isEnd: slice.isEnd)
        case let .failure(error):
            // ⛔ THE ROWS ARE DROPPED ON PURPOSE. The pager has just been reset, so
            // keeping them would leave the accumulator and the pager's offsets
            // describing different feeds, and the next append would duplicate.
            rows = []
            state = .failed(FailureText.from(error))
        }
    }

    private func content(isEnd: Bool) -> CallLogState {
        .content(rows: rows, isEnd: isEnd, appending: false, appendFailure: nil)
    }

    /// One window that either carries NEW rows or reaches the end.
    ///
    /// ⛔ AN EMPTY SLICE WITH `isEnd` FALSE IS NOT THE END, and treating it as one
    /// truncates the feed silently. ``OffsetSlice`` is deduplicated, so a window whose
    /// every row had already been seen comes back empty while more rows remain; the
    /// list's own trigger is the LAST ROW APPEARING, and an empty slice adds no new
    /// last row, so nothing would ever ask again. Fetching on through those windows is
    /// the only way the trigger stays live.
    ///
    /// ⚠️ BOUNDED, because "keep going until something new arrives" against a feed
    /// that is churning is an unbounded request loop. Stopping early costs a scroll
    /// that has to be nudged; not stopping costs the API.
    private func loadWindow() async -> Result<CallWindow, ApiError> {
        var isEnd = false
        for _ in 0 ..< Self.maxEmptyWindows {
            switch await pager.loadNext(limit: Self.pageSize) {
            case let .success(slice):
                isEnd = slice.isEnd
                guard slice.items.isEmpty, !slice.isEnd else {
                    return .success(CallWindow(items: slice.items, isEnd: slice.isEnd))
                }
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(CallWindow(items: [], isEnd: isEnd))
    }
}

/// What ``CallLogModel/loadWindow()`` resolved to.
///
/// ⚠️ ITS OWN TYPE RATHER THAN ``OffsetSlice``, WHICH CANNOT BE BUILT HERE.
/// `OffsetSlice` declares no explicit initialiser, so its synthesised memberwise one
/// is internal to `DistrictData` and unreachable from the app target. This also drops
/// `receivedCount`, which is a pager-internal detail nothing on this screen reads.
private struct CallWindow {
    let items: [CallSummary]
    let isEnd: Bool
}
