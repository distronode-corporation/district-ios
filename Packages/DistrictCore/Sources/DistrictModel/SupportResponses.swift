import Foundation

/// What a new support request is about.
///
/// ⛔ A CLOSED VOCABULARY, AND THE WRITE TAKES THIS RATHER THAN A `String` FOR THE
/// SAME REASON ``KnowledgeMode`` DOES: it is what makes the route's refusal
/// unreachable from this client. `POST support/requests` validates with
/// `z.enum(["problem","question","suggestion"])` and maps the short kind onto a
/// Jira request type id SERVER-SIDE, deliberately, so that a caller cannot file
/// into an arbitrary type on the desk. Filing into a type whose portal form we do
/// not populate 400s at Atlassian AFTER the local claim row exists, which is the
/// one failure shape here that leaves a half-made request behind.
///
/// ⚠️ THE LABELS ARE NOT THESE NAMES. The web offers "Something is broken", "A
/// question" and "A suggestion"; the raw values are the wire vocabulary and never
/// reach a screen. Same rule as the contact inquiry types: wire values do not get
/// reworded, labels do.
public enum SupportRequestKind: String, Sendable, CaseIterable {
    /// The server's own default on the web form, and the commonest reason anyone
    /// opens this screen.
    case problem
    case question
    case suggestion
}

/// One message in a support thread.
///
/// ⛔ THE THREAD IS RETURNED IN FULL HERE, AND THAT IS DELIBERATE RATHER THAN AN
/// OVERSIGHT TO HARDEN. The neighbouring VOICE path
/// `/api/internal/support-lookup` returns status and nothing else — no summary, no
/// description, no comment body — because a phone call is authenticated by caller
/// ID and caller ID is spoofable, so reading a thread aloud would leak whatever
/// the customer and our agents wrote each other to whoever dialled. This surface
/// is the opposite case: it runs under the operator's own session bearer, inside
/// an authenticated app, scoped by `requireWorkspaceRole`. Withholding the
/// conversation here would leave a paying customer unable to read the answer they
/// opened the screen for. Do not carry the voice rule across.
///
/// ⚠️ ``author`` IS A SUBSTITUTION, NOT THE VENDOR'S DISPLAY NAME. The route
/// answers "Distronode Support" or "You" and never passes an agent's real name
/// through — an agent's name is theirs, and a support thread should read as the
/// company. So it is display copy the server owns, and it is the string to SHOW.
/// ⛔ It is not the string to BRANCH on: see ``knownRole``.
///
/// ⚠️ ``createdAt`` IS AN ISO-8601 STRING RATHER THAN AN INSTANT, like every other
/// timestamp in this module. One decoder strategy would have to be right for every
/// timestamp on the surface and they do not all agree.
public struct SupportMessage: Codable, Sendable, Equatable {
    /// Atlassian's own comment id once the thread exists, mirrored locally.
    public let id: String

    /// `agent` or `customer` on the wire.
    ///
    /// ⛔ A `String`, NOT AN ENUM, AND THE ASYMMETRY WITH ``SupportRequestKind`` IS
    /// THE SAME ONE ``KnowledgeModeResponse/mode`` MAKES. The write is closed
    /// because the server validates it; the read is open because a third role added
    /// server-side must arrive as a value to display rather than fail a support
    /// thread to decode on a build that has not learned it. Branch on
    /// ``knownRole``.
    public let role: String

    /// Who to show as the writer: "Distronode Support" or "You".
    public let author: String

    /// The message text. ⚠️ PLAIN TEXT — the desk stores Atlassian's own rendering
    /// and the server sends it as-is. Nothing here may be interpreted as markup.
    public let body: String

    /// ISO-8601, server-formatted.
    public let createdAt: String
}

/// Which side of a support thread a message came from.
///
/// ⚠️ TWO CASES BECAUSE THE SERVER PRODUCES TWO, and a third would be a value this
/// build does not know rather than an error. See ``SupportMessage/knownRole``.
public enum SupportMessageRole: String, Sendable, CaseIterable {
    /// Distronode wrote it.
    case agent
    /// Somebody in this workspace wrote it.
    case customer
}

