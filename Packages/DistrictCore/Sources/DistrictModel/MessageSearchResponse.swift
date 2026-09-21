import Foundation

/// `GET /api/district/messages/search?workspaceId=&q=` — full-content message
/// search for the unified Inbox.
///
/// ⛔ THIS ROUTE HAS EXISTED ON THE SERVER SINCE BEFORE EITHER MOBILE CLIENT AND
/// NOTHING HAS EVER CALLED IT, which is why there is no fixture behind this type.
/// The shared contract corpus mirrors the Android client and that client has no
/// search, so this DTO is modelled from the server's route source rather than
/// pinned by the strict gate —
/// the same footing as ``ContactCreateResponse``. It is the shape to re-check
/// first if that route ever changes.
///
/// ⛔ TWO BODIES, ONE ENDPOINT, AND THE SECOND ONE IS WHY ``limit`` IS OPTIONAL.
/// See its own note: the short-query branch omits the key entirely.
public struct MessageSearchResponse: Codable, Sendable {
    public let success: Bool

    /// The matches, newest first, capped server-side at ``limit``.
    ///
    /// ⚠️ ONE MESSAGE PER ENTRY, NOT ONE THREAD. Several hits can share a
    /// ``MessageSearchHit/threadKey`` — the same conversation matched twice — so a
    /// list keyed on the thread would collapse rows the server deliberately sent
    /// separately. Key on ``MessageSearchHit/messageId``.
    public let results: [MessageSearchHit]

    /// The server's result cap (30), reported so a full page can be captioned as
    /// capped rather than drawn as complete.
    ///
    /// ⛔ OPTIONAL BECAUSE THE SHORT-QUERY BRANCH OMITS THE KEY ALTOGETHER. A `q`
    /// under two characters returns `{"success":true,"results":[]}` and nothing
    /// else — not `limit: null`, not `limit: 0`, absent. A non-optional `Int` here
    /// decodes every ordinary response and then fails on the first person who
    /// types one letter into the search field, which is both the commonest input
    /// and the hardest failure to attribute.
    ///
    /// ⚠️ nil THEREFORE MEANS "the server did not search", not "the cap is
    /// unknown". The results are empty by construction in that branch, so nothing
    /// can be capped and no caption is owed.
    public let limit: Int?
}

/// One matching message.
///
/// ⛔ FIELD NAMES ARE THE SERVER'S, INCLUDING THE ONES THAT READ POORLY IN SWIFT.
/// ``key`` is deprecated server-side and ``kind`` is a per-message property with a
/// thread-shaped name; both are carried rather than renamed or dropped, for the
/// reason ``ConversationSummary`` states at length — an unmodelled key is a
/// dropped key, and a renamed one silently stops matching the wire.
///
/// ⛔ IT CARRIES NO `canSms`/`canEmail`, WHICH IS THE ONE THING A CALLER MUST NOT
/// PAPER OVER. ``ConversationSummary/replyTarget`` gates a reply on those two
/// SERVER-DECIDED flags and this shape has neither, so a reply destination cannot
/// be derived from a hit. Deriving one from ``kind`` would reintroduce exactly the
/// bug ``ConversationSummary/canSms`` documents: the web's reply box inferred
/// sendability from the latest message's type and decided a customer who had only
/// ever emailed could not be sent an SMS.
public struct MessageSearchHit: Codable, Sendable {
    public let messageId: String

    /// The normalized address of THIS message's counterpart.
    ///
    /// ⛔ NOT THREAD IDENTITY, AND SUPERSEDED BY ``threadKey``. Retained through
    /// one deploy for the same client-skew reason as ``ConversationSummary/key``.
    public let key: String

    /// Stable thread identity: `contact:<id>` or `addr:<normalized>`.
    ///
    /// ⛔ THE SAME VALUE `getConversationSummaries` COMPUTES, and that is the whole
    /// point of it being here: it is what lets opening a hit land on the
    /// conversation the Inbox already knows about instead of forking a new one. The
    /// route resolves it stored-link-first, address-second, identically to the list.
    public let threadKey: String

    /// The counterpart as stored on the message, in display form.
    public let counterpart: String

    /// `phone` or `email`, for THIS message.
    ///
    /// ⛔ NOT A CHANNEL THE THREAD CAN BE REPLIED ON. See the ⛔ on the type.
    public let kind: String

    /// nil when the counterpart resolves to no Contact row.
    public let contactId: String?
    public let contactName: String?
    public let contactEmail: String?

    /// The matched message body. ⚠️ Whole, not a snippet: the server does no
    /// highlighting and sends no excerpt, so any truncation is the client's.
    public let body: String

    /// Email branch only; nil on SMS.
    public let subject: String?

    /// `inbound` or `outbound`.
    public let direction: String

    /// `sms`, `email` or `whatsapp` — ⚠️ nil on older rows, the same nullable
    /// column ``ConversationLastMessage/type`` carries.
    public let type: String?

    /// ISO-8601, server-formatted. This module owns no date parsing.
    public let createdAt: String
}

public extension MessageSearchHit {
    /// What to show as the hit's title.
    ///
    /// ⚠️ FALLS BACK TO THE RAW COUNTERPART, NEVER TO A PLACEHOLDER, exactly as
    /// ``ConversationSummary/displayName`` does. An unresolved address IS the
    /// identity of that thread; "Unknown" would hide the one fact available.
    ///
    /// ⚠️ THE NAME COLUMN IS NULLABLE **AND** CAN HOLD AN EMPTY STRING, so a nil
    /// check alone lets a blank title through.
    var displayName: String {
        guard let contactName, !contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return counterpart
        }
        return contactName
    }
}
