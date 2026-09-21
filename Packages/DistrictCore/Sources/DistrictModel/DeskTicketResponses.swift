import Foundation

/// One ticket as every list and every write echoes it.
///
/// ⛔ `displayReference` IS THE SERVER'S OWN `T-104` AND NO CLIENT MAY REBUILD IT.
/// The server's `formatDeskReference` puts it on every payload
/// precisely "so no client re-invents it": the reference is spoken aloud by the voice
/// agent and printed in the customer's notification email, so a second formatter here
/// is how the phone and the phone call start disagreeing about the same ticket.
/// ``reference`` is carried too because it is what sorts numerically, and it is the
/// only field of the two that may be used for that.
///
/// ⚠️ `status` AND `source` ARE FREE TEXT ON THE WIRE. Both columns are plain `TEXT`
/// server-side — chosen so adding a state never needs a migration on four databases
/// — so an unrecognised value is DISPLAYED as itself rather than switched on
/// exhaustively. Branch on ``knownStatus`` and on ``fromCall``, both of which answer
/// honestly for a value this build has not learned. Same call ``KnowledgeDocument``
/// makes about its own `status`.
///
/// ⛔ THE THREE REQUESTER FIELDS ARE THE TENANT'S CUSTOMER'S DETAILS, IN THE CLEAR,
/// AND THAT IS CORRECT HERE AND NOWHERE NEAR THE VOICE PATH. These rows are the
/// tenant's own CRM data being read by the tenant's own staff over a bearer the
/// server checked, under RLS. The phone lookup the agent uses
/// (`/api/internal/desk-lookup`) returns status ONLY, with no subject and no bodies,
/// because a call is authenticated by caller ID and caller ID is spoofable. Do not
/// let a helper written for this type end up serialising into that one.
///
/// ⚠️ EVERY TIMESTAMP IS AN ISO-8601 STRING, NOT AN INSTANT, for the reason
/// ``CallSummary`` and ``KnowledgeDocument`` give: one decoder strategy would have to
/// be right for every timestamp on this surface and they do not all agree.
public struct DeskTicketSummary: Codable, Sendable, Equatable {
    public let id: String
    /// The per-workspace counter. ⚠️ Sorts; never rendered directly.
    public let reference: Int
    /// ⛔ The server's own `T-104`. See the ⛔ on the type.
    public let displayReference: String
    public let subject: String
    /// ⚠️ Free text. Branch on ``knownStatus``.
    public let status: String
    /// `voice-call` or `manual`. ⚠️ Free text. Branch on ``fromCall``.
    public let source: String
    /// The `Contact` row this ticket was raised against, when there was one.
    public let contactId: String?
    public let requesterName: String?
    public let requesterEmail: String?
    /// ⚠️ CANONICALISED SERVER-SIDE on the way in, by the same function the contact
    /// table and the inbound-call upsert use. What arrives here is the stored form.
    public let requesterPhone: String?
    public let createdAt: String
    public let updatedAt: String
    /// ⚠️ CLEARED ON REOPEN, not merely set on close, so a ticket that was resolved
    /// and reopened does not keep a stale timestamp that every "time to resolution"
    /// figure would then be computed from.
    public let resolvedAt: String?
    /// ⚠️ INCLUDES THE OPENING MESSAGE, so a voice-filed ticket nobody has answered
    /// reads as 1 rather than 0.
    public let messageCount: Int

    /// ``status`` parsed into the vocabulary this build knows, or nil for anything
    /// outside it.
    ///
    /// ⚠️ nil IS NOT AN ERROR AND MUST NOT RENDER AS ONE. It means a state was added
    /// server-side that this build predates; the right response is to show ``status``
    /// as itself and offer no opinion, exactly as ``KnowledgeModeResponse/knownMode``
    /// does. Painting an unknown status as resolved would tell an operator a customer
    /// has been dealt with.
    ///
    /// ⚠️ COMPUTED, SO IT IS NOT ENCODED. Synthesised `Codable` covers stored
    /// properties only, which is what keeps this from adding a key the server never
    /// sent.
    public var knownStatus: DeskTicketStatus? {
        DeskTicketStatus(rawValue: status)
    }