public extension SupportMessage {
    /// ``role`` parsed into the vocabulary this build knows, or nil for anything
    /// outside it.
    ///
    /// ⛔ nil MEANS "A ROLE THIS BUILD DOES NOT KNOW", AND IT MUST NOT COLLAPSE
    /// ONTO EITHER SIDE. Defaulting an unrecognised role to `customer` would draw a
    /// message the workspace did not write as though they had; defaulting it to
    /// `agent` would put words in Distronode's mouth. A caller lays an unknown role
    /// out neutrally and shows ``author``, which the server computed and is
    /// therefore right about either way.
    ///
    /// ⚠️ COMPUTED, SO IT IS NOT ENCODED. Synthesised `Codable` covers stored
    /// properties only, which is what keeps this from adding a key the server never
    /// sent.
    var knownRole: SupportMessageRole? {
        SupportMessageRole(rawValue: role)
    }
}

/// One row of the support request list.
///
/// ⚠️ THIS IS THE SERVER'S `WorkspaceTicketSummary` SERIALISED WHOLE. The route
/// spreads the value rather than re-listing its fields, deliberately, so that one
/// place is auditable — which also means a field dropped from that type vanishes
/// from this payload silently. Every field below is non-Optional except
/// ``issueKey``, because every underlying column carries a default or is
/// substituted on the way out.
///
/// ⛔ ``issueKey`` IS NULL WHILE A REQUEST IS STILL BEING FILED, AND THAT IS A
/// STATE RATHER THAN AN ERROR. A request is claimed locally before Atlassian is
/// called, so between the two there is a real, visible row with no key. ``filed``
/// is the flag that says which side of that line it is on, and ``id`` is what a
/// caller keys a list on — it is stable from the moment of submission where the
/// key is not.
public struct SupportRequestSummary: Codable, Sendable, Equatable {
    /// Atlassian's key (`DA-42`), or nil while the request is still being opened.
    public let issueKey: String?

    /// Our own row id, stable from submission. ⚠️ The list keys on this.
    public let id: String

    public let subject: String

    /// The customer-facing status, or the synthetic `Received` while unfiled.
    ///
    /// ⚠️ THE DESK'S OWN WORD, AND THE LIVE WORKFLOW IS LOCALISED — measured
    /// transitions on a real request included `完成` and `等待客户`. So this is a
    /// string to display and never one to match on. ``statusCategory`` is the
    /// language-independent discriminator.
    public let statusName: String

    /// Atlassian's coarse bucket: `NEW`, `INDETERMINATE`, `DONE`, or the synthetic
    /// `PENDING` while unfiled.
    ///
    /// ⛔ NEVER COMPARED WITH `==` AGAINST A LITERAL. This column can carry two
    /// vocabularies (the core issue API reports a lowercase key, the
    /// servicedeskapi an uppercase one) and nothing fails loudly. Go through ``isResolved``.
    public let statusCategory: String

    /// ISO-8601, server-formatted.
    public let createdAt: String
    public let updatedAt: String

    /// True once Atlassian holds it and a conversation is possible.
    ///
    /// ⛔ THE REPLY BOX IS GATED ON THIS AND NOT ON ``issueKey`` ALONE. The server
    /// computes it as "has a key AND the local row is still open", so a retired row
    /// with a key reads as unfiled here, and posting into a thread that does not
    /// exist would silently drop the one message the customer wanted us to see
    /// (the route answers that case **409**).
    public let filed: Bool

    /// How the request reached us: `contact-form`, `voice-call` or `workspace`.
    ///
    /// ⚠️ SURFACED BECAUSE A WORKSPACE'S REQUESTS ARE NOT ALL RAISED FROM THE APP.
    /// An unresolved call to our line files one under the same workspace, so
    /// without this the customer sees a ticket they have no memory of writing. Free
    /// text on the wire and added to rather than renamed server-side, because these
    /// values participate in the claim key.
    public let source: String

    /// The residency region the request was raised in: `us`, `ca`, `eu`, `apac`.
    ///
    /// ⚠️ DISPLAY ONLY. The routing decision was made when the row was written.
    /// ⛔ An unrecognised value is shown as itself and never coerced to `us`: a
    /// helper that picks a default would tell a customer their data sits in the
    /// United States on the strength of a typo.
    public let region: String
}

