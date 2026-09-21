import DistrictModel
import DistrictNetwork
import Foundation

/// Whether sending one of these writes a second time is the same write a second
/// time.
///
/// ⛔ A PROPERTY OF THE CALL, DECLARED AT THE CALL SITE, because only the caller
/// knows which call it is making. Each method on ``SupportRepository`` states its
/// answer in its own doc comment and they are copied to the call site rather than
/// guessed.
///
/// ⚠️ IT IS NOT "IS THIS SCARY". Closing a request is the calmest-sounding control
/// on the screen and is ``once``; raising a whole new request is the loudest and is
/// ``idempotent``, because it carries an idempotency key and the server claims it.
public enum SupportWriteRepeat: Sendable {
    /// Safe to send again: the server converges, or the request carries a key it
    /// deduplicates on.
    case idempotent

    /// ⛔ A REPEAT MAY LEAVE A SECOND VISIBLE MESSAGE IN A CUSTOMER'S OWN THREAD.
    /// Both entries here post a PUBLIC Jira comment: the reply posts the customer's
    /// own text, always; and the close posts an audit note naming who asked BETWEEN
    /// finding the resolving transition and applying it, so a repeat that still
    /// finds one posts a second "Closed at the requester's request by …".
    case once
}

/// Whether a failed write may be sent again from the control it failed in.
///
/// ⛔ THE CONSERVATIVE RULE: A REPEAT IS OFFERED ONLY WHEN THE FAILURE **PROVES**
/// THE WRITE DID NOT HAPPEN, never when it merely might not have. The three
/// ``ApiError`` cases are not equally informative and that asymmetry is the whole
/// decision:
///
///   - `.http` in 400...499 is the server having REFUSED. It reached that decision
///     before it did any work (the role guard, the Zod parse, a missing row, the
///     rate limiter), so nothing was posted. A repeat is honest.
///   - `.http` at 500 and above is the server having THROWN, which it can do while
///     posting the comment, after posting it, or while serialising the answer to
///     one that landed. Ambiguous.
///   - `.transport` is no answer at all, which is the lost-response case. Ambiguous.
///   - `.decoding` is NOT ambiguous and is the one that reads as harmless. It is
///     only ever produced from a **2xx** — `ApiErrorNormalizer` guards on
///     `isSuccess`, and every site below is an envelope check downstream of one —
///     so the server answered success and the comment IS in the thread. A repeat
///     posts a second one, guaranteed rather than possibly.
///
/// ⚠️ A 3xx CANNOT REACH `(400 ..< 500)` AND THAT IS DELIBERATE.
/// `ApiErrorNormalizer` maps anything outside 2xx to `.http`, so an unfollowed
/// redirect arrives as `.http(302, …)` and is treated as ambiguous, which is the
/// safe direction for a status nobody on this surface has reasoned about.
///
/// ⚠️ THE SAME RULE IS RESTATED FOR THE NUMBER PROVISIONING WRITES, AND THAT IS
/// WORTH KNOWING RATHER THAN HIDING. See the ⚠️ in `NumbersRepository+Provisioning.swift`
/// on why the two are not consolidated yet.
public enum SupportResubmit: Sendable {
    case allowed

    /// The control is gone and the only way on is a fresh look at the thread.
    case refused
}

public extension SupportResubmit {
    var isAllowed: Bool {
        switch self {
        case .allowed:
            true
        case .refused:
            false
        }
    }

    /// What a failed write leaves behind. See the ⛔ on the type.
    static func after(_ error: ApiError, _ repeatable: SupportWriteRepeat) -> SupportResubmit {
        guard case .once = repeatable else { return .allowed }
        guard let status = error.httpStatus, (400 ..< 500).contains(status) else { return .refused }
        return .allowed
    }
}