    /// Whether the agent filed this at the end of a call it could not resolve.
    ///
    /// ⚠️ THE ONE COMPARISON AGAINST `source` THAT ANY UI SHOULD MAKE, so the literal
    /// lives here rather than in a view. The server's own status lookup derives its
    /// `fromCall` from exactly this test.
    public var fromCall: Bool {
        source == "voice-call"
    }
}

/// One message in a ticket's thread.
///
/// ⛔ THE SERVER SENDS NO AUTHOR LABEL AND THIS TYPE DOES NOT INVENT ONE.
/// `DeskMessageView` is deliberately narrow — `{id, authorType, body, createdAt}` —
/// so a label has to be derived from ``authorType`` plus the ticket's requester at
/// the point of display. That is a UI decision with a trap in it: the fallback in a
/// shared thread renderer names DISTRONODE, which is the wrong company on a tenant's
/// own desk.
///
/// ⚠️ `authorType` IS FREE TEXT ON THE WIRE for the same reason ``status`` is.
/// `customer`, `team` and `assistant` are what the server writes today; branch on
/// ``knownAuthor`` and treat nil as "someone on the team's side", never as an error.
public struct DeskMessage: Codable, Sendable, Equatable {
    public let id: String
    /// ⚠️ Free text. Branch on ``knownAuthor``.
    public let authorType: String
    /// ⛔ PLAIN TEXT. Nothing on this surface renders markup, and a customer's own
    /// words are the last place to start.
    public let body: String
    public let createdAt: String

    /// ``authorType`` parsed, or nil for a value this build has not learned.
    public var knownAuthor: DeskMessageAuthor? {
        DeskMessageAuthor(rawValue: authorType)
    }
}

/// Who wrote a message.
///
/// ⛔ THREE KINDS, TWO SIDES, AND THE DISTINCTION MATTERS IN BOTH DIRECTIONS. The
/// customer is one side; the team and the agent are the other, and a renderer that
/// collapsed them would tell an operator their own agent's summary was written by the
/// person who called. The web maps `assistant` onto the team's SIDE while giving it
/// its own label, which is the shape to copy: the layout answers "which side", the
/// label answers "who".
///
/// ⚠️ `assistant` IS THE VOICE AGENT'S OWN NOTE, and today the only one that exists
/// is the opening summary of a call. It is the one author kind that emits no
/// telemetry and sends no email, because the ticket it belongs to has already been
/// announced.
public enum DeskMessageAuthor: String, Sendable, CaseIterable, Equatable {
    case customer
    case team
    case assistant
}

/// One ticket and its whole thread.
///
/// ⛔ THE MESSAGES ARE NESTED INSIDE THE TICKET, NOT BESIDE IT.
/// `GET /api/district/desk/tickets/{id}` answers `{success, ticket}` where `ticket`
/// carries the summary fields PLUS `messages`. Reading a top-level `messages` yields
/// nothing and renders as an EMPTY THREAD with no error anywhere: the header is
/// right, the conversation is simply gone. The web carries the identical warning.
///
/// ⛔ A FLAT STRUCT RATHER THAN A ``DeskTicketSummary`` PLUS AN ARRAY, because the
/// JSON is flat. Nesting the summary would need a hand-written `init(from:)` whose
/// only job is to undo a shape the server does not send, and a hand-written decoder
/// on this surface is a place for a key to go missing silently.
///
/// ⚠️ IT IS NOT A SUPERSET OF THE LIST ROW BY ACCIDENT — it is the same `select` plus
/// the thread — but nothing may rely on decoding one payload as the other. The list
/// route sends no `messages`, so a detail decoded from a list row would be a ticket
/// whose conversation is permanently empty.
public struct DeskTicketDetail: Codable, Sendable, Equatable {
    public let id: String
    public let reference: Int
    public let displayReference: String
    public let subject: String
    public let status: String
    public let source: String
    public let contactId: String?
    public let requesterName: String?
    public let requesterEmail: String?
    public let requesterPhone: String?
    public let createdAt: String
    public let updatedAt: String
    public let resolvedAt: String?
    public let messageCount: Int
    /// ⛔ Oldest first, as the route orders it. ⚠️ An empty array is legitimate: a
    /// ticket may be created with no opening message at all.
    public let messages: [DeskMessage]

