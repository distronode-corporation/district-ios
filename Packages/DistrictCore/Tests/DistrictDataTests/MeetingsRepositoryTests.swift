import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The meetings archive's two reads.
///
/// ⚠️ NEITHER ROUTE CARRIES A `success` ENVELOPE AND THE TWO DO NOT SHARE A
/// TOP-LEVEL SHAPE, so the bodies below deliberately have no such key. That is
/// asserted rather than assumed: a repository that reached for
/// `ResponseEnvelope.affirm` would fail every one of these, and the copy is a
/// one-line lift from any neighbouring repository.
final class MeetingsRepositoryTests: XCTestCase {
    // MARK: - The list

    func testReadingTheMeetingsGetsTheDistrictRouteWithTheWorkspaceInTheQuery() async {
        let transport = RepositoryTransport(json: MeetingBodies.list(rooms: ["meet_ws_1_standup"]))

        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.meetings.count, 1)
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/meetings?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty)
    }

    /// ⛔ A BARE ARRAY WITH NO ENVELOPE IS A SUCCESS, AND AN EMPTY ONE IS AN
    /// ANSWER. There is no flag to check and no guard could tell "nothing yet"
    /// from a broken read anyway, so a repository that wrapped this would reject
    /// every healthy response — including the ordinary one from a workspace that
    /// has never held a meeting.
    func testAnEmptyArrayIsASuccessRatherThanAMissingEnvelope() async throws {
        let transport = RepositoryTransport(json: "[]")

        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        XCTAssertNil(result.failureOnly, "there is no envelope flag to fail on")
        let page = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(page.meetings.count, 0, "nothing yet is an answer, not a broken read")
        // ⛔ AND IT IS THE ONE EMPTY THAT MAY BE WORDED AS "there are no meetings".
        // Nothing arrived, so nothing was dropped; see the next test for the other one.
        XCTAssertEqual(page.receivedCount, 0)
        XCTAssertFalse(page.isEmptyAfterFiltering)
        XCTAssertFalse(page.isCapped)
    }

    /// ⛔ `video_` ROWS ARE FILTERED OUT AND THE FILTER IS DELIBERATE RATHER THAN
    /// DEFENSIVE. The Meeting table records whatever room the Companion was
    /// dispatched into, including billable avatar sessions — a different product
    /// surface whose rows would appear here as meetings the user never held. A
    /// row that fails the filter belongs to something else; it is not corrupt
    /// data and it is not an error, so the rest of the list is still served.
    func testAvatarRoomsAreFilteredOutWithoutFailingTheRead() async throws {
        let transport = RepositoryTransport(
            json: MeetingBodies.list(rooms: ["meet_ws_1_standup", "video_ws_1_demo", "meet_ws_1_review"])
        )

        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        let page = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(page.meetings.map(\.roomName), ["meet_ws_1_standup", "meet_ws_1_review"])
        XCTAssertNil(result.failureOnly, "a foreign row is not an error")
        // ⚠️ THE COUNT IS OF WHAT ARRIVED, NOT OF WHAT SURVIVED. It is the only
        // evidence a screen has that the page was longer than the list it draws.
        XCTAssertEqual(page.receivedCount, 3)
    }

    /// ⛔ A SCHEDULER-BOOKED MEETING IS A MEETING, AND THE OLD `meet_`-ONLY ALLOWLIST
    /// DROPPED EVERY ONE OF THEM. The scheduling webhook writes
    /// `sched_<workspaceId>_<bookingId>` and the Companion writes it up with a title, a
    /// summary, a transcript and participants exactly as it does a `meet_` room; the
    /// web lists them. The rule that was meant was "not the billable avatar sessions",
    /// and an allowlist expressed it in a form that silently excluded a prefix nobody
    /// had thought of, which is what this pins against a fourth one.
    func testSchedulerBookedMeetingsAreListedRatherThanDroppedWithTheAvatarRooms() async throws {
        let rooms = ["sched_ws_1_bk-42", "meet_ws_1_standup", "video_ws_1_demo"]
        let transport = RepositoryTransport(json: MeetingBodies.list(rooms: rooms))

        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        let page = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(page.meetings.map(\.roomName), ["sched_ws_1_bk-42", "meet_ws_1_standup"])
        XCTAssertNil(RoomName(joining: "sched_ws_1_bk-42"), "and it is still not a room this client would join")
    }

    /// ⛔ ROWS ARRIVED AND NONE OF THEM IS DRAWN, WHICH IS NOT "there are no
    /// meetings". The server caps its query at 50 BEFORE this client drops the avatar
    /// sessions, so a busy workspace can be handed a full page holding nothing this app
    /// renders and a screen that read the empty array alone would tell that operator
    /// their history is empty while the browser shows a full one. ⚠️ The cap itself is
    /// server-side and unfixable from here; what is fixable is the claim made about it.
    func testAPageOfNothingThisAppDrawsIsNotAnEmptyHistory() async throws {
        let transport = RepositoryTransport(
            json: MeetingBodies.list(rooms: ["video_ws_1_demo", "video_ws_1_intro"])
        )

        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        let page = try XCTUnwrap(result.successOnly)
        XCTAssertTrue(page.meetings.isEmpty)
        XCTAssertEqual(page.receivedCount, 2)
        XCTAssertTrue(page.isEmptyAfterFiltering, "the page held rows; the history is not known to be empty")
    }

    /// ⚠️ A FULL PAGE MEANS THERE MAY BE OLDER MEETINGS THIS READ CANNOT SEE, and the
    /// only signal is that the page came back at the server's own `take: 50`. Nothing
    /// on the wire carries a total or a cursor, so a screen has to caption the list
    /// rather than present it as the whole history.
    func testAFullPageIsReportedAsCappedAndAShortOneIsNot() async throws {
        let full = MeetingBodies.list(rooms: (0 ..< MeetingsPage.serverPageLimit).map { "meet_ws_1_m\($0)" })
        let short = MeetingBodies.list(rooms: (0 ..< 3).map { "meet_ws_1_m\($0)" })

        let capped = await MeetingsRepository(client: .repositoryTest(RepositoryTransport(json: full)))
            .meetings(workspaceId: "ws_1")
        let partial = await MeetingsRepository(client: .repositoryTest(RepositoryTransport(json: short)))
            .meetings(workspaceId: "ws_1")

        XCTAssertTrue(try XCTUnwrap(capped.successOnly).isCapped)
        XCTAssertFalse(try XCTUnwrap(partial.successOnly).isCapped)
    }

    /// ⛔ THE FILTER IS A PREFIX TEST AND NOT ``RoomName``, WHICH WOULD HIDE LIVE
    /// MEETINGS FROM THEIR OWN LIST. That type additionally restricts the suffix
    /// to `[a-zA-Z0-9-]` to match the web lobby, while the server's own regex
    /// ends in `.+` and admits underscores — so a real room like
    /// `meet_ws-contract-test_standup` is a name this client must READ and would
    /// refuse to MINT. Validating a name we did not construct against the minting
    /// rule is the mistake this pins.
    func testARoomNameThisClientWouldRefuseToMintIsStillListed() async throws {
        let underscored = "meet_ws-contract-test_standup"
        XCTAssertNil(RoomName(underscored), "the minting rule refuses it, which is correct for minting")

        let transport = RepositoryTransport(json: MeetingBodies.list(rooms: [underscored]))
        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        XCTAssertEqual(try XCTUnwrap(result.successOnly).meetings.map(\.roomName), [underscored])
    }

    /// ⚠️ THE IN-PROGRESS ROW SURVIVES THE REPOSITORY WITH ITS NULLS INTACT. It
    /// is the row most likely to be at the top of a live user's list, and every
    /// one of its absences is a fact rather than a gap.
    func testAnInProgressRowKeepsItsNullsThroughTheRepository() async throws {
        let transport = RepositoryTransport(json: MeetingBodies.inProgress)

        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        let row = try XCTUnwrap(result.successOnly?.meetings.first)
        XCTAssertNil(row.summaryPreview)
        XCTAssertNil(row.endedAt)
        XCTAssertNil(row.title)
        XCTAssertEqual(row.durationSec, 0)
    }

    func testASignedOutListReadIsA401() async {
        let transport = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)

        let result = await MeetingsRepository(client: .repositoryTest(transport)).meetings(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 401)
        XCTAssertNil(result.successOnly)
    }

    // MARK: - The detail

    /// ⚠️ SCOPED ON BOTH THE ID AND THE WORKSPACE, and the workspace travels in
    /// the query rather than being inferred: the id alone is not the tenant
    /// boundary, and the server checks the pair inside its workspace-context
    /// transaction.
    func testTheDetailReadCarriesBothTheIdInThePathAndTheWorkspaceInTheQuery() async {
        let transport = RepositoryTransport(json: MeetingBodies.detail)

        let result = await MeetingsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", meetingId: "m_1")

        XCTAssertEqual(result.successOnly?.id, "m_1")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/meetings/m_1?workspaceId=ws_1"
        )
    }

    /// ⛔ A BARE OBJECT WITH NO ENVELOPE, AND THE DETAIL IS NOT THE LIST ROW.
    /// It carries `summary` and `participants` where the list carried
    /// `summaryPreview` and `participantCount`, so a screen cannot promote a list
    /// row into a detail one without this call.
    func testTheDetailDecodesWithoutAnEnvelopeAndCarriesTheFieldsTheListNeverSends() async throws {
        let transport = RepositoryTransport(json: MeetingBodies.detail)

        let result = await MeetingsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", meetingId: "m_1")

        XCTAssertNil(result.failureOnly, "there is no envelope flag to fail on")
        let detail = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(detail.workspaceId, "ws_1")
        XCTAssertEqual(detail.roomSid, "RM_1")
        XCTAssertEqual(detail.summary, "The team agreed the routing change lands this week.")
    }

    /// ⚠️ A 404 IS ALSO WHAT ANOTHER WORKSPACE'S MEETING ID PRODUCES, because the
    /// lookup is scoped on both id and workspace: "not yours" and "not there" are
    /// deliberately indistinguishable, so any message about it has to be worded
    /// for both.
    func testAMissingOrForeignMeetingIsThe404AndNotAnEmptyDetail() async {
        let transport = RepositoryTransport(json: #"{"error":"Meeting not found"}"#, status: 404)

        let result = await MeetingsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", meetingId: "m_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 404)
        XCTAssertNil(result.successOnly)
    }

    func testAServerFailureOnTheDetailIsAnErrorRatherThanAnAbsentMeeting() async {
        let transport = RepositoryTransport(json: #"{"error":"Failed to load meeting"}"#, status: 500)

        let result = await MeetingsRepository(client: .repositoryTest(transport))
            .detail(workspaceId: "ws_1", meetingId: "m_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 500)
    }
}

/// Minimal, VALID bodies for the two meetings shapes.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-meetings.json` and
/// `district-meeting-detail.json` pin the wire shape through the strict gate;
/// these are the smallest bodies that satisfy the Swift types. ⛔ Neither carries
/// a `success` key, because neither route sends one.
private enum MeetingBodies {
    static func row(roomName: String) -> String {
        #"""
        {"id":"\#(roomName)","roomName":"\#(roomName)","title":"Standup","status":"completed",
         "startedAt":"2026-08-19T09:41:00.000Z","endedAt":"2026-08-19T09:55:00.000Z",
         "createdAt":"2026-08-19T09:41:00.000Z","durationSec":840,
         "summaryPreview":"Short.","participantCount":2}
        """#
    }

    static func list(rooms: [String]) -> String {
        "[" + rooms.map(row(roomName:)).joined(separator: ",") + "]"
    }

    /// ⛔ THE ORDINARY LIVE ROW: no title, no end, no preview, and a zero
    /// duration that is stamped at the end rather than accumulated.
    static let inProgress = #"""
    [{"id":"m_live","roomName":"meet_ws_1_standup","title":null,"status":"in-progress",
      "startedAt":"2026-08-19T09:41:00.000Z","endedAt":null,
      "createdAt":"2026-08-19T09:41:00.000Z","durationSec":0,
      "summaryPreview":null,"participantCount":0}]
    """#

    static let detail = #"""
    {"id":"m_1","roomSid":"RM_1","roomName":"meet_ws_1_standup","workspaceId":"ws_1",
     "title":"Standup","status":"completed",
     "summary":"The team agreed the routing change lands this week.",
     "transcript":"Ada: Morning.","actionItems":[],"participants":[],
     "durationSec":840,"startedAt":"2026-08-19T09:41:00.000Z",
     "endedAt":"2026-08-19T09:55:00.000Z","createdAt":"2026-08-19T09:41:00.000Z"}
    """#
}
