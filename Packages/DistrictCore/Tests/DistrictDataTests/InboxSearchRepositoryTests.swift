@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Full-content message search: the two bodies the route sends, the cap it
/// reports, and what a hit can and cannot be asked for.
///
/// ⛔ A FILE OF ITS OWN BECAUSE THERE IS NO FIXTURE BEHIND THIS ROUTE, WHICH MAKES
/// THESE TESTS THE ONLY PIN ON ITS SHAPE. Every other typed endpoint in this
/// repository is gated by the shared contract corpus through the strict contract
/// suite; the corpus mirrors the Kotlin client and that client has no search, so
/// there is nothing to gate against. The bodies below are written from the
/// server's search module and its route, and they are the artefact a
/// server change has to be diffed against. ⚠️ That also means they are worth
/// keeping VERBOSE: a body trimmed to the fields one assertion needs would stop
/// being a record of the wire shape.
final class InboxSearchRepositoryTests: XCTestCase {
    // MARK: - The two bodies the route sends

    /// ⛔ EVERY NULLABLE FIELD POPULATED. This is the shape a hit on a
    /// contact-resolved EMAIL takes, which is the only branch that carries all
    /// five of the route's nullable columns at once.
    func testAHitCarryingEveryNullableFieldDecodes() async {
        let transport = RepositoryTransport(json: Self.resolvedEmailHitBody)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        let hit = result.successOnly?.hits.first
        XCTAssertEqual(hit?.messageId, "m_1")
        XCTAssertEqual(hit?.threadKey, "contact:c_1")
        XCTAssertEqual(hit?.contactId, "c_1")
        XCTAssertEqual(hit?.contactName, "Ada Lovelace")
        XCTAssertEqual(hit?.contactEmail, "ada@contract.test")
        XCTAssertEqual(hit?.subject, "Re: your survey")
        XCTAssertEqual(hit?.type, "email")
        XCTAssertEqual(hit?.kind, "email")
        XCTAssertEqual(hit?.direction, "inbound")
        XCTAssertEqual(hit?.createdAt, "2026-08-19T09:41:00.000Z")
    }

    /// ⛔ AND THE SAME SHAPE WITH ALL FIVE NULLABLE COLUMNS EXPLICITLY NULL, which
    /// is an SMS from an address that resolved to no Contact row. `null` here is not
    /// a degenerate case: the route emits `contactId: null` for every unresolved
    /// counterpart, so this is the ORDINARY body for a workspace whose CRM is empty.
    func testAHitWithEveryNullableFieldNullDecodes() async {
        let transport = RepositoryTransport(json: Self.unresolvedSmsHitBody)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        let hit = result.successOnly?.hits.first
        XCTAssertEqual(hit?.messageId, "m_2")
        XCTAssertEqual(hit?.threadKey, "addr:14165550134")
        XCTAssertNil(hit?.contactId)
        XCTAssertNil(hit?.contactName)
        XCTAssertNil(hit?.contactEmail)
        XCTAssertNil(hit?.subject)
        XCTAssertNil(hit?.type)
    }