    /// ``status`` parsed. See the ⚠️ on ``DeskTicketSummary/knownStatus``.
    public var knownStatus: DeskTicketStatus? {
        DeskTicketStatus(rawValue: status)
    }

    /// Whether the agent filed this at the end of a call.
    public var fromCall: Bool {
        source == "voice-call"
    }

    /// This ticket with the server's echoed row adopted and one message appended.
    ///
    /// ⛔ THIS EXISTS SO THE CONFIRMED-APPEND RULE LIVES ON THE TESTED TIER. A reply
    /// answers a ``DeskTicketSummary`` and a thread screen holds a
    /// ``DeskTicketDetail``; the two are not interchangeable, because the summary
    /// carries no messages. Rebuilding the detail at a call site would put the merge
    /// in `App/`, which has no test lane at all, and the field most likely to be
    /// dropped there is the one that decides whether the ticket still reads as open.
    ///
    /// ⛔ EVERY FIELD EXCEPT THE MESSAGES COMES FROM `ticket`, THE SERVER'S OWN ROW.
    /// A team reply auto-sets `waiting` unless the ticket is resolved, so keeping the
    /// local status would show a ticket that still says the ball is with the team.
    ///
    /// ⚠️ `messageCount` IS RECOMPUTED FROM THE THREAD rather than taken from the
    /// echo. The summary's count is the server's, from before this append landed in
    /// the local copy, so adopting it would leave the header one behind the messages
    /// visible underneath it.
    public func appending(_ message: DeskMessage, adopting ticket: DeskTicketSummary) -> DeskTicketDetail {
        adopting(ticket, messages: messages + [message])
    }

    /// This ticket with the server's echoed row adopted and the thread unchanged.
    ///
    /// ⛔ WHAT A STATUS CHANGE APPLIES. Resolving stamps `resolvedAt` and reopening
    /// CLEARS it, both server-side, so adopting the requested status alone would leave
    /// a reopened ticket carrying a resolution time in the past — and every "time to
    /// resolution" figure computed from it is then wrong in a way that looks plausible.
    public func adopting(_ ticket: DeskTicketSummary) -> DeskTicketDetail {
        adopting(ticket, messages: messages)
    }

    private func adopting(_ ticket: DeskTicketSummary, messages: [DeskMessage]) -> DeskTicketDetail {
        DeskTicketDetail(
            id: ticket.id,
            reference: ticket.reference,
            displayReference: ticket.displayReference,
            subject: ticket.subject,
            status: ticket.status,
            source: ticket.source,
            contactId: ticket.contactId,
            requesterName: ticket.requesterName,
            requesterEmail: ticket.requesterEmail,
            requesterPhone: ticket.requesterPhone,
            createdAt: ticket.createdAt,
            updatedAt: ticket.updatedAt,
            resolvedAt: ticket.resolvedAt,
            messageCount: messages.count,
            messages: messages
        )
    }
}

/// `GET /api/district/desk/tickets`.
///
/// ⛔ AN EMPTY ARRAY IS A REAL ANSWER AND MUST NEVER RENDER AS A FAILURE — nor as
/// "the desk is off", which is a different fact with a different screen. It is a
/// workspace whose customers have not raised anything, which is where every workspace
/// starts. ``tickets`` is non-Optional because `findMany` always emits the array, so
/// an absent key is drift; the `success` flag is checked by hand at the repository,
/// because a required field rejects `{}` and does not reject a well-formed
/// `success: false`.
public struct DeskTicketsResponse: Codable, Sendable {
    public let success: Bool
    public let tickets: [DeskTicketSummary]
}

