import DistrictModel
import Foundation

/// This workspace's own support requests **with Distronode**: raising one,
/// reading it, answering it and closing it.
///
/// ⛔ THE MIRROR IMAGE OF THE DESK, AND THE TWO MUST NEVER BE DESCRIBED WITH THE
/// SAME NOUN. `district/support/*` is the tenant writing to US; `district/desk/*`
/// is the tenant's own customers writing to THEM. The web sidebar carries the
/// same instruction beside its two entries, because a two-word label cannot hold
/// the distinction on its own and a bare "Tickets" on either surface collapses
/// them. Nothing here may be reused to address the desk.
///
/// ⛔ ALL FIVE ADMIT `agency` AND `client` AND EXCLUDE `viewer`, which is unusual
/// on this surface: most reads here widen to every role and only the writes
/// narrow. The route's own header states why — these payloads are support
/// CORRESPONDENCE rather than operational status, and a read-only seat exists to
/// watch operations. So the READ is gated too, and a viewer must not be offered
/// the destination at all rather than being walked into a 403.
///
/// ⚠️ A WORKSPACE MEMBER SEES THE WHOLE WORKSPACE'S REQUESTS, not only the ones
/// they raised. That is a deliberate product decision on the server (a colleague's
/// open ticket must not become unreachable when they leave), and it is the reason
/// the role list is the administrative pair rather than every member.
///
/// ⛔ THE SIXTH THING THIS SURFACE COULD DO IS ABSENT ON PURPOSE: there is no
/// REOPEN. The desk workflow exposes no single unambiguous transition back out of
/// `done`, so the server does not offer one and guessing one would move a
/// customer's request into a state their agent did not choose. Replying on a
/// closed request is the supported path.
public extension DistrictEndpoints {
    /// Every request this workspace has raised, newest first.
    ///
    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND MUST NEVER RENDER AS A FAILURE, and on
    /// this surface the inverse is the expensive one: the web swallowed every list
    /// failure into `[]` and told a customer with three open tickets that they had
    /// none, so they stopped chasing and nobody here ever saw the request. The
    /// envelope check in ``SupportRepository`` is what keeps the two apart.
    ///
    /// ⚠️ CAPPED SERVER-SIDE AT 100 ROWS AND NOT PAGED. There is no cursor and no
    /// `limit` parameter to send; a workspace past the cap simply does not see its
    /// oldest requests here.
    static func supportRequests(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .supportRequests,
            .get,
            DistrictPaths.supportRequests,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Raise a new request.
    ///
    /// ⛔ `kind` IS A CLOSED VOCABULARY AND THE PARAMETER IS ``SupportRequestKind``
    /// RATHER THAN A `String` FOR THAT REASON. The route maps the short kind onto a
    /// Jira request type id server-side precisely so a caller cannot file into an
    /// arbitrary type on the desk — one whose portal form we do not populate, which
    /// 400s at Atlassian AFTER the local claim row already exists. A bare string
    /// here would be a client that could earn that.
    ///
    /// ⛔ THE PAYLOAD IS EXACTLY `kind`, `subject`, `message` AND THE KEY, AND
    /// NOTHING MAY BE ADDED TO IT. This is backed by a real Atlassian service desk,
    /// where `requestFieldValues` may only carry the fields the REQUEST TYPE
    /// exposes on its portal form and an unknown field is a hard **400** rather
    /// than an ignored key — the failure that cost every ticket the platform tried
    /// to file (`The field 'labels' is not valid for this request type 'Problem'`).
    /// Do not add a field here because it looks available.
    ///
    /// - Parameter idempotencyKey: ⛔ **MINTED ONCE PER COMPOSED DRAFT, NEVER PER
    ///   ATTEMPT**, and that is what makes this the one write on this surface a
    ///   caller may repeat. The server claims the key before it calls Atlassian and
    ///   answers a re-used one with `{success:true, deduplicated:true}`, so a
    ///   retry that carries the SAME key collapses onto the first request; a retry
    ///   that mints a fresh one puts a second ticket in a human's queue. It is
    ///   Optional because an older client that omits it still works, just without
    ///   that protection — which is a compatibility allowance and not an invitation.
    ///
    /// ⚠️ RATE LIMITED 10/HOUR PER **WORKSPACE**, not per caller, plus a durable
    /// 5/day bound per requester hash that survives a Redis outage. A refusal is a
    /// **429** carrying the server's own sentence, which names the remedy (reply on
    /// an existing request) and should be shown verbatim.
    ///
    /// ⚠️ AN UNCONFIGURED DESK IS A **503**, NOT A 500, and its sentence points at
    /// the public form as a PATH (`/support/report`) rather than a host, because
    /// Canada's canonical host is distronode.ca. Show it as sent.
    static func createSupportRequest(
        workspaceId: String,
        kind: SupportRequestKind,
        subject: String,
        message: String,
        idempotencyKey: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .createSupportRequest,
            .post,
            DistrictPaths.supportRequests,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([
                ("kind", .string(kind.rawValue)),
                ("subject", .string(subject)),
                ("message", .string(message)),
                ("idempotencyKey", .optional(idempotencyKey)),
            ]))
        )
    }

    /// One request and its whole conversation.
    ///
    /// ⛔ THIS RETURNS FULL CONTENT, AND THAT IS CORRECT HERE. The neighbouring
    /// voice path `/api/internal/support-lookup` deliberately returns STATUS ONLY —
    /// no summary, no description, no comment body — because a phone call is
    /// authenticated by caller ID and caller ID is spoofable. This route is not
    /// that: it runs under the operator's own session bearer inside an
    /// authenticated app and is scoped by `requireWorkspaceRole`, so withholding
    /// the thread would leave the customer unable to read the answer they came for.
    /// Do not import the voice rule onto this surface.
    ///
    /// ⛔ **404, NEVER 403, FOR ANOTHER WORKSPACE'S REQUEST**, and the client must
    /// not try to distinguish them. The server answers "no such request", "not this
    /// workspace's request" and "erased" identically so that a sequential key like
    /// `DA-41` cannot be probed by anyone with a session and a loop.
    ///
    /// ⚠️ IT REFRESHES FROM ATLASSIAN ON READ rather than serving the local mirror,
    /// so it is slower than the list and a vendor outage degrades to the mirror
    /// instead of failing. Nothing here may poll it.
    ///
    /// - Parameter key: the Jira issue key (`DA-42`) **or** our own row id. Both
    ///   resolve, which is what makes a request that has not been filed yet
    ///   addressable at all.
    static func supportRequest(workspaceId: String, key: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .supportRequest,
            .get,
            DistrictPaths.supportRequest(key),
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Answer on a request.
    ///
    /// ⛔ **THE FIELD IS `body`.** The desk's reply route one family over spells the
    /// same idea `message`, and transposing them is a silent **400** on a screen
    /// whose whole job is to deliver a sentence to a human. The server route's Zod
    /// schema is `z.object({ body: … })`.
    ///
    /// ⛔ NOT IDEMPOTENT AND NEVER RETRIED AUTOMATICALLY. The reply is posted as a
    /// PUBLIC Jira comment, so a repeat leaves a second copy in the customer's own
    /// thread and notifies the agent twice. See ``SupportResubmit``.
    ///
    /// ⚠️ **409 MEANS THE REQUEST IS STILL BEING OPENED**, which is a state rather
    /// than a fault: we hold it, it has no Atlassian thread yet, and accepting the
    /// reply would silently drop the one message the customer wanted us to see. It
    /// deserves its own sentence and is worth showing the server's verbatim.
    ///
    /// ⚠️ Rate limited 30 per five minutes, keyed on workspace AND issue key.
    static func replyToSupportRequest(
        workspaceId: String,
        key: String,
        body: String
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .replyToSupportRequest,
            .post,
            DistrictPaths.supportRequestReply(key),
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([("body", .string(body))]))
        )
    }

    /// Close a request because the customer says it is resolved.
    ///
    /// ⛔ **NO BODY AT ALL**, and the workspace travels in the QUERY. The handler
    /// never calls `req.json()`, so a body would be ignored; sending one would be a
    /// client inventing a contract.
    ///
    /// ⛔ NOT IDEMPOTENT, AND THE REASON IS THE ORDER THE SERVER WORKS IN.
    /// `closeRequestAsRequester` resolves the done-category transition, then posts a
    /// PUBLIC audit comment naming who asked, then applies it — the comment first,
    /// deliberately, so the attribution survives a transition that fails. So a
    /// repeat that still finds a transition leaves a SECOND "Closed at the
    /// requester's request by …" in the customer's own thread. ⚠️ A repeat against
    /// an ALREADY-resolved request is harmless (no transition is found, so it
    /// returns 409 before commenting) — but which of the two a retry lands on is
    /// exactly what an ambiguous failure does not tell us. See ``SupportResubmit``.
    ///
    /// ⚠️ **409 `not-closeable` IS AN ANSWER, NOT AN ERROR.** The desk's workflow
    /// either offers no resolving transition or offers several, and in the second
    /// case picking one would decide on the customer's behalf whether their request
    /// was "done" or "won't do". The server's sentence names the way forward (reply
    /// and we will close it) and should be shown verbatim.
    ///
    /// ⚠️ THE REPLY CARRIES THE RESOLVED `statusName` AND THE CALLER SHOULD ADOPT
    /// IT. It is the desk's own word for the state, and the live workflow is
    /// localised — a client that substituted "Closed" would print English over a
    /// status Atlassian spells in another language.
    static func closeSupportRequest(workspaceId: String, key: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .closeSupportRequest,
            .post,
            DistrictPaths.supportRequestClose(key),
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }
}
