import Foundation

/// `GET /api/district/messages/{id}?workspaceId=` — one message id exchanged for
/// the THREAD it belongs to.
///
/// ⛔ THIS ROUTE EXISTS BECAUSE THE PUSH PAYLOAD MAY NOT CARRY THE ANSWER, AND
/// WIDENING THE PAYLOAD IS THE BUG IT PREVENTS. A message push is
/// `{type, category, workspaceId, messageId}` and nothing else: a notification is
/// readable by the operating system and by any installed notification-listener
/// app, so `threadKey` is precisely the field that cannot travel in it — it is
/// `addr:<address>` whenever the thread has no `Contact` row, which is to say a
/// customer's raw phone number or email address, on a lock screen. Same for
/// ``MessageThreadTarget/counterpart``. Both are safe HERE and only here, because
/// the request arrives under this client's own bearer and is re-authorised against
/// the workspace before a row is read. The route's own header says all of this.
///
/// ⛔ EVERY INBOX ENDPOINT IS ADDRESSED BY THREAD RATHER THAN BY MESSAGE, WHICH IS
/// WHY A RESOLVER IS NEEDED AT ALL. `mark-read` takes `contactId` or
/// `counterpart`; `send` takes `to` plus a `channel`; `drafts` takes a
/// `threadKey`; `timeline` takes `contactId` or the counterpart address. A
/// message id opens none of them.
///
/// ⚠️ ROLES ARE `["agency","client"]`, THE NARROWER SIDE OF A DISAGREEMENT WITHIN
/// THE INBOX. `timeline` admits `viewer` and this does not, because both actions
/// this resolver exists to enable (reply, mark read) are on the narrow list. It is
/// not a containment claim — a viewer already reaches every fact below through
/// `conversations` and `timeline` — so gate the CALL on the same role the writes
/// are gated on rather than treating a 403 here as a surprise.
///
/// ⚠️ A 404 SAYS NOTHING ABOUT WHICH KIND OF MISS IT WAS. The route's predicate is
/// `{id, workspaceId}`, so "not yours" and "never existed" answer the same status
/// and the same literal, deliberately: distinguishing them would make this an
/// oracle for whether a message id exists somewhere on the platform.
///
/// ⛔ AND A **409** IS A REAL ANSWER RATHER THAN A FAULT. A row whose counterpart
/// does not normalise has no thread to open and nothing to reply to, and the route
/// answers 409 instead of a 200 with a null thread — which is what keeps
/// ``thread`` non-Optional here. Do not model it as nullable to "be safe": that
/// would make every caller branch on a state only a malformed row produces
/// (`Message.from` defaults to `""`).
public struct MessageThreadResponse: Codable, Sendable, Equatable {
    public let success: Bool
    public let message: MessageThreadMessage
    public let thread: MessageThreadTarget
}

/// The message the push was about, reduced to what a shade can act on.
///
/// ⛔ NO `body` AND NO `subject`, AND THEIR ABSENCE IS THE ROUTE'S DESIGN RATHER
/// THAN AN OVERSIGHT IN THIS DTO. The thread target is ROUTING information; the
/// content is what `timeline` serves, under the same bearer, once a thread has been
/// chosen. Keeping them out means a resolver a notification-service extension may
/// one day call cannot become a second content API. Adding either field here would
/// not make it arrive.
public struct MessageThreadMessage: Codable, Sendable, Equatable {
    public let id: String
    /// `inbound` or `outbound`.
    public let direction: String
    /// `sms`, `email` or `whatsapp`. ⚠️ Nullable: `Message.type` is a nullable
    /// column on rows written before it existed, and the route passes it through
    /// untouched rather than substituting a default.
    public let type: String?
    /// When the workspace marked this message read, or nil while it is unread.
    ///
    /// ⚠️ THIS IS WHAT LETS A SHADE DROP A "Mark read" ACTION THAT WOULD DO
    /// NOTHING. The inbox is workspace-level, so a colleague may have opened the
    /// thread between the push being sent and the notification being tapped.
    /// ⚠️ An explicit `null` on the wire, which is why `district-message-thread.json`
    /// carries an `allowedExplicitNulls` entry for `$.message.readAt`.
    public let readAt: String?
    /// ISO-8601, server-stamped. This module owns no date parsing.
    public let createdAt: String
}

/// Where the message's thread is, in all three of the vocabularies the Inbox uses.
///
/// ⛔ THE THREE MUST AGREE AND THEREFORE ARRIVE TOGETHER, which is the same
/// reasoning that put `to` and `channel` inside ``ReplyTarget``. ``threadKey`` is
/// the drafts table's key, ``contactId``/``counterpart`` is what `mark-read` and
/// `timeline` accept, and ``counterpart``/``channel`` is where a send goes.
/// Assembling them from independent guesses is how a draft is saved against one
/// thread and displayed in another.
public struct MessageThreadTarget: Codable, Sendable, Equatable {
    /// `contact:<id>` or `addr:<normalized>` — the server's own form, minted by
    /// the same helpers `conversations` uses, so this route and the Inbox list
    /// agree about the same message.
    public let threadKey: String
    /// nil on an address-keyed thread, which is the ordinary state for a stranger
    /// who has just written in.
    public let contactId: String?
    /// ⛔ THE UNWRAPPED ADDRESS, NOT THE STORED ONE, AND THAT IS WHY IT MUST BE
    /// USED VERBATIM. Inbound email `from` frequently carries a display-name
    /// wrapper (`Paul <paul@example.com>`), and handing that back as a reply
    /// target would put it in `to` on a send. The route runs `normalizeAddress`
    /// and returns its display form; re-deriving anything from this string is how
    /// the wrapper comes back.
    public let counterpart: String
    /// One of ``MessageChannel``'s values.
    ///
    /// ⛔ SERVER-DECIDED FROM THE STORED `type`, FALLING BACK TO THE ADDRESS SHAPE
    /// ONLY WHERE THE COLUMN IS NULL. That fallback is the route's, not this
    /// client's, and it is the one place an `@` test is legitimate — a client that
    /// repeated it would be a second, disagreeing decision, which is exactly what
    /// ``ReplyTarget`` exists to prevent.
    public let channel: String
}