/// `GET /api/district/desk/tickets/{id}`.
///
/// ⚠️ A FOREIGN OR DELETED ID IS A **404**, NOT AN EMPTY 200, and that is the right
/// disclosure as well as the right status: a 403 would confirm the id exists
/// somewhere on the platform. So ``ticket`` being nil is contract drift rather than
/// "not found", and the repository reports it as such.
public struct DeskTicketResponse: Codable, Sendable {
    public let success: Bool
    public let ticket: DeskTicketDetail?
}

/// `POST /api/district/desk/tickets`.
///
/// ⛔ A SUCCESS MAY CARRY NO TICKET, AND THAT IS NOT AN ERROR. When the client's
/// `idempotencyKey` has already produced a ticket the route answers
/// `{success: true, deduplicated: true}` and nothing else — deliberately, because
/// reporting a retried submit as a failure would make it look broken and invite a
/// third. See ``DeskTicketCreation``.
///
/// ⚠️ THE DEDUPE IS FAIL-OPEN. `redisClaimOnce` returns true when Redis is
/// unreachable, so a double submit during an outage creates two tickets. The server
/// takes that trade knowingly (the opposite failure is DROPPING a ticket a human
/// typed) and a client must not add a second guard that assumes otherwise.
public struct DeskTicketCreateResponse: Codable, Sendable {
    public let success: Bool
    /// nil when ``deduplicated`` is true. See the ⛔ on the type.
    public let ticket: DeskTicketSummary?
    /// ⚠️ ABSENT rather than false on the ordinary path, which a nil Optional already
    /// round-trips.
    public let deduplicated: Bool?
}

/// `POST /api/district/desk/tickets/{id}/reply`.
///
/// ⛔ `message` IS THE SERVER'S OWN COPY OF THE ROW IT WROTE AND THE COMPOSER DEPENDS
/// ON GETTING IT. The desk follows the confirmed-append rule: a thread appends only
/// what the server says it stored, never an optimistic local echo. Showing the draft
/// optimistically would tell an operator their customer had been answered when the
/// message may never have been written, which is the worst failure this surface can
/// produce, because the customer is waiting.
///
/// ⛔ AND A REPLAY CAN LEGITIMATELY ARRIVE WITH NOTHING TO APPEND. The route caches
/// its result under the idempotency claim and replays it, but two concurrent submits
/// (or Redis dying between the claim and the read) produce a bare
/// `{success: true, deduplicated: true}`. No second row was written either way, which
/// is the property that matters — but there is nothing to add to the thread, and a
/// client that treated the absence as an ordinary success would leave the reply
/// invisible until a refetch. ``DeskReplyOutcome`` is where that fork is made
/// explicit rather than left to an `if let`.
///
/// ⚠️ `notified` IS REPORTED, NOT ENFORCED. False is an ordinary outcome (no address
/// on file, notifications off, the daily cap, or Postmark refusing) and never a
/// failure of the reply itself. The reply is the durable artefact; the email is a
/// doorbell.
public struct DeskReplyResponse: Codable, Sendable {
    public let success: Bool
    public let ticket: DeskTicketSummary?
    /// ⛔ The row the server wrote. See the ⛔ on the type.
    public let message: DeskMessage?
    /// ⚠️ Absent on the degraded replay, which is the only shape that omits it.
    public let notified: Bool?
    public let deduplicated: Bool?
}

/// `POST /api/district/desk/tickets/{id}/status`.
///
/// ⚠️ THE ECHOED TICKET IS ADOPTED, NEVER THE STATUS THAT WAS ASKED FOR. The route
/// writes `resolvedAt` alongside the column — setting it on resolve and CLEARING it
/// on reopen — so the row that comes back carries a fact the request did not, and a
/// screen that kept its own requested value would show a resolved ticket with a
/// resolution time it no longer has.
public struct DeskTicketStatusResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ nil is drift, not "not found": that case is a 404.
    public let ticket: DeskTicketSummary?
}