/// One support request with its whole conversation.
///
/// ⛔ A FLAT STRUCT REPEATING ``SupportRequestSummary``'S FIELDS RATHER THAN
/// COMPOSING ONE, BECAUSE THE WIRE IS FLAT. The route spreads the summary into the
/// same object as `messages` and `closeable`, so a DTO holding a nested
/// `summary` would decode to nothing at all. The duplication is the wire's, and
/// the pair is worth reading together: a field added to the list read almost
/// certainly belongs here too.
public struct SupportRequestDetail: Codable, Sendable, Equatable {
    public let issueKey: String?
    public let id: String
    public let subject: String
    public let statusName: String
    public let statusCategory: String
    public let createdAt: String
    public let updatedAt: String
    public let filed: Bool
    public let source: String
    public let region: String

    /// The conversation, oldest first.
    ///
    /// ⛔ AN EMPTY THREAD IS A REAL ANSWER. A request that has just been filed has
    /// no comments yet, and the description the customer typed is the ticket's own
    /// body rather than a message — so the commonest freshly-opened request shows
    /// an empty conversation and must not read as a failure.
    public let messages: [SupportMessage]

    /// Whether the desk will accept a close from the requester right now.
    ///
    /// ⛔ THE SERVER'S ANSWER, ADOPTED RATHER THAN RE-DERIVED. It is
    /// `filed && !isResolvedCategory(statusCategory)` today, but the second half
    /// was `!== "done"` server-side until it was found to be true for every
    /// resolved request — so the dashboard offered Close on tickets that were
    /// already closed, forever. A client that recomputed it would be free to make
    /// the same mistake again.
    public let closeable: Bool
}

/// Whether a status bucket means the request is finished.
///
/// ⛔ ONE PREDICATE, CASE-INSENSITIVE, AND NEVER AN `==` AT A CALL SITE. The
/// server stores `DONE`, but older production rows still hold lowercase `done`; a
/// comparison against either literal is silently wrong for half the corpus. The
/// rule mirrors the server's `isResolvedCategory`.
public enum SupportStatusCategory {
    /// The canonical spelling the server stores today.
    public static let resolved = "DONE"

    /// True when this bucket means resolved, in either spelling.
    public static func isResolved(_ category: String) -> Bool {
        category.caseInsensitiveCompare(resolved) == .orderedSame
    }
}

public extension SupportRequestSummary {
    /// True when this request is finished. See ``SupportStatusCategory``.
    var isResolved: Bool {
        SupportStatusCategory.isResolved(statusCategory)
    }
}

public extension SupportRequestDetail {
    /// True when this request is finished. See ``SupportStatusCategory``.
    var isResolved: Bool {
        SupportStatusCategory.isResolved(statusCategory)
    }
}

/// `GET /api/district/support/requests?workspaceId=`.
///
/// ⛔ AN EMPTY ARRAY IS A LEGITIMATE ANSWER AND THE ENVELOPE CHECK IS WHAT KEEPS
/// IT DISTINGUISHABLE FROM A FAILURE. This is the surface where conflating them
/// costs the most: the web swallowed every list failure into `[]`, so a desk that
/// was DOWN rendered "No support requests yet" to a customer with three open
/// tickets, who then stopped chasing. ``requests`` is non-Optional because
/// `findMany` always emits the array.
public struct SupportRequestListResponse: Codable, Sendable {
    public let success: Bool
    public let requests: [SupportRequestSummary]
}

/// `GET /api/district/support/requests/{key}?workspaceId=`.
///
/// ⚠️ ``request`` IS NON-OPTIONAL BECAUSE THE ROUTE ALWAYS EMITS IT ON A 200.
/// Every refusal is a **404** carrying `{success:false,error}`, which
/// ``ApiClient/send(_:as:)`` never decodes — it maps the status first. So a 200
/// without the object is contract drift, and failing to decode is the right
/// verdict rather than handing a screen an empty request it would then draw.
public struct SupportRequestDetailResponse: Codable, Sendable {
    public let success: Bool
    public let request: SupportRequestDetail
}

