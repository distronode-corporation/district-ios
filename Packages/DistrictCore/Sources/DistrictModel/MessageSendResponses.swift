import Foundation

/// `POST /api/district/messages/send` — the reply that leaves the building.
///
/// ⛔ METERED AND NON-IDEMPOTENT. Every 2xx is a carrier segment or a Postmark
/// send that has already been paid for. Nothing in this client may retry it, and
/// the single 401 refresh-and-resend that lives in the token coordinator is the
/// only re-send that may ever happen to it.
///
/// ⚠️ ``message`` IS NON-OPTIONAL, WHICH DIVERGES FROM THE KOTLIN DTO. Both of
/// the route's success branches build the key unconditionally; the Kotlin type
/// also decodes the refusal body through this shape, while this client routes
/// non-2xx through `ApiErrorEnvelope`. ⚠️ Those refusals are worth surfacing
/// VERBATIM rather than replacing — an unverified sender, an exhausted A2P
/// registration, the per-workspace 30/min cap — because "Could not send" throws
/// all of that away.
public struct SendMessageResponse: Codable, Sendable {
    public let success: Bool
    public let message: SentMessage
}

/// The message row the send endpoint echoes back.
///
/// ⛔ THE WHOLE ROW, NOT A RECEIPT, AND THE KOTLIN TYPE GOT THIS WRONG ONCE. It
/// modelled five fields out of the thirteen the server sends, so ``status`` was
/// being thrown away — the only field distinguishing "accepted by the carrier and
/// still queued" from "delivered", i.e. a reply that went out from one that is
/// about to fail. Caught by pinning `district-message-send.json`, not by anything
/// in the app.
///
/// ⛔ ONE ENDPOINT, TWO SHAPES, WHICH IS WHY FOUR FIELDS ARE OPTIONAL. The SMS
/// branch sends ``externalId`` and ``accountId`` and no ``subject``; the email
/// branch sends ``subject`` and neither of the other two. All three fixtures are
/// gated for exactly this reason — a single fixture would have made one branch's
/// fields look mandatory, and the strict gate compares key sets per fixture, so a
/// DTO proven against one branch is proven against half the responses.
///
/// ⚠️ ``from`` IS NOT THE RECIPIENT. This row is outbound, so the customer is
/// ``to``. A client that labelled the bubble with ``from`` would attribute the
/// operator's own reply to itself.
public struct SentMessage: Codable, Sendable {
    public let id: String
    /// The provider's own id: a Twilio SID, or a Postmark message id.
    ///
    /// ⚠️ OPTIONAL EVEN THOUGH ALL THREE FIXTURES CARRY IT. The column is
    /// nullable and the route passes it through untouched, so a send whose
    /// provider returned no id would break a non-optional field on a response
    /// that had otherwise succeeded — the worst moment for a decode failure on a
    /// route that has already spent money. Matches the Kotlin DTO.
    public let messageSid: String?
    public let workspaceId: String
    /// ⚠️ The workspace's sending identity, NOT the customer. See the type note.
    public let from: String
    public let to: String
    public let body: String
    /// Email branch only; the key is absent on SMS.
    public let subject: String?
    /// Always `outbound` here, but modelled rather than assumed.
    public let direction: String
    /// `sms`, `email` or `whatsapp`.
    public let type: String
    /// The PROVIDER's word for where the message got to — `queued` from Twilio,
    /// `sent` from Postmark.
    ///
    /// ⚠️ NOT NORMALISED AND NOT REPLACED WITH A BOOLEAN. The two channels
    /// genuinely report different values for the same successful send, so neither
    /// is a constant the client may assume, and collapsing them would discard the
    /// distinction between queued and delivered.
    public let status: String
    /// ISO-8601, server-stamped.
    public let createdAt: String
    /// SMS branch only: the provider's external id. Absent on email.
    public let externalId: String?
    /// `twilio`, `telnyx`, `sinch` or `postmark`.
    public let provider: String
    /// SMS branch only: which of the workspace's gateway accounts sent it.
    /// Absent on email.
    public let accountId: String?
}

/// `messages/send`'s channel vocabulary. The route branches on these exact
/// strings.
public enum MessageChannel {
    public static let sms = "sms"
    public static let email = "email"
    public static let whatsapp = "whatsapp"
}

/// `POST /api/district/messages/mark-read`.
///
/// ⛔ THE ROUTE EXCLUDES `viewer`, SO A READ-ONLY SEAT 403s ON OPENING A THREAD.
/// It can list the inbox and it cannot mark it read, which without a UI gate is a
/// permanent unread badge plus an error dialog on every tap. Gate the call on
/// ``WorkspaceRole/canMutate`` before making it.
///
/// ⚠️ ``marked`` IS A COUNT AND ZERO IS A SUCCESS, the same shape as
/// ``DeviceRevokeResponse/revoked``: a thread whose messages another agent
/// already opened marks nothing, and that is the ordinary race rather than a
/// failure. Both resolve to the same action — redraw from the list.
public struct MarkReadResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ Zero is a success. See the type note.
    public let marked: Int
}