/// The tenant's own support requests **with Distronode**: the list, one thread,
/// and the three things that can be done to one.
///
/// ⛔ THIS IS NOT THE DESK. `district/support/*` is the customer raising something
/// with US; `district/desk/*` is their customers raising something with THEM. The
/// two families speak of requests, threads and replies in the same words and are
/// one path segment apart, so nothing here may be pointed at the desk to "reuse a
/// route" and nothing here may be described with a noun that could mean either.
///
/// ⛔ EVERY ROUTE EXCLUDES `viewer`, INCLUDING THE READS, which is the opposite
/// split from `workspace/knowledge` and `workspace/messaging` on this same client.
/// The route's own header gives the reason: these payloads are support
/// correspondence rather than operational status. So a viewer must not be OFFERED
/// the destination — a screen gated only at its controls would walk them into a
/// 403 on the very first read.
///
/// ⛔ FULL CONTENT IS CORRECT HERE, AND THE NEIGHBOURING RULE THAT SAYS OTHERWISE
/// BELONGS TO A DIFFERENT SURFACE. `/api/internal/support-lookup` (the VOICE path)
/// returns status and never a summary, a description or a comment body, because a
/// phone call is authenticated by spoofable caller ID. This client authenticates
/// with the operator's own session bearer inside an authenticated app, so
/// withholding the thread would make the screen useless without protecting
/// anything. Do not import the voice rule.
///
/// ⛔ TWO OF THE THREE WRITES ARE NOT IDEMPOTENT AND NOTHING HERE RETRIES
/// ANYTHING. The reply posts a public comment into a live human queue; the close
/// posts an audit comment between finding the resolving transition and applying
/// it, so a repeat that still finds one leaves a second note in a customer's own
/// thread. See
/// ``SupportResubmit``, which is what a caller uses to decide whether the control
/// may come back after a failure.
///
/// ⚠️ NO CACHE. A support thread is opened to find out whether somebody has
/// answered yet, which is the one question a stale copy is worst at — and the
/// detail route deliberately refreshes from Atlassian on read for that reason.
public struct SupportRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Every request this workspace has raised, newest first.
    ///
    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND A FAILED READ IS NOT ONE, AND THIS IS
    /// THE SURFACE WHERE CONFUSING THEM COSTS THE MOST. The web returned `[]` for
    /// every failure until it was found rendering "No support requests yet" to a
    /// customer with three open tickets, who then stopped chasing and whose request
    /// nobody here ever saw. The envelope check is what makes the two different
    /// values: a required field rejects `{}` but not a well-formed
    /// `success: false`, which is exactly what this route's catch branch produces
    /// once the headers are written.
    ///
    /// ⚠️ CAPPED AT 100 ROWS SERVER-SIDE AND NOT PAGED. There is no cursor to send,
    /// so a workspace past the cap silently does not see its oldest requests.
    public func requests(workspaceId: String) async -> Result<[SupportRequestSummary], ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.supportRequests(workspaceId: workspaceId),
            as: SupportRequestListResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("SupportRequestListResponse", $0.success, $0) }
            .map(\.requests)
    }

    /// One request and its whole conversation.
    ///
    /// ⛔ A **404** MEANS "NO SUCH REQUEST FOR THIS WORKSPACE" AND THE THREE THINGS
    /// IT COVERS ARE NOT SEPARABLE FROM HERE, BY DESIGN. The server answers "no such
    /// request", "not this workspace's request" and "erased" identically so that a
    /// sequential key like `DA-41` reveals nothing to anyone with a session and a
    /// loop. A caller must not try to word them apart.
    ///
    /// ⚠️ SLOWER THAN THE LIST ON PURPOSE: it refreshes from Atlassian rather than
    /// serving the local mirror, because someone opening their own ticket has
    /// usually just been told there is a reply. A vendor failure degrades to the
    /// mirror server-side rather than erroring. ⛔ Nothing may poll it.
    ///
    /// - Parameter key: the issue key (`DA-42`) **or** our own row id. Both resolve
    ///   server-side, which is what makes an unfiled request addressable at all.
    public func request(
        workspaceId: String,
        key: String
    ) async -> Result<SupportRequestDetail, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.supportRequest(workspaceId: workspaceId, key: key),
            as: SupportRequestDetailResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("SupportRequestDetailResponse", $0.success, $0) }
            .map(\.request)
    }

    /// Raise a new request.
    ///
    /// ⛔ THE ONE WRITE HERE A CALLER MAY REPEAT, AND ONLY IF IT SENDS THE SAME
    /// ``idempotencyKey``. The server claims the key before it calls Atlassian and
    /// answers a re-used one with `deduplicated: true`, so a retry carrying the same
    /// key collapses onto the first request — and a retry that mints a fresh one
    /// puts a second ticket in a human's queue. Mint it once per composed draft.
    ///
    /// ⛔ ALL THREE 200 BRANCHES ARE SUCCESSES AND ``SupportRequestFiling`` IS WHAT
    /// KEEPS THEM APART. `deduplicated` in particular must not be worded as a
    /// failure: it means the key did its job, and telling the operator something
    /// went wrong is what invites a third attempt.
    ///
    /// ⛔ THE BODY IS EXACTLY FOUR KEYS AND MUST NOT GROW. This is backed by a real
    /// Atlassian service desk where a request type accepts only the fields its
    /// portal form exposes and an unknown field is a hard **400** rather than an
    /// ignored key — which is what stopped every ticket the platform tried to file
    /// (`The field 'labels' is not valid for this request type 'Problem'`). The
    /// mapping from `kind` to a request type id is the server's and stays there.
    ///
    /// ⚠️ A **429** IS THE RATE LIMITER (10/hour per WORKSPACE, plus a durable 5/day
    /// per requester) and a **503** IS AN UNCONFIGURED DESK. Both carry a sentence
    /// the server authored that names the way forward, so both are worth showing
    /// verbatim rather than replacing with a generic failure.
    public func create(
        workspaceId: String,
        kind: SupportRequestKind,
        subject: String,
        message: String,
        idempotencyKey: String?
    ) async -> Result<SupportRequestFiling, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.createSupportRequest(
                workspaceId: workspaceId,
                kind: kind,
                subject: subject,
                message: message,
                idempotencyKey: idempotencyKey
            ),
            as: SupportRequestCreateResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("SupportRequestCreateResponse", $0.success, $0) }
            .map(\.filing)
    }

    /// Answer on a request.
    ///
    /// ⛔ THE FIELD IS `body`, AND THE DESK'S REPLY ONE FAMILY OVER SPELLS THE SAME
    /// IDEA `message`. Transposing them is a silent **400** on the one control whose
    /// entire job is to deliver a sentence to a human. The descriptor is what pins
    /// it; nothing here may assemble a body of its own.
    ///
    /// ⛔ NOT IDEMPOTENT, AND NOTHING RETRIES IT — not here and not above. The reply
    /// is posted as a PUBLIC Jira comment so it reaches the agent working the queue,
    /// which means a repeat is a second copy in the customer's own thread and a
    /// second notification. A caller that has to decide whether to re-arm its send
    /// control asks ``SupportResubmit/after(_:_:)`` with ``SupportWriteRepeat/once``.
    ///
    /// ⛔ THE ECHOED MESSAGE IS THE ANSWER AND SHOULD BE APPENDED RATHER THAN THE
    /// TYPED TEXT. It carries Atlassian's own comment id and the server's timestamp,
    /// so a thread built from it agrees with the next read; one built from the local
    /// draft does not.
    ///
    /// ⚠️ A **409** IS A STATE RATHER THAN A FAULT: the request is real and we hold
    /// it, it simply has no Atlassian thread yet. The server's sentence says so and
    /// is worth showing as sent.
    public func reply(
        workspaceId: String,
        key: String,
        body: String
    ) async -> Result<SupportMessage, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.replyToSupportRequest(workspaceId: workspaceId, key: key, body: body),
            as: SupportReplyResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("SupportReplyResponse", $0.success, $0) }
            .map(\.message)
    }

    /// Close a request because the customer says it is resolved.
    ///
    /// ⛔ NOT IDEMPOTENT IN THE ONLY WAY THAT MATTERS TO A CUSTOMER. The transition
    /// itself converges, but the server posts a PUBLIC audit comment naming who
    /// asked BETWEEN resolving that transition and applying it — deliberately, so
    /// the attribution survives a transition that then fails — so a repeat that
    /// still finds a transition leaves a second "Closed at the requester's request
    /// by …" in a thread they read. Pair it with ``SupportWriteRepeat/once``.
    ///
    /// ⛔ RETURNS THE DESK'S OWN `statusName` AND THE CALLER ADOPTS IT. The live
    /// workflow is localised, so substituting "Closed" would print English over a
    /// status Atlassian spells in another language.
    ///
    /// ⚠️ A **409** HERE IS `not-closeable` AND IS AN ANSWER RATHER THAN AN ERROR:
    /// the workflow offers no single resolving transition, or offers several, and
    /// picking one would decide on the customer's behalf whether their request was
    /// "done" or "won't do". The server's sentence names the way forward.
    ///
    /// ⚠️ THERE IS NO REOPEN, HERE OR SERVER-SIDE. Replying on a closed request is
    /// the supported path and the agent reopens if it warrants it.
    public func close(workspaceId: String, key: String) async -> Result<String, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.closeSupportRequest(workspaceId: workspaceId, key: key),
            as: SupportCloseResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("SupportCloseResponse", $0.success, $0) }
            .map(\.statusName)
    }
}
