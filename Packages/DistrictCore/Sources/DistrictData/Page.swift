import DistrictModel
import Foundation

/// One page of a cursor-paged collection.
///
/// ⚠️ `nextCursor == nil` is the ONLY end-of-collection signal. An empty
/// `items` array is not: the timeline endpoints can legitimately return a page
/// with no rows and a cursor that still advances (the server's cursor paging
/// filters after the page window). A loop that stops on `items.isEmpty` skips
/// the rest of the collection and looks like data loss.
public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// True when another page should be requested.
    public var hasMore: Bool {
        nextCursor != nil
    }

    /// Append the next page, preserving order and carrying its cursor forward.
    public func appending(_ next: Page<Item>) -> Page<Item> {
        Page(items: items + next.items, nextCursor: next.nextCursor)
    }
}

/// The result of a repository read: either a page or the one normalised error
/// type. Repositories never surface transport-layer types to feature code.
public typealias PageResult<Item: Sendable> = Result<Page<Item>, ApiError>
