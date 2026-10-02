import DistrictModel
import DistrictNetwork
import Foundation

/// One page of an offset-paged endpoint, as the server answered it.
///
/// - Parameter total: the workspace-wide count, or **nil** when the endpoint does
///   not report one. ⛔ The two are not interchangeable: `GET /api/district/calls`
///   has no total (a short page is the only end-of-list signal available) and
///   `GET /api/district/contacts` has a real one. Conflating them either wastes a
///   request or ends the list early.
public struct OffsetPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let total: Int?

    public init(items: [Item], total: Int? = nil) {
        self.items = items
        self.total = total
    }
}

/// What one `loadNext` produced: the rows that were NEW to this pager, and
/// whether the feed is finished.
public struct OffsetSlice<Item: Sendable>: Sendable {
    /// ⚠️ DEDUPLICATED. This can be SHORTER than the page the server sent, and it
    /// can legitimately be EMPTY while ``isEnd`` is false — every row in that
    /// window had already been seen. A caller that stops on an empty slice
    /// truncates the feed.
    public let items: [Item]
    public let isEnd: Bool
    /// The raw number of rows the server returned, before deduplication.
    public let receivedCount: Int
    /// ⛔ THE PAGER WAS RESET WHILE THIS WINDOW WAS IN FLIGHT, SO IT WAS THROWN AWAY.
    /// A NO-OP, NEVER THE END OF THE FEED: ``isEnd`` is false and ``items`` is empty,
    /// and a caller must change nothing on screen, because whoever called
    /// ``OffsetPager/reset()`` now owns the list.
    public let isDiscarded: Bool

    init(items: [Item], isEnd: Bool, receivedCount: Int, isDiscarded: Bool = false) {
        self.items = items
        self.isEnd = isEnd
        self.receivedCount = receivedCount
        self.isDiscarded = isDiscarded
    }

    static var discarded: OffsetSlice {
        OffsetSlice(items: [], isEnd: false, receivedCount: 0, isDiscarded: true)
    }
}

