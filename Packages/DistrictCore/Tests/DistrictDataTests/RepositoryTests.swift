@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The overview, workspace, calls and contacts repositories.
///
/// ⚠️ THE INBOX LIVES IN `InboxRepositoryTests` AND `ThreadPageReaderTests`, not
/// because it is different in kind but because it is half the surface — the
/// composer alone is seven methods, three of which spend money — and SwiftLint's
/// file-length ceiling is 500 lines, which this file is already within 22 of.
final class RepositoryTests: XCTestCase {
    // MARK: - Overview

    /// ⛔ AN EMPTY `{}` MUST NOT READ AS FOUR CONFIDENT ZEROS. Typing the response
    /// is most of that defence now — `OverviewResponse` requires six keys — but
    /// the envelope guard is what catches the body that carries all six and says
    /// `success: false`.
    func testAnEmptyOverviewBodyIsADecodeFailure() async {
        let repository = OverviewRepository(client: .repositoryTest(RepositoryTransport(json: "{}")))

        let result = await repository.overview(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
    }

    /// ⛔ THE CASE THE TYPE ALONE CANNOT CATCH: every required key present, and
    /// the flag false. Without ``ResponseEnvelope/affirm(_:_:_:)`` this renders as
    /// a workspace that took no calls this week.
    func testAWellFormedOverviewThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let body = Bodies.overview().replacingOccurrences(of: #""success":true"#, with: #""success":false"#)
        let repository = OverviewRepository(client: .repositoryTest(RepositoryTransport(json: body)))

        let result = await repository.overview(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("OverviewResponse did not affirm success=true"))
    }

    func testAnOverviewDecodesItsMetricsAndRecentCalls() async {
        let transport = RepositoryTransport(json: Bodies.overview(totalCalls: 128, recentCallIds: ["call_1", "call_2"]))

        let result = await OverviewRepository(client: .repositoryTest(transport)).overview(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.metrics.totalCalls, 128)
        XCTAssertEqual(result.successOnly?.recentCalls.map(\.id), ["call_1", "call_2"])
        // ⛔ The server's own label, not a locally formatted duration: this tile
        // omits a zero minutes component where a call row always emits one.
        XCTAssertEqual(result.successOnly?.avgDurationLabel, "3m 12s")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/overview?workspaceId=ws_1"
        )
    }

    /// ⚠️ THE ECHOED WORKSPACE ID IS WHAT CATCHES A DRIFTED LOCAL SELECTION, which
    /// is the whole reason it is non-optional on the DTO.
    func testAnOverviewEchoesTheWorkspaceThatAnswered() async {
        let transport = RepositoryTransport(json: Bodies.overview(workspaceId: "ws_other"))

        let result = await OverviewRepository(client: .repositoryTest(transport)).overview(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.workspaceId, "ws_other")
    }

    /// ⚠️ Nil is legal and makes the SERVER choose. The request must then carry no
    /// `workspaceId` at all rather than an empty one.
    func testANilWorkspaceOmitsTheParameterEntirely() async {
        let transport = RepositoryTransport(json: Bodies.overview())

        _ = await OverviewRepository(client: .repositoryTest(transport)).overview(workspaceId: nil)

        XCTAssertEqual(transport.requestedURLs.first, "https://www.distronode.com/api/district/overview")
    }

    // MARK: - Workspaces

    /// ⛔ "WE COULD NOT LOOK" IS NOT "THERE IS NOTHING". A 503 `REGIONS_DEGRADED`
    /// rendered as an empty list routes a paying customer to an onboarding dead
    /// end.
    func testADegradedRegionListIsItsOwnCaseAndKeepsTheRegions() async {
        let body = #"{"error":"Some regions are unavailable","code":"REGIONS_DEGRADED","#
            + #""degradedRegions":["eu","apac"]}"#
        let transport = RepositoryTransport(json: body, status: 503)

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(
            result.failureOnly,
            .regionsDegraded(message: "Some regions are unavailable", regions: ["eu", "apac"])
        )
    }