/// What happened to a newly raised request.
///
/// ⛔ THREE OUTCOMES, ALL OF THEM A **200 WITH `success: true`**, AND NONE OF THEM
/// A FAILURE. That is the whole reason this type exists rather than a bare
/// `issueKey`: the server deliberately reports a re-used idempotency key as a
/// SUCCESS, because reporting it as an error would make a retried submit look
/// broken and invite a third attempt into a human's queue.
public enum SupportRequestFiling: Equatable, Sendable {
    /// Filed at Atlassian, and this is its key.
    case filed(issueKey: String)

    /// This exact idempotency key already produced a request. ⚠️ The correct
    /// sentence is the one for a request that exists, not one for a duplicate the
    /// operator must resolve.
    case deduplicated

    /// We hold the request and it is being opened. ⚠️ The claim row exists and the
    /// recovery sweep will file it, so the honest sentence is "we have it and it is
    /// catching up" rather than any kind of failure.
    case pending
}

/// `POST /api/district/support/requests?workspaceId=`.
///
/// ⛔ THREE BODIES BEHIND ONE 200, AND EVERY FIELD IS OPTIONAL BECAUSE EACH BODY
/// CARRIES EXACTLY ONE OF THEM. `{success, issueKey}` when it filed,
/// `{success, deduplicated:true}` when the key was already claimed, and
/// `{success, pending:true}` when the vendor call did not complete. A DTO with a
/// required `issueKey` fails to decode two of the three, and both of those are
/// states a customer sees in normal operation.
public struct SupportRequestCreateResponse: Codable, Sendable {
    public let success: Bool

    /// Present only on the filed branch.
    public let issueKey: String?

    /// `true` only when this idempotency key had already produced a request.
    public let deduplicated: Bool?

    /// `true` only when the claim exists and Atlassian has not answered yet.
    public let pending: Bool?
}

public extension SupportRequestCreateResponse {
    /// Which of the three branches this body is.
    ///
    /// ⛔ THE FALL-THROUGH IS ``SupportRequestFiling/pending`` AND THAT IS A
    /// DELIBERATE CHOICE ABOUT THE SAFE DIRECTION, NOT A DEFAULT. Every branch of
    /// this route that answers 200 has ALREADY written the claim row, so on any
    /// body this build cannot classify the true statement is still "we have your
    /// request". Reporting drift as a failure here would tell a customer their
    /// request was lost when it was not, and they would send it again.
    ///
    /// ⚠️ ORDERED: a present ``issueKey`` wins, then ``deduplicated``. The server
    /// never sends two of them together; the ordering is what makes that assumption
    /// unnecessary rather than load-bearing.
    var filing: SupportRequestFiling {
        if let issueKey, !issueKey.isEmpty {
            return .filed(issueKey: issueKey)
        }
        if deduplicated == true {
            return .deduplicated
        }
        return .pending
    }
}

/// `POST /api/district/support/requests/{key}/reply?workspaceId=`.
///
/// ⚠️ THE ECHOED MESSAGE IS ADOPTED RATHER THAN THE TYPED TEXT, and it is what
/// lets the thread show the reply immediately. The mirror already holds it under
/// Atlassian's own comment id, so the row a later read returns is this one.
/// ``message`` is non-Optional for the reason ``SupportRequestDetailResponse``
/// gives: every refusal is a non-2xx and never reaches this decoder.
public struct SupportReplyResponse: Codable, Sendable {
    public let success: Bool
    public let message: SupportMessage
}

/// `POST /api/district/support/requests/{key}/close?workspaceId=`.
///
/// ⛔ ``statusName`` IS THE DESK'S OWN WORD FOR THE RESOLVED STATE AND MUST BE
/// ADOPTED. The live workflow is localised, so a client that substituted "Closed"
/// would print English over a status Atlassian spells in another language — the
/// same trap that made a name-matching close implementation report "you cannot
/// close this request" on a workflow that plainly could.
///
/// ⚠️ THE CATEGORY IS NOT ECHOED. A caller that keeps a local copy of the request
/// should set it to ``SupportStatusCategory/resolved`` itself, which is the
/// canonical spelling the server now stores, so an optimistic update and the next
/// list read cannot disagree about the same ticket.
public struct SupportCloseResponse: Codable, Sendable {
    public let success: Bool
    public let statusName: String
}
