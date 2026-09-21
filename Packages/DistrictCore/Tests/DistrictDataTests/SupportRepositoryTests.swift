import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Minimal, VALID bodies for the support surface.
///
/// ⚠️ NOT CONTRACT FIXTURES, AND THEY MUST NOT DRIFT INTO PRETENDING TO BE. They are
/// written from the route source to drive the repository's branches. The generated
/// `district-support-*.json` fixtures pin the real shapes, gated in
/// `ImplementedFixtures+DeskSupport.swift`. ⛔ Re-check these bodies against those
/// files if the support routes ever change.
enum SupportBodies {
    /// One list row, with every key the route's `WorkspaceTicketSummary` spread
    /// emits and nothing else.
    static func summary(
        id: String,
        issueKey: String? = "DA-42",
        statusName: String = "Waiting for support",
        statusCategory: String = "NEW",
        filed: Bool = true,
        source: String = "workspace",
        region: String = "us"
    ) -> String {
        // ⚠️ The key is sent as an explicit NULL while unfiled rather than being
        // omitted, because the route serialises the summary whole.
        let key = issueKey.map { #""\#($0)""# } ?? "null"
        return #"""
        {"issueKey":\#(key),"id":"\#(id)","subject":"Outbound calls failing",
         "statusName":"\#(statusName)","statusCategory":"\#(statusCategory)",
         "createdAt":"2026-09-06T09:41:00.000Z","updatedAt":"2026-09-06T10:02:00.000Z",
         "filed":\#(filed),"source":"\#(source)","region":"\#(region)"}
        """#
    }

    static func list(_ rows: [String]) -> String {
        #"{"success":true,"requests":[\#(rows.joined(separator: ","))]}"#
    }

    static func message(id: String, role: String = "agent") -> String {
        let author = role == "agent" ? "Distronode Support" : "You"
        return #"""
        {"id":"\#(id)","role":"\#(role)","author":"\#(author)","body":"Looking into it now.",
         "createdAt":"2026-09-06T10:02:00.000Z"}
        """#
    }

    /// One detail body: the summary's ten keys, plus `messages` and `closeable`.
    static func detail(
        id: String = "st_1",
        issueKey: String? = "DA-42",
        statusCategory: String = "NEW",
        filed: Bool = true,
        closeable: Bool = true,
        messages: [String] = []
    ) -> String {
        let key = issueKey.map { #""\#($0)""# } ?? "null"
        return #"""
        {"success":true,"request":{
         "issueKey":\#(key),"id":"\#(id)","subject":"Outbound calls failing",
         "statusName":"Waiting for support","statusCategory":"\#(statusCategory)",
         "createdAt":"2026-09-06T09:41:00.000Z","updatedAt":"2026-09-06T10:02:00.000Z",
         "filed":\#(filed),"source":"workspace","region":"us","closeable":\#(closeable),
         "messages":[\#(messages.joined(separator: ","))]}}
        """#
    }

    static let filed = #"{"success":true,"issueKey":"DA-42"}"#
    static let deduplicated = #"{"success":true,"deduplicated":true}"#
    static let pending = #"{"success":true,"pending":true}"#

    static func reply(id: String = "c_9") -> String {
        #"{"success":true,"message":\#(message(id: id, role: "customer"))}"#
    }

    static let closed = #"{"success":true,"statusName":"完成"}"#

    /// ⚠️ THE 503 THE ROUTE ANSWERS WHEN THE DESK IS UNCONFIGURED. Its sentence
    /// names a PATH rather than a host, deliberately: Canada's canonical host is
    /// distronode.ca, so a hardcoded distronode.com would send a workspace served
    /// there to the wrong origin.
    static let unconfigured = #"""
    {"success":false,"error":"Support requests are temporarily unavailable here. \#(formPath)"}
    """#

    static let formPath = "The support form at /support/report still records your request while we catch up."

    /// ⚠️ The reply route's 409: the request is real and we hold it, it just has no
    /// Atlassian thread yet.
    static let notFiledYet = #"""
    {"success":false,"error":"This request is still being opened. Please try again in a moment."}
    """#
}

/// The tenant's own support requests with Distronode.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT OUTCOMES THAT LOOK ALIKE AND MEAN OPPOSITE
/// THINGS. An empty request list and a failed read are the same picture and must
/// never be the same value — that conflation is what told a web customer with three
/// open tickets that they had none. The three 200 branches of the create are all
/// successes and one of them reads like an error. And a failed write's
/// repeatability is a claim about whether a second public comment lands in somebody
/// else's thread.
final class SupportRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SupportRepository {
        SupportRepository(client: .repositoryTest(transport))
    }

    // MARK: - The list

    func testListingRequestsGetsTheSupportRouteAndAnswersTheRows() async {
        let transport = RepositoryTransport(
            json: SupportBodies.list([
                SupportBodies.summary(id: "st_1"),
                SupportBodies.summary(id: "st_2", issueKey: "DA-43", source: "voice-call", region: "eu"),
            ])
        )

        let result = await repository(transport).requests(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["st_1", "st_2"])
        XCTAssertEqual(result.successOnly?.map(\.issueKey), ["DA-42", "DA-43"])
        XCTAssertEqual(result.successOnly?.map(\.source), ["workspace", "voice-call"])
        XCTAssertEqual(result.successOnly?.map(\.region), ["us", "eu"])
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/support/requests?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a GET carries no body")
    }

    /// ⛔ AN EMPTY LIST IS A SUCCESS. Every workspace starts here, and this is the
    /// state the empty-queue copy is written for.
    func testAnEmptyRequestListIsASuccessRatherThanAFailure() async {
        let transport = RepositoryTransport(json: SupportBodies.list([]))

        let result = await repository(transport).requests(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isEmpty, true)
        XCTAssertNil(result.failureOnly)
    }

    /// ⛔ THE ENVELOPE CHECK IS THE WHOLE POINT ON THIS SURFACE. A required field
    /// rejects `{}` but not a well-formed `success: false`, which is what this
    /// route's catch branch produces once the headers are written — and "we could
    /// not look" rendered as "you have no support requests" is the exact failure the
    /// web shipped: a customer with three open tickets was told they had none and
    /// stopped chasing.
    func testARequestListThatDoesNotAffirmSuccessIsADecodeFailureNotAnEmptyList() async {
        let transport = RepositoryTransport(json: #"{"success":false,"requests":[]}"#)

        let result = await repository(transport).requests(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("SupportRequestListResponse did not affirm success=true"))
        XCTAssertNil(result.successOnly, "a refused envelope must never arrive as an empty history")
    }

    /// ⚠️ THE READ EXCLUDES `viewer` SERVER-SIDE, unlike most reads on this client,
    /// so a 403 here is an ordinary role refusal rather than a broken client. It
    /// must keep its status so the UI can word it as permission rather than offering
    /// a retry that returns the same answer.
    func testARefusedListAndAnExpiredSessionKeepTheirStatuses() async {
        let forbidden = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)
        let refused = await repository(forbidden).requests(workspaceId: "ws_1")
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).requests(workspaceId: "ws_1")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)
        XCTAssertNil(unauthorized.successOnly)
    }

    // MARK: - One request

    /// ⛔ FULL CONTENT, WHICH IS CORRECT HERE AND WRONG ONE SURFACE OVER. The voice
    /// path returns status only because a phone call is authenticated by spoofable
    /// caller ID; this one runs under the operator's own bearer, so the thread is
    /// the answer they opened the screen for.
    func testReadingOneRequestCarriesTheWholeThread() async {
        let transport = RepositoryTransport(
            json: SupportBodies.detail(
                messages: [
                    SupportBodies.message(id: "c_1", role: "customer"),
                    SupportBodies.message(id: "c_2", role: "agent"),
                ]
            )
        )

        let result = await repository(transport).request(workspaceId: "ws_1", key: "DA-42")

        XCTAssertEqual(result.successOnly?.messages.map(\.id), ["c_1", "c_2"])
        XCTAssertEqual(result.successOnly?.messages.map(\.body), ["Looking into it now.", "Looking into it now."])
        XCTAssertEqual(result.successOnly?.messages.map(\.author), ["You", "Distronode Support"])
        XCTAssertEqual(result.successOnly?.closeable, true)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/support/requests/DA-42?workspaceId=ws_1"
        )
    }

    /// ⚠️ A FRESHLY FILED REQUEST HAS NO COMMENTS: the description the customer
    /// typed is the ticket's own body rather than a message. So the commonest thread
    /// a new customer opens is empty, and that must read as a state.
    func testAThreadWithNoMessagesIsAStateRatherThanAFailure() async {
        let transport = RepositoryTransport(json: SupportBodies.detail())

        let result = await repository(transport).request(workspaceId: "ws_1", key: "DA-42")

        XCTAssertEqual(result.successOnly?.messages.isEmpty, true)
        XCTAssertNil(result.failureOnly)
    }

    /// ⛔ AN UNFILED REQUEST IS ADDRESSABLE BY OUR OWN ROW ID AND CARRIES A NULL
    /// KEY. That is the window between the local claim and the Atlassian call, and
    /// it is a real row a customer can see: `filed` is what says which side of the
    /// line it is on, and the reply box is gated on it rather than on the key.
    func testAnUnfiledRequestKeepsItsNullKeyAndIsAddressableByRowId() async {
        let transport = RepositoryTransport(
            json: SupportBodies.detail(
                id: "st_7",
                issueKey: nil,
                statusCategory: "PENDING",
                filed: false,
                closeable: false
            )
        )

        let result = await repository(transport).request(workspaceId: "ws_1", key: "st_7")

        XCTAssertNil(result.successOnly?.issueKey)
        XCTAssertEqual(result.successOnly?.filed, false)
        XCTAssertEqual(result.successOnly?.closeable, false)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/support/requests/st_7?workspaceId=ws_1"
        )
    }

    /// ⛔ 404 COVERS "NO SUCH REQUEST", "NOT YOURS" AND "ERASED" IDENTICALLY, BY
    /// DESIGN, so that a sequential key cannot be probed. The client must carry the
    /// status through rather than trying to word them apart.
    func testAMissingRequestArrivesAsA404AndNothingElse() async {
        let transport = RepositoryTransport(json: #"{"success":false,"error":"Not found"}"#, status: 404)

        let result = await repository(transport).request(workspaceId: "ws_1", key: "DA-99")

        XCTAssertEqual(result.failureOnly, .http(status: 404, message: "Not found"))
    }

    /// ⚠️ A 200 WITH NO `request` IS DRIFT, and failing to decode is the right
    /// verdict: handing a screen an empty request would draw a ticket that does not
    /// exist.
    func testADetailBodyWithNoRequestIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).request(workspaceId: "ws_1", key: "DA-42")

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
    }

    // MARK: - Raising one

    /// ⛔ THE KIND IS MAPPED SERVER-SIDE AND THE BODY CARRIES EXACTLY FOUR KEYS.
    /// Adding a field to a create payload on this desk is a hard 400 rather than an
    /// ignored key, so the encoded bytes are the assertion worth having.
    func testRaisingARequestSendsTheClosedKindAndTheIdempotencyKey() async {
        let transport = RepositoryTransport(json: SupportBodies.filed)

        let result = await repository(transport).create(
            workspaceId: "ws_1",
            kind: .question,
            subject: "How do I add a number",
            message: "I cannot find it.",
            idempotencyKey: "4f1c8f2e-0f2a-4a7c-8b1e-2f0a9c3d5e77"
        )

        XCTAssertEqual(result.successOnly, .filed(issueKey: "DA-42"))
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/support/requests?workspaceId=ws_1"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"idempotencyKey":"4f1c8f2e-0f2a-4a7c-8b1e-2f0a9c3d5e77","kind":"question","#
                + #""message":"I cannot find it.","subject":"How do I add a number"}"#
        )
    }

    /// ⛔ AN ABSENT KEY IS DROPPED RATHER THAN SENT AS NULL. The route validates it
    /// with `z.string().uuid().optional()`, so an explicit null fails the parse and
    /// 400s a request that would otherwise have been filed.
    func testAnAbsentIdempotencyKeyIsDroppedNotSentAsNull() async {
        let transport = RepositoryTransport(json: SupportBodies.filed)

        _ = await repository(transport).create(
            workspaceId: "ws_1",
            kind: .suggestion,
            subject: "A smaller dialer",
            message: "It would help.",
            idempotencyKey: nil
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"kind":"suggestion","message":"It would help.","subject":"A smaller dialer"}"#
        )
    }

    /// ⛔ ALL THREE 200 BRANCHES ARE SUCCESSES AND `deduplicated` IS THE ONE THAT
    /// READS LIKE AN ERROR. It means the idempotency key did its job; reporting it
    /// as a failure is what invites a third attempt into a human's queue.
    func testTheThreeFilingOutcomesAreAllSuccessesAndStayDistinct() async {
        let filed = RepositoryTransport(json: SupportBodies.filed)
        let deduplicated = RepositoryTransport(json: SupportBodies.deduplicated)
        let pending = RepositoryTransport(json: SupportBodies.pending)

        let one = await repository(filed).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )
        let two = await repository(deduplicated).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )
        let three = await repository(pending).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )

        XCTAssertEqual(one.successOnly, .filed(issueKey: "DA-42"))
        XCTAssertEqual(two.successOnly, .deduplicated)
        XCTAssertEqual(three.successOnly, .pending)
    }

    /// ⛔ AN UNCLASSIFIABLE 200 FALLS THROUGH TO `pending` RATHER THAN TO A FAILURE,
    /// AND THAT IS THE SAFE DIRECTION RATHER THAN A DEFAULT. Every branch of this
    /// route that answers 200 has already written the claim row, so "we have your
    /// request" is still true; reporting drift as a failure would tell a customer
    /// their request was lost when it was not, and they would send it again.
    ///
    /// ⚠️ An empty-string key takes the same path, because a key that cannot address
    /// a request is not a key.
    func testAnUnclassifiableFilingReadsAsPendingRatherThanAsAFailure() async {
        let bare = RepositoryTransport(json: #"{"success":true}"#)
        let blank = RepositoryTransport(json: #"{"success":true,"issueKey":""}"#)

        let one = await repository(bare).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )
        let two = await repository(blank).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )

        XCTAssertEqual(one.successOnly, .pending)
        XCTAssertEqual(two.successOnly, .pending)
    }

    /// ⚠️ THE 429 AND THE 503 BOTH CARRY A SENTENCE THE SERVER AUTHORED, and both
    /// name the way forward. They must reach the screen with their status intact so
    /// the caller can show them verbatim rather than replacing them.
    func testTheRateLimitAndTheUnconfiguredDeskKeepTheirOwnSentences() async {
        let limited = RepositoryTransport(
            json: #"{"success":false,"error":"You have opened several requests in the last hour."}"#,
            status: 429
        )
        let capped = await repository(limited).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )
        XCTAssertEqual(capped.failureOnly?.httpStatus, 429)
        XCTAssertEqual(capped.failureOnly?.message, "You have opened several requests in the last hour.")

        let down = RepositoryTransport(json: SupportBodies.unconfigured, status: 503)
        let unavailable = await repository(down).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )
        XCTAssertEqual(unavailable.failureOnly?.httpStatus, 503)
        XCTAssertEqual(unavailable.failureOnly?.message?.contains("/support/report"), true)
    }

    // MARK: - Replying

    /// ⛔ THE FIELD IS `body`. The desk's reply one family over takes `message`, and
    /// transposing them is a silent 400 on the one control whose job is to deliver a
    /// sentence to a human.
    func testAReplySendsBodyAndAdoptsTheEchoedMessage() async {
        let transport = RepositoryTransport(json: SupportBodies.reply(id: "c_9"))

        let result = await repository(transport).reply(
            workspaceId: "ws_1",
            key: "DA-42",
            body: "It is still happening."
        )

        XCTAssertEqual(result.successOnly?.id, "c_9")
        XCTAssertEqual(result.successOnly?.author, "You")
        XCTAssertEqual(result.successOnly?.knownRole, .customer)
        XCTAssertEqual(transport.bodies.first, #"{"body":"It is still happening."}"#)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/support/requests/DA-42/reply?workspaceId=ws_1"
        )
    }

    /// ⚠️ THE 409 IS A STATE: the request exists and we hold it, it simply has no
    /// Atlassian thread yet. Accepting the reply would have dropped the message.
    func testAReplyOnAnUnfiledRequestArrivesAsA409WithItsSentence() async {
        let transport = RepositoryTransport(json: SupportBodies.notFiledYet, status: 409)

        let result = await repository(transport).reply(workspaceId: "ws_1", key: "st_7", body: "Hello.")

        XCTAssertEqual(result.failureOnly?.httpStatus, 409)
        XCTAssertEqual(result.failureOnly?.message?.contains("still being opened"), true)
    }

    // MARK: - Closing

    /// ⛔ THE DESK'S OWN WORD IS ADOPTED. A desk workflow can be localised — its
    /// transitions can read `完成` — so a client that printed
    /// "Closed" would put English over a status Atlassian spells otherwise.
    ///
    /// ⛔ AND THE CLOSE CARRIES NO BODY. The handler never reads one.
    func testClosingAdoptsTheDesksOwnStatusNameAndSendsNoBody() async {
        let transport = RepositoryTransport(json: SupportBodies.closed)

        let result = await repository(transport).close(workspaceId: "ws_1", key: "DA-42")

        XCTAssertEqual(result.successOnly, "完成")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertTrue(transport.bodies.isEmpty, "the close handler never reads a body")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/support/requests/DA-42/close?workspaceId=ws_1"
        )
    }

    /// ⚠️ `not-closeable` IS AN ANSWER RATHER THAN AN ERROR: the workflow offers no
    /// single resolving transition, or offers several, and choosing one would decide
    /// on the customer's behalf whether their request was done or won't-do.
    func testARequestTheWorkflowWillNotCloseArrivesAsA409() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"This request cannot be closed from here."}"#,
            status: 409
        )

        let result = await repository(transport).close(workspaceId: "ws_1", key: "DA-42")

        XCTAssertEqual(result.failureOnly?.httpStatus, 409)
        XCTAssertEqual(result.failureOnly?.message?.contains("cannot be closed from here"), true)
    }

    /// ⛔ A 200 THAT DOES NOT AFFIRM SUCCESS IS DRIFT ON EVERY WRITE HERE, AND ON
    /// THE CLOSE IT IS THE ONE THAT MATTERS MOST: the decode failure is what tells
    /// the caller the audit comment IS in the thread, so the control must not come
    /// back. See ``SupportResubmit``.
    func testAWriteThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let refusedClose = RepositoryTransport(json: #"{"success":false,"statusName":"Open"}"#)
        let closed = await repository(refusedClose).close(workspaceId: "ws_1", key: "DA-42")
        XCTAssertEqual(closed.failureOnly, .decoding("SupportCloseResponse did not affirm success=true"))

        let refusedReply = RepositoryTransport(
            json: #"{"success":false,"message":\#(SupportBodies.message(id: "c_1"))}"#
        )
        let replied = await repository(refusedReply).reply(workspaceId: "ws_1", key: "DA-42", body: "x")
        XCTAssertEqual(replied.failureOnly, .decoding("SupportReplyResponse did not affirm success=true"))

        let refusedCreate = RepositoryTransport(json: #"{"success":false,"issueKey":"DA-42"}"#)
        let created = await repository(refusedCreate).create(
            workspaceId: "ws_1", kind: .problem, subject: "A", message: "B", idempotencyKey: nil
        )
        XCTAssertEqual(
            created.failureOnly,
            .decoding("SupportRequestCreateResponse did not affirm success=true")
        )
    }
}
