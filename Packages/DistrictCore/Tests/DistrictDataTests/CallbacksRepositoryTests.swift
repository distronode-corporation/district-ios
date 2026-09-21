import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// ``CallsRepository/recentCallbacks(workspaceId:limit:)``, which is the dialer's
/// call-back list.
///
/// ⛔ ITS OWN FILE RATHER THAN A SECTION OF `RepositoryTests`, WHICH IS A LINT
/// CEILING RATHER THAN A DESIGN STATEMENT: that file is within 22 lines of
/// SwiftLint's 500-line limit and says so at the top, for the same reason the inbox
/// tests already live apart.
///
/// ⛔ THE FILTER IS WHAT THIS FILE IS ABOUT, AND EVERY NEGATIVE CASE HERE IS A CALL
/// THAT MUST NOT BE OFFERED. `from` on an outbound row is the workspace's OWN
/// number, so a row that leaked through would put the workspace's line on a
/// call-back list and the resulting call would connect, bill, and read as a carrier
/// fault. A test that only checked the happy path would pass against a repository
/// with no filter at all.
final class CallbacksRepositoryTests: XCTestCase {
    // MARK: - The request

    /// ⛔ ONE PAGE OF THE EXISTING CALL-LOG ENDPOINT, limit 20 and offset 0. The
    /// server has no `direction` filter, so this route plus a client-side filter is
    /// the whole feature: a new endpoint, a new descriptor or a new fixture would
    /// all be inventions.
    func testTheCallbackListAsksTheCallLogForOnePageAndNothingElse() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([CallbackBodies.row(id: "call_1")]))

        _ = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(transport.requests.count, 1, "a call-back read is one GET, never a page walk")
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/calls?workspaceId=ws_1&limit=20&offset=0"
        )
    }

    // MARK: - Which rows survive

    /// ⛔ INBOUND ONLY. An outbound row's `from` is the workspace's own number, so
    /// keeping one would offer to dial the workspace's own line.
    func testAnOutboundRowIsNotACallback() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([
            CallbackBodies.row(id: "call_in", direction: "inbound", from: "+14165550100"),
            CallbackBodies.row(id: "call_out", direction: "outbound", from: "+14165550159"),
        ]))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["call_in"])
    }

    /// ⛔ AN ABSENT DIRECTION IS EXCLUDED, WHICH IS THE CASE A "keep what is not
    /// outbound" FILTER WOULD GET WRONG. An unknown direction is not evidence that
    /// `from` is a callee, and ``CallSummary/direction`` is Optional precisely
    /// because rows without one exist.
    func testARowWithNoDirectionIsNotACallback() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([
            CallbackBodies.row(id: "call_known", direction: "inbound", from: "+14165550100"),
            CallbackBodies.row(id: "call_unknown", direction: nil, from: "+14165550101"),
        ]))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["call_known"])
    }

    /// ⛔ BLANK COUNTS AS ABSENT. A row carrying `"   "` decodes perfectly well and
    /// is still not a number anyone can be called back on; a nil-only check would
    /// let it through and the row would fill the keypad with whitespace.
    func testAnInboundRowWithNoUsableNumberIsNotACallback() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([
            CallbackBodies.row(id: "call_ok", from: "+14165550100"),
            CallbackBodies.row(id: "call_missing", from: nil),
            CallbackBodies.row(id: "call_blank", from: "   "),
        ]))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["call_ok"])
    }

    /// ⛔ A WITHHELD CALLER IS NOT A CALL-BACK, AND BLANKNESS ALONE MISSED IT. The
    /// LiveKit webhook writes an English SENTENCE into the `from` column when
    /// telephony gave it no caller ID, so `"Inbound SIP Caller"` is neither nil nor
    /// blank and the row was offered. Tapping it typed those three words into the
    /// keypad and left the Call button dead: an offer to ring somebody who left no
    /// number. All three of the server's literals are asserted, because the set is an
    /// exact match and a partial list is the easy mistake.
    func testARowCarryingACallerPlaceholderIsNotACallback() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([
            CallbackBodies.row(id: "call_ok", from: "+14165550100"),
            CallbackBodies.row(id: "call_sip", from: "Inbound SIP Caller"),
            CallbackBodies.row(id: "call_campaign", from: "Outbound Campaign Caller"),
            CallbackBodies.row(id: "call_unknown", from: "Unknown"),
        ]))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["call_ok"])
    }

    /// ⚠️ AND THE FILTER IS NOT OVER-EAGER. The match is exact, so a caller genuinely
    /// named something that merely BEGINS with a placeholder keeps their row — a
    /// prefix or `contains` implementation would quietly drop real people, which is
    /// the failure a test written only for the case above would not catch.
    func testACallerWhoseNameMerelyBeginsWithAPlaceholderIsStillACallback() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([
            CallbackBodies.row(id: "call_real", from: "Unknown Caller Ltd"),
        ]))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["call_real"])
    }

    /// ⚠️ NOT DEDUPLICATED BY NUMBER, DELIBERATELY. One person who called three
    /// times is three rows, each with its own time and outcome; collapsing them here
    /// would misreport the log, and a view that collapses them for display has to
    /// say so itself.
    func testThreeCallsFromOneNumberAreThreeCallbacks() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([
            CallbackBodies.row(id: "call_1", from: "+14165550100"),
            CallbackBodies.row(id: "call_2", from: "+14165550100"),
            CallbackBodies.row(id: "call_3", from: "+14165550100"),
        ]))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["call_1", "call_2", "call_3"])
        XCTAssertEqual(result.successOnly?.compactMap(\.from), Array(repeating: "+14165550100", count: 3))
    }

    // MARK: - Nothing to show is not a failure

    /// ⚠️ A LEGITIMATE STATE, NOT AN ERROR. A workspace whose newest twenty calls
    /// were all outbound has no call-backs, and so does one that has never taken a
    /// call. It must arrive as `.success([])`, because the screen's empty state and
    /// its failure state say different things.
    func testAPageWithNoInboundRowsIsAnEmptySuccess() async {
        let transport = RepositoryTransport(json: CallbackBodies.feed([
            CallbackBodies.row(id: "call_out", direction: "outbound", from: "+14165550159"),
        ]))

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isEmpty, true)
        XCTAssertNil(result.failureOnly, "an empty list is an answer, never a failure")
    }

    /// ⚠️ AND THE SAME FOR A GENUINELY EMPTY FEED, which is what a brand-new
    /// workspace answers.
    func testAnEmptyFeedIsAnEmptySuccess() async {
        let transport = RepositoryTransport(json: "[]")

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isEmpty, true)
    }

    // MARK: - Failures

    /// ⛔ A DEAD SESSION IS A FAILURE, NEVER AN EMPTY LIST. Rendering a 401 as "no
    /// recent callers" would tell someone whose session just ended that nobody has
    /// called them.
    func testAnExpiredSessionIsAFailureRatherThanAnEmptyList() async {
        let transport = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .http(status: 401, message: "Unauthorized"))
        XCTAssertNil(result.successOnly)
    }

    /// ⚠️ A 403 REACHES THE DIALER TOO, because the call log is role-gated
    /// independently of the keypad. It is a failure of the LIST and must not be
    /// allowed to become a refusal of the dial.
    func testARoleRefusalIsAFailureOfTheListOnly() async {
        let transport = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .http(status: 403, message: "Forbidden"))
    }

    /// ⚠️ A TRANSIENT UPSTREAM FAILURE STAYS A FAILURE AND KEEPS ITS STATUS, so the
    /// screen can offer a retry that could honestly change the answer.
    func testATransientUpstreamFailureIsReportedWithItsStatus() async {
        let transport = RepositoryTransport(json: #"{"error":"Service Unavailable"}"#, status: 503)

        let result = await CallsRepository(client: .repositoryTest(transport))
            .recentCallbacks(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .http(status: 503, message: "Service Unavailable"))
    }
}