    /// ⚠️ A PLAIN 503 FROM AN EDGE PROXY IS AN ORDINARY OUTAGE. Branching on the
    /// status alone would report degraded regions that were never named.
    func testAPlain503WithoutTheCodeIsAnOrdinaryFailure() async {
        let transport = RepositoryTransport(json: #"{"error":"Bad gateway"}"#, status: 503)

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.failureOnly, .api(.http(status: 503, message: "Bad gateway")))
    }

    /// ⛔ `degradedRegions` ON A **200** MEANS THE LIST IS PARTIAL. A client that
    /// handled the array only on the 503 path presents a partial account as the
    /// whole one.
    func testAPartialListIsASuccessThatSaysItIsPartial() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList(degradedRegions: ["apac"]))

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.successOnly?.degradedRegions, ["apac"])
        XCTAssertEqual(result.successOnly?.isPartial, true)
    }

    func testACompleteListIsNotPartial() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList())

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.successOnly?.isPartial, false)
    }

    func testAWorkspaceListThatDoesNotDecodeIsAFailure() async {
        let transport = RepositoryTransport(json: "{}")

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.failureOnly, .api(.decoding("WorkspaceListResponse did not decode")))
    }

    /// ⛔ THE STORED DEFAULT IS AN ID TO LOOK UP, NOT ONE TO SEND BLIND. The server
    /// echoes it without cross-checking, so it can name a workspace whose
    /// subscription has lapsed — and sending that id earns a 403 on a screen the
    /// user never touched.
    func testTheDefaultSelectionPrefersTheStoredChoiceWhenItIsStillInTheList() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList(
            entries: [Bodies.workspaceEntry(id: "ws_1"), Bodies.workspaceEntry(id: "ws_2", name: "South Studio")],
            defaultWorkspaceId: "ws_2"
        ))

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.successOnly?.defaultSelection?.id, "ws_2")
    }

    func testAStoredDefaultThatIsNoLongerInTheListFallsBackToIndexZero() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList(
            entries: [Bodies.workspaceEntry(id: "ws_1"), Bodies.workspaceEntry(id: "ws_2")],
            defaultWorkspaceId: "ws_gone"
        ))

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        // ⛔ Index 0 is the server's owned-first ordering, which is what the
        // browser treats as active. Re-sorting would make the two disagree.
        XCTAssertEqual(result.successOnly?.defaultSelection?.id, "ws_1")
    }

    func testAnAccountWithNoWorkspacesHasNoDefaultSelection() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList())

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertNil(result.successOnly?.defaultSelection)
        XCTAssertEqual(result.successOnly?.isBlockedByBilling, false)
    }

    /// ⛔ AN EMPTY LIST WITH A NON-ZERO `inactiveCount` IS A LAPSED ACCOUNT, NOT A
    /// NEW ONE. They need different screens, and this is the only thing that tells
    /// them apart.
    func testAnEmptyListWithWithheldWorkspacesIsALapsedAccount() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList(inactiveCount: 2))

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.successOnly?.isBlockedByBilling, true)
        XCTAssertEqual(result.successOnly?.response.inactiveCount, 2)
    }

    /// ⚠️ A DEGRADED BODY WITHOUT THE ARRAY STILL DEGRADES. The code is the
    /// contract; the region list is detail, and its absence must not turn a
    /// "we could not look" into an ordinary error.
    func testADegradedBodyWithNoRegionArrayStillReportsDegraded() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Some regions are unavailable","code":"REGIONS_DEGRADED"}"#,
            status: 503
        )

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(
            result.failureOnly,
            .regionsDegraded(message: "Some regions are unavailable", regions: [])
        )
    }

    /// ⚠️ NOTHING WAS SENT AT ALL — no credential — so there is no body to
    /// classify and the failure is carried through as-is.
    func testAWorkspaceListWithNoCredentialFailsWithoutClassifyingABody() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList())
        let client = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { nil }
        )

        let result = await WorkspaceRepository(client: client).list()

        XCTAssertEqual(result.failureOnly, .api(.http(status: 401, message: nil)))
        XCTAssertTrue(transport.requestedURLs.isEmpty)
    }

    func testAWorkspaceListTransportFailureIsCarriedThrough() async {
        let transport = RepositoryTransport([])

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        // The stub answers 500 once its queue is empty.
        XCTAssertEqual(result.failureOnly, .api(.http(status: 500, message: nil)))
    }

    // MARK: - Members

    func testTheRosterDecodesTyped() async {
        let body = #"""
        {"success":true,"members":[{"email":"ada@example.com","role":"agency","createdAt":"2026-08-01T00:00:00Z"}]}
        """#
        let transport = RepositoryTransport(json: body)

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).members(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.members.first?.email, "ada@example.com")
        XCTAssertEqual(result.successOnly?.members.first?.parsedRole, .agency)
    }

    /// ⛔ THE CASE THE TYPE ALONE CANNOT CATCH. `members` is non-optional, so `{}` is
    /// rejected anyway and a missing envelope check reads as harmless; but a
    /// well-formed body carrying `success:false` decodes cleanly and the settings
    /// screen draws the roster.
    /// ⚠️ The array is deliberately NON-EMPTY here: a fixture answering `[]` would
    /// pass against the broken code too, which is exactly how a happy-path-only test
    /// misses this class of defect.
    func testARosterThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let body = #"""
        {"success":false,"members":[{"email":"ada@example.com","role":"agency","createdAt":"2026-08-01T00:00:00Z"}]}
        """#
        let transport = RepositoryTransport(json: body)

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).members(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("MemberListResponse did not affirm success=true"))
        XCTAssertNil(result.successOnly, "an unaffirmed envelope must not hand a roster to the screen")
    }

    /// ⚠️ THE REMOVAL RESPONSE HAS NO `member` KEY, and it is the one response a
    /// client must not fail to decode — the row really is gone.
    func testARemovalWithNoEchoedMemberStillDecodes() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await WorkspaceRepository(client: .repositoryTest(transport))
            .removeMember(workspaceId: "ws_1", email: "ada@example.com")

        XCTAssertEqual(result.successOnly?.success, true)
        XCTAssertNil(result.successOnly?.member)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/members?workspaceId=ws_1&email=ada%40example.com"
        )
    }

    func testAddingAMemberSendsTheRoleWireValueAndDropsANilRole() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let repository = WorkspaceRepository(client: .repositoryTest(transport))

        _ = await repository.addMember(workspaceId: "ws_1", email: "ada@example.com", role: .viewer)

        let body = try XCTUnwrap(transport.requests.first?.body)
        XCTAssertEqual(
            try XCTUnwrap(String(bytes: body, encoding: .utf8)),
            #"{"email":"ada@example.com","role":"viewer","workspaceId":"ws_1"}"#
        )
    }

    func testChangingARoleAndRenamingUseTheirOwnRoutes() async {
        let transport = RepositoryTransport(queue: [
            #"{"success":true}"#,
            #"{"success":true,"name":"North Studio"}"#,
        ])
        let repository = WorkspaceRepository(client: .repositoryTest(transport))

        _ = await repository.changeMemberRole(workspaceId: "ws_1", email: "ada@example.com", role: .client)
        let renamed = await repository.rename(workspaceId: "ws_1", name: "  North Studio  ")

        // ⛔ The ECHOED, trimmed name is what a later read will see.
        XCTAssertEqual(renamed.successOnly?.name, "North Studio")
        XCTAssertEqual(transport.requestedURLs.last, "https://www.distronode.com/api/district/workspace/rename")
    }

    // MARK: - Calls

    /// ⛔ NO ENVELOPE ON THE CALL LOG — it is `NextResponse.json(calls)`, decoded
    /// as `[CallSummary]`. A `success` guard, or a DTO expecting an object, would
    /// reject every response the server sends.
    func testTheCallLogIsABareArrayAndPagesWithoutATotal() async {
        let transport = RepositoryTransport(json: Bodies.calls(ids: ["call_1", "call_2"]))
        let pager = CallsRepository(client: .repositoryTest(transport)).pager(workspaceId: "ws_1")

        let slice = await pager.loadNext(limit: 25)

        XCTAssertEqual(slice.successOnly?.items.map(\.id), ["call_1", "call_2"])
        XCTAssertEqual(slice.successOnly?.isEnd, true, "a short page is the only end signal available")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/calls?workspaceId=ws_1&limit=25&offset=0"
        )
    }

    /// ⛔ THE DEDUP SET IS WHAT STOPS A ROW ARRIVING TWICE, and on the calls feed
    /// it is the only thing that can: a call placed between two page loads shifts
    /// every window down and re-serves the boundary row.
    func testABoundaryRowRepeatedOnTheNextPageIsDeduplicated() async {
        let transport = RepositoryTransport(queue: [
            Bodies.calls(ids: ["call_1", "call_2"]),
            Bodies.calls(ids: ["call_2", "call_3"]),
        ])
        let pager = CallsRepository(client: .repositoryTest(transport)).pager(workspaceId: "ws_1")

        _ = await pager.loadNext(limit: 2)
        let second = await pager.loadNext(limit: 2)

        XCTAssertEqual(second.successOnly?.items.map(\.id), ["call_3"])
        // ⛔ The offset advanced by the RAW page size. Advancing by the
        // deduplicated count would re-request the row just dropped, forever.
        XCTAssertEqual(
            transport.requestedURLs.last,
            "https://www.distronode.com/api/district/calls?workspaceId=ws_1&limit=2&offset=2"
        )
    }

    func testACallLogThatIsNotAnArrayIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true,"calls":[]}"#)
        let pager = CallsRepository(client: .repositoryTest(transport)).pager(workspaceId: "ws_1")

        let slice = await pager.loadNext(limit: 25)

        XCTAssertEqual(slice.failureOnly?.isShapeMismatch, true)
    }

    func testCallDetailUnwrapsTheEnvelopeToTheFeedsOwnRow() async {
        let transport = RepositoryTransport(json: Bodies.callDetail(id: "call_1"))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(result.successOnly?.id, "call_1")
        XCTAssertEqual(result.successOnly?.callerName, "Ada Lovelace")
    }

    /// ⚠️ THE ENVELOPE IS ASSERTED BEFORE THE PAYLOAD IS EXAMINED, so a body whose
    /// flag is false reports "the server did not affirm success" rather than the
    /// more specific and more misleading "success response carried no call".
    func testCallDetailChecksTheEnvelopeBeforeThePayload() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await CallsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(result.failureOnly, .decoding("CallDetailResponse did not affirm success=true"))
    }

    /// ⚠️ A 2xx WITH NO `call` IS MALFORMED, NOT AN ABSENCE. Absence is a 404;
    /// reporting this as one would hide a server bug behind an empty state.
    func testCallDetailWithNoCallIsADecodeFailureNotAnAbsence() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await CallsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(result.failureOnly, .decoding("CallDetailResponse success response carried no call"))
    }

    /// ⛔ THE ENVELOPE MATTERS MOST HERE, because `""` is the legitimate value for
    /// a call with no transcript — a structurally wrong 200 would otherwise render
    /// as "nothing was said".
    func testAnAbsentTranscriptIsTheEmptyStringButAWrongEnvelopeIsAFailure() async {
        let ok = RepositoryTransport(json: #"{"success":true,"transcript":""}"#)
        let bad = RepositoryTransport(json: #"{"success":false,"transcript":""}"#)

        let empty = await CallsRepository(client: .repositoryTest(ok))
            .transcript(workspaceId: "ws_1", callId: "call_1")
        let broken = await CallsRepository(client: .repositoryTest(bad))
            .transcript(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(empty.successOnly, "")
        XCTAssertEqual(broken.failureOnly, .decoding("CallTranscriptResponse did not affirm success=true"))
    }

    func testATranscriptIsUnwrappedToItsString() async {
        let transport = RepositoryTransport(json: #"{"success":true,"transcript":"hello"}"#)

        let result = await CallsRepository(client: .repositoryTest(transport))
            .transcript(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(result.successOnly, "hello")
    }

    /// ⛔ THE RECORDING URL COMES FROM THE `Location` HEADER OF A 302 THAT IS NOT
    /// FOLLOWED, and it is perishable — resolve it at playback, never cache it.
    func testTheRecordingUrlIsTheRedirectTarget() async {
        let transport = RepositoryTransport(redirectTo: "https://storage.example.com/rec.mp3?sig=abc")

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recordingURL(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(result.successOnly, "https://storage.example.com/rec.mp3?sig=abc")
    }

    // MARK: - Contacts

    /// ⚠️ CONTACTS REPORTS A REAL `total`, so the end is KNOWN and a full final
    /// page costs no extra request — unlike the call log.
    func testContactsPagingUsesTheReportedTotal() async {
        let transport = RepositoryTransport(json: Bodies.contactPage(ids: ["c_1", "c_2"], total: 2, limit: 2))
        let pager = ContactsRepository(client: .repositoryTest(transport)).pager(workspaceId: "ws_1")

        let slice = await pager.loadNext(limit: 2)

        XCTAssertEqual(slice.successOnly?.items.map(\.id), ["c_1", "c_2"])
        XCTAssertEqual(slice.successOnly?.isEnd, true)
    }

    /// ⚠️ A FULL PAGE SHORT OF THE TOTAL KEEPS GOING. The pager stops on the
    /// total rather than on a short page here, which is the difference the
    /// contacts route's `total` buys.
    func testContactsPagingContinuesWhileTheTotalSaysThereIsMore() async {
        let transport = RepositoryTransport(json: Bodies.contactPage(ids: ["c_1", "c_2"], total: 9, limit: 2))
        let pager = ContactsRepository(client: .repositoryTest(transport)).pager(workspaceId: "ws_1")

        let slice = await pager.loadNext(limit: 2)

        XCTAssertEqual(slice.successOnly?.isEnd, false)
    }

    func testAContactPageThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let body = Bodies.contactPage(ids: [], total: 0)
            .replacingOccurrences(of: #""success":true"#, with: #""success":false"#)
        let transport = RepositoryTransport(json: body)
        let pager = ContactsRepository(client: .repositoryTest(transport)).pager(workspaceId: "ws_1")

        let slice = await pager.loadNext(limit: 25)

        XCTAssertEqual(slice.failureOnly, .decoding("ContactListResponse did not affirm success=true"))
    }

    func testAContactPageWithNoContactsKeyDoesNotDecode() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let pager = ContactsRepository(client: .repositoryTest(transport)).pager(workspaceId: "ws_1")

        let slice = await pager.loadNext(limit: 25)

        XCTAssertEqual(slice.failureOnly?.isShapeMismatch, true)
    }

    func testContactDetailUsesTheQueryParameterRouteAndUnwraps() async {
        let transport = RepositoryTransport(json: Bodies.contactDetail(id: "c_1"))

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.successOnly?.id, "c_1")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/contacts/get?workspaceId=ws_1&contactId=c_1"
        )
    }

    func testContactDetailWithNoContactIsADecodeFailureNotAnAbsence() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.failureOnly, .decoding("ContactDetailResponse success response carried no contact"))
    }

    /// ⚠️ THE VOICE AGENT WRITES THE LITERAL "Unknown" FOR A CALLER IT COULD NOT
    /// IDENTIFY, so a blank check alone leaves a list of rows all called Unknown.
    func testAnUnidentifiedContactHasNoDisplayName() async {
        let transport = RepositoryTransport(json: Bodies.contactDetail(id: "c_1")
            .replacingOccurrences(of: "Ada Lovelace", with: "Unknown"))

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertNil(result.successOnly?.displayName)
    }
}
