import DistrictModel
import Foundation

/// A message search's matches, and whether the server had to stop.
///
/// ⛔ THE SAME SHAPE AS ``ConversationList`` AND FOR THE SAME REASON. The hits
/// alone cannot say whether the list is everything: `messages/search` caps at 30
/// and reports the cap, so a caller handed a bare array would draw a full page as
/// if it were complete. This is the smallest type that carries the caption's input
/// without handing the envelope's `success` flag back to a screen.
///
/// ⚠️ A FILE OF ITS OWN RATHER THAN BESIDE ``ConversationList``, WHICH IS A SIZE
/// DECISION AND NOT A KIND ONE. `InboxRepository.swift` sits close to SwiftLint's
/// 500-line `file_length` ceiling — an error under `--strict` — and this type plus
/// its sibling method would leave it almost no headroom. `InboxRepositoryTests`
/// is split from `RepositoryTests` for the same reason.
public struct MessageSearchResults: Sendable {
    /// ⚠️ NO EXPLICIT INITIALISER, LIKE ``ConversationList``. A public struct's
    /// synthesised memberwise initialiser is INTERNAL, so only this module can build
    /// one — which is correct here, because the only honest producer is
    /// ``InboxRepository/search(workspaceId:query:)``. ``ReplyTarget`` documents the
    /// opposite call and why it needed one.
    public let response: MessageSearchResponse

    /// The matches, newest first.
    ///
    /// ⛔ KEY A LIST ON ``MessageSearchHit/messageId``, NEVER ON `threadKey`. Two
    /// hits in one conversation are two rows the server deliberately sent
    /// separately, and a duplicate identifier in a SwiftUI `ForEach` is a rendering
    /// fault rather than a cosmetic repeat.
    public var hits: [MessageSearchHit] {
        response.results
    }

    /// ⚠️ CAPTION THE LIST WHEN THIS IS TRUE. The server stopped at its cap, so
    /// older matches exist that this response does not contain. There is nothing to
    /// fetch — the route takes no offset — so this is a truthfulness signal rather
    /// than a pager, exactly like ``ConversationList/isPartial``.
    ///
    /// ⚠️ FALSE WHEN `limit` IS ABSENT, WHICH IS NOT A GUESS. The key is missing
    /// only on the short-query branch, and that branch returns no results at all, so
    /// there is nothing that could have been capped.
    public var isCapped: Bool {
        guard let limit = response.limit else { return false }
        return response.results.count >= limit
    }
}