/// Feed rows carrying the two fields the call-back filter reads.
///
/// ⛔ ITS OWN BUILDER RATHER THAN `Bodies.call(id:)`, WHICH CARRIES NEITHER
/// `direction` NOR `from`. Those are exactly the keys under test, and a builder
/// that always emitted them could not express the two ABSENCES the filter has to
/// reject: an omitted key and an Optional decoded as nil are the same thing here,
/// and both have to be reachable from a test.
///
/// ⚠️ THE NEWLINES SIT BETWEEN JSON TOKENS, NEVER INSIDE A STRING VALUE. A newline
/// inside a value is invalid JSON, and the decode failure it produces reads as a
/// bug in the repository rather than in the fixture.
private enum CallbackBodies {
    static func row(
        id: String,
        direction: String? = "inbound",
        from: String? = "+14165550100"
    ) -> String {
        let directionKey = direction.map { #","direction":"\#($0)""# } ?? ""
        let fromKey = from.map { #","from":"\#($0)""# } ?? ""
        return #"""
        {"id":"\#(id)","type":"inbound","number":"Ada Lovelace","status":"completed",
         "duration":"1m 5s","time":"9:41 AM","aiSummary":"Booked a survey.","transcript":"",
         "callerName":"Ada Lovelace","summary":"Booked a survey.",
         "createdAt":"2026-08-19T09:41:00.000Z"\#(directionKey)\#(fromKey)}
        """#
    }

    static func feed(_ rows: [String]) -> String {
        "[" + rows.joined(separator: ",") + "]"
    }
}