    /// ⛔ THE SHORT-QUERY BRANCH OMITS `limit` ENTIRELY, AND THIS IS THE TEST THE
    /// WHOLE OPTIONAL EXISTS FOR. A `q` under two characters answers
    /// `{"success":true,"results":[]}` — not `limit: null`, not `limit: 0`, ABSENT —
    /// so a non-optional `Int` would decode every ordinary response and then fail on
    /// the first person who types one letter. That failure would surface as "this
    /// version of the app could not read that response" on the commonest input there
    /// is.
    func testTheShortQueryBodyDecodesWithNoLimitKeyAtAll() async {
        let transport = RepositoryTransport(json: #"{"success":true,"results":[]}"#)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "a")

        XCTAssertEqual(result.successOnly?.hits.count, 0)
        XCTAssertNil(result.successOnly?.response.limit)
        // ⛔ AND IT IS NOT CAPPED. Nothing was searched, so nothing was truncated,
        // and a caption saying otherwise would be a claim about a query the server
        // never ran.
        XCTAssertEqual(result.successOnly?.isCapped, false)
    }

    // MARK: - The cap, reported rather than inferred

    /// ⚠️ A FULL PAGE MEANS OLDER MATCHES EXIST. There is no offset to page on, so
    /// this is a caption rather than a pager — the same signal `scanned`/`scanLimit`
    /// carries on the conversation list.
    func testAFullPageOfResultsIsCapped() async {
        let transport = RepositoryTransport(json: Self.results(count: 3, limit: 3))

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        XCTAssertEqual(result.successOnly?.hits.count, 3)
        XCTAssertEqual(result.successOnly?.isCapped, true)
    }

    func testAPartialPageOfResultsIsNotCapped() async {
        let transport = RepositoryTransport(json: Self.results(count: 2, limit: 30))

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        XCTAssertEqual(result.successOnly?.isCapped, false)
    }

    /// ⛔ SEVERAL HITS MAY SHARE ONE `threadKey` — the same conversation matched
    /// twice — so the list identity is the MESSAGE id. Keying on the thread would
    /// collapse rows the server deliberately sent separately, and a duplicate
    /// identifier in a SwiftUI `ForEach` is a rendering fault rather than a
    /// cosmetic repeat.
    func testTwoHitsInOneThreadStayTwoRows() async {
        let transport = RepositoryTransport(json: Self.results(count: 2, limit: 30))

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        XCTAssertEqual(result.successOnly?.hits.map(\.messageId), ["m_1", "m_2"])
        XCTAssertEqual(Set(result.successOnly?.hits.map(\.threadKey) ?? []), ["contact:c_1"])
    }

    // MARK: - The request

    /// ⚠️ FREE TEXT TYPED BY A PERSON, so the percent-encoding is the one thing
    /// about this URL that can be wrong. A permissive encoder leaves `+` literal and
    /// the server's form decoding reads it back as a space.
    func testTheQueryTravelsAsQAndIsPercentEncoded() async {
        let transport = RepositoryTransport(json: Self.results(count: 0, limit: 30))

        _ = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey +1 booking")

        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/messages/search?workspaceId=ws_1&q=survey%20%2B1%20booking"
        )
    }

    // MARK: - Failure mapping