/// Offset-keyed paging over any District list endpoint.
///
/// ⛔ THIS IS SHARED BECAUSE THE RULES BELOW ARE SUBTLE AND WERE ALREADY DERIVED
/// ONCE, ON THE KOTLIN CLIENT, AGAINST THE REAL SERVER. Every paged endpoint in
/// this API is offset-based over live, newest-first data with no cursor. Three
/// consequences follow, and each silently corrupts a list if reimplemented
/// slightly differently in the next section:
///
/// ⛔ 1. THE SAME ROW CAN ARRIVE ON TWO PAGES. A row inserted between two page
/// loads shifts every subsequent window down, so the row at the old boundary is
/// served again. Reproduced against the real server, not theorised: fetch page 1
/// of the calls feed, insert a call, fetch page 2, and the boundary id comes
/// back. For contacts it is worse, because `bulk-create` inserts an entire import
/// in one statement. ``seenIDs`` is what prevents it, and on a `List` bound to
/// `Identifiable` rows a duplicate id is a runtime failure rather than a cosmetic
/// one.
///
/// ⛔ 2. THE OFFSET MUST ADVANCE BY THE RAW PAGE SIZE, NOT THE DEDUPLICATED SIZE.
/// The server counts offsets over its own rows, so skipping ahead by a smaller
/// number re-requests exactly the rows just dropped — which are dropped again,
/// forever. That is a list that never ends and never stops fetching.
///
/// ⛔ 3. DEDUPLICATION IS PER INSTANCE, AND THAT IS LOAD-BEARING. A pull-to-
/// refresh must start from a clean set (see ``reset()``); a set shared across
/// refreshes would filter out the very rows it just fetched and present an empty
/// list.
///
/// ⚠️ AN ACTOR because the set and the offset are mutable state that a scroll and
/// a refresh can reach concurrently, and because `Item` is only `Sendable`.
///
/// ⛔ AND AN ACTOR IS NOT ENOUGH ON ITS OWN, BECAUSE IT IS REENTRANT. A
/// ``loadNext(limit:)`` suspended on its fetch lets a ``reset()`` run, and when the
/// stale page lands it would advance the RESET pager: scroll to the end, pull to
/// refresh, and the next scroll asks for offset 100 while rows 50 to 99 are never
/// shown, with no error anywhere. ``generation`` is what refuses that page.
public actor OffsetPager<Item: Sendable> {
    public typealias Fetch = @Sendable (_ limit: Int, _ offset: Int) async -> Result<OffsetPage<Item>, ApiError>

    /// ⚠️ RETURNS AN OPTIONAL, AND NIL MEANS "KEEP THIS ROW". A row whose id
    /// could not be read must not be deduplicated: collapsing every id-less row
    /// onto one key would silently drop real data, which is a worse outcome than
    /// showing a duplicate.
    private let identify: @Sendable (Item) -> String?
    private let fetch: Fetch

    private var seenIDs: Set<String> = []
    private var nextOffset = 0
    private var finished = false

    /// Bumped by every ``reset()``. A window whose generation changed across its
    /// fetch belongs to a feed that no longer exists and comes back
    /// ``OffsetSlice/isDiscarded``.
    private var generation = 0

    public init(
        identify: @escaping @Sendable (Item) -> String?,
        fetch: @escaping Fetch
    ) {
        self.identify = identify
        self.fetch = fetch
    }

    /// Whether the feed has reported its end.
    public var isEnd: Bool {
        finished
    }

    /// The offset the next request will use. Exposed for assertions rather than
    /// for callers to drive.
    public var offset: Int {
        nextOffset
    }

    /// Fetch the next window.
    ///
    /// - Parameter limit: ⚠️ THE SERVER CLAMPS IT TO 100 and a non-positive value
    ///   falls back to its DEFAULT of 10 rather than being clamped up — so
    ///   passing 0 quietly yields ten rows and a first page that looks like the
    ///   whole feed. Ask for what you want, under 100.
    public func loadNext(limit: Int) async -> Result<OffsetSlice<Item>, ApiError> {
        // ⚠️ A finished feed answers an empty end-slice rather than issuing
        // another request. The alternative (one wasted round trip per scroll to
        // the bottom) is what an infinite list does when nothing tracks the end.
        guard !finished else {
            return .success(OffsetSlice(items: [], isEnd: true, receivedCount: 0))
        }

        let started = generation
        let outcome = await fetch(limit, nextOffset)
        // ⛔ CHECKED AFTER THE AWAIT, AND FOR A FAILURE TOO. A stale failure would
        // put a "Could not load more" footer under a feed that never asked.
        guard started == generation else { return .success(.discarded) }

        switch outcome {
        case let .success(page):
            return .success(absorb(page, requested: limit))
        case let .failure(error):
            // ⛔ SURFACED, NEVER AS AN EMPTY PAGE. An empty page renders as
            // "nothing here", which for a degraded region or an expired session
            // is a lie the user cannot act on.
            return .failure(error)
        }
    }

    /// Start again from the top with an empty dedup set.
    ///
    /// ⚠️ THIS IS WHAT A PULL-TO-REFRESH CALLS, and clearing ``seenIDs`` is the
    /// point of it rather than an afterthought — see ⛔ 3 on the type. For a
    /// newest-first feed, restarting from offset 0 is also the only honest answer:
    /// an anchor position cannot be translated back into an offset that still
    /// means the same thing once rows have been inserted above it.
    public func reset() {
        seenIDs.removeAll()
        nextOffset = 0
        finished = false
        generation += 1
    }

    /// One window that either carries NEW rows, reaches the end, or was discarded.
    ///
    /// ⛔ AN EMPTY SLICE WITH `isEnd` FALSE IS NOT THE END, and treating it as one
    /// truncates the feed silently. A slice is deduplicated, so a window whose every
    /// row had already been seen comes back empty while more rows remain; a list's
    /// own trigger is the LAST ROW APPEARING, and an empty slice adds no new last
    /// row, so nothing would ever ask again. Fetching on through those windows is the
    /// only way the trigger stays live.
    ///
    /// ⚠️ BOUNDED BY `maxEmptyWindows`, because "keep going until something new
    /// arrives" against a churning feed is an unbounded request loop. Stopping early
    /// costs a scroll that has to be nudged; not stopping costs the API.
    ///
    /// ⛔ A DISCARDED WINDOW STOPS THE LOOP. Going on would fetch from the RESET
    /// pager's offset and hand its rows to a caller still appending to the old feed.
    public func loadNonEmptyWindow(limit: Int, maxEmptyWindows: Int) async -> Result<OffsetSlice<Item>, ApiError> {
        // ⚠️ WHAT THE CEILING ANSWERS: the last empty, unfinished window, so the
        // caller keeps its footer and the next scroll asks again.
        var last = OffsetSlice<Item>(items: [], isEnd: false, receivedCount: 0)
        let started = generation
        for _ in 0 ..< maxEmptyWindows {
            let outcome = await loadNext(limit: limit)
            // ⚠️ THE LOOP'S OWN GENERATION, NOT ONLY EACH WINDOW'S. A reset landing
            // BETWEEN two windows would otherwise start the next one on the new feed.
            guard started == generation else { return .success(.discarded) }
            switch outcome {
            case let .success(slice):
                guard slice.items.isEmpty, !slice.isEnd else {
                    return .success(slice)
                }
                last = slice
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(last)
    }

    private func absorb(_ page: OffsetPage<Item>, requested: Int) -> OffsetSlice<Item> {
        let received = page.items.count
        let fresh = page.items.filter { item in
            guard let key = identify(item) else { return true }
            return seenIDs.insert(key).inserted
        }

        // ⛔ THE RAW COUNT, NOT `fresh.count`. See ⛔ 2 on the type.
        nextOffset += received

        if let total = page.total {
            // A real total: the end is known, so no wasted request.
            finished = received < requested || nextOffset >= total
        } else {
            // No total: a short page is the only end-of-list signal. Costs one
            // extra empty request on an exactly-divisible feed, which is the right
            // price for not guessing a total.
            finished = received < requested
        }

        return OffsetSlice(items: fresh, isEnd: finished, receivedCount: received)
    }
}