    /// ⛔ THE CASE THE TYPE ALONE CANNOT CATCH: every required key present and the
    /// flag false. Without the envelope guard that renders as "no matches" for a
    /// search the server never completed, which is a failure wearing an absence's
    /// clothes on the one screen where an empty list is a plausible correct answer.
    func testASearchThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"results":[],"limit":30}"#)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        XCTAssertEqual(result.failureOnly, .decoding("MessageSearchResponse did not affirm success=true"))
    }

    /// ⚠️ A ROLE REFUSAL REACHES THE CALLER AS THE SERVER'S OWN SENTENCE. The route
    /// admits `viewer`, so a 403 here means the caller is not in the workspace at
    /// all rather than that they are read-only.
    func testAForbiddenSearchSurfacesTheServersOwnSentence() async {
        let body = #"{"success":false,"error":"You do not have access to this workspace."}"#
        let transport = RepositoryTransport(json: body, status: 403)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        XCTAssertEqual(
            result.failureOnly,
            .http(status: 403, message: "You do not have access to this workspace.")
        )
    }

    /// ⛔ A 2xx THIS BUILD CANNOT PARSE IS CONTRACT DRIFT, NOT AN EMPTY RESULT SET.
    /// Reported as ``ApiError/decoding(_:)`` so ``FailureText`` offers no retry: a
    /// second attempt returns the identical body.
    func testAResponseMissingResultsIsAShapeMismatch() async {
        let transport = RepositoryTransport(json: #"{"success":true,"limit":30}"#)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .search(workspaceId: "ws_1", query: "survey")

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
    }

    // MARK: - What a hit is allowed to be asked for

    /// ⚠️ THE CONTACT NAME WHEN THERE IS ONE.
    func testAResolvedHitDisplaysTheContactName() throws {
        XCTAssertEqual(try Self.hit(Self.resolvedEmailHitBody).displayName, "Ada Lovelace")
    }

    /// ⚠️ FALLS BACK TO THE RAW COUNTERPART, NEVER TO A PLACEHOLDER. An unresolved
    /// address IS the identity of that thread, and "Unknown" would hide the one fact
    /// available.
    func testAnUnresolvedHitDisplaysTheCounterpart() throws {
        XCTAssertEqual(try Self.hit(Self.unresolvedSmsHitBody).displayName, "+14165550134")
    }

    /// ⚠️ THE NAME COLUMN IS NULLABLE **AND** CAN HOLD AN EMPTY STRING, so a nil
    /// check alone lets a blank title through — a row with no visible identity at
    /// all, which reads as a rendering failure rather than as a missing name.
    func testABlankContactNameOnAHitFallsBackToTheCounterpart() throws {
        let body = Self.resolvedEmailHitBody.replacingOccurrences(of: "Ada Lovelace", with: "   ")

        XCTAssertEqual(try Self.hit(body).displayName, "ada@contract.test")
    }

    // MARK: - Marking a thread opened from a hit as read

    /// ⛔ PREFERS THE CONTACT ID, exactly as ``ThreadSelector/forConversation(_:)``
    /// does: it is exact, and it survives the address changing.
    func testAResolvedHitMarksReadOnItsContactId() throws {
        XCTAssertEqual(try ThreadSelector.forSearchHit(Self.hit(Self.resolvedEmailHitBody)), .contact("c_1"))
    }

    /// ⛔ AND THE FALLBACK IS THE COUNTERPART, NEVER ``MessageSearchHit/threadKey``.
    /// `addr:14165550134` sent whole as the address parameter matches no message row,
    /// so the write would succeed against nothing and the badge would never clear —
    /// a fix that looks exactly like the bug it replaced.
    func testAnUnresolvedHitMarksReadOnItsCounterpart() throws {
        let hit = try Self.hit(Self.unresolvedSmsHitBody)

        XCTAssertEqual(ThreadSelector.forSearchHit(hit), .address("+14165550134"))
        XCTAssertNotEqual(ThreadSelector.forSearchHit(hit), .address(hit.threadKey))
    }

    /// ⚠️ A PRESENT-BUT-BLANK CONTACT ID IS NOT A CONTACT ID. It reaches the route as
    /// `contactId=`, which is a different instruction from omitting it.
    func testABlankContactIdOnAHitFallsBackToTheCounterpart() throws {
        let body = Self.resolvedEmailHitBody.replacingOccurrences(of: #""contactId":"c_1""#, with: #""contactId":"""#)

        XCTAssertEqual(try ThreadSelector.forSearchHit(Self.hit(body)), .address("ada@contract.test"))
    }

    // MARK: - Helpers

    /// One hit on a contact-resolved EMAIL: every nullable column populated.
    private static let resolvedEmailHitBody = #"""
    {"success":true,"limit":30,"results":[
      {"messageId":"m_1","key":"ada@contract.test","threadKey":"contact:c_1",
       "counterpart":"ada@contract.test","kind":"email","contactId":"c_1",
       "contactName":"Ada Lovelace","contactEmail":"ada@contract.test",
       "body":"Following up on the survey you mentioned.","subject":"Re: your survey",
       "direction":"inbound","type":"email","createdAt":"2026-08-19T09:41:00.000Z"}]}
    """#

    /// One hit on an SMS from an address that resolved to no Contact: all five
    /// nullable columns explicitly `null`.
    private static let unresolvedSmsHitBody = #"""
    {"success":true,"limit":30,"results":[
      {"messageId":"m_2","key":"14165550134","threadKey":"addr:14165550134",
       "counterpart":"+14165550134","kind":"phone","contactId":null,
       "contactName":null,"contactEmail":null,
       "body":"Can we move the survey to Thursday?","subject":null,
       "direction":"inbound","type":null,"createdAt":"2026-08-19T09:41:00.000Z"}]}
    """#

    /// `count` hits in ONE thread, so the message-id keying is exercised rather
    /// than assumed.
    private static func results(count: Int, limit: Int) -> String {
        // ⚠️ A HALF-OPEN RANGE, so `count == 0` is an empty list rather than the
        // trap a closed `1 ... count` would be.
        let rows = (0 ..< count).map { offset in
            let index = offset + 1
            return #"""
            {"messageId":"m_\#(index)","key":"ada@contract.test","threadKey":"contact:c_1",
             "counterpart":"ada@contract.test","kind":"email","contactId":"c_1",
             "contactName":"Ada Lovelace","contactEmail":"ada@contract.test",
             "body":"survey \#(index)","subject":null,"direction":"outbound","type":"email",
             "createdAt":"2026-08-19T09:41:00.000Z"}
            """#
        }
        return #"{"success":true,"limit":\#(limit),"results":[\#(rows.joined(separator: ","))]}"#
    }

    /// ⚠️ DECODED DIRECTLY RATHER THAN READ BACK THROUGH THE REPOSITORY, so a
    /// display assertion fails on the thing it is about instead of on an unrelated
    /// envelope change.
    private static func hit(_ json: String) throws -> MessageSearchHit {
        try XCTUnwrap(JSONDecoder().decode(MessageSearchResponse.self, from: Data(json.utf8)).results.first)
    }
}
