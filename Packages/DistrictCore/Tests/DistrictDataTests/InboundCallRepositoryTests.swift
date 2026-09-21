import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Answering a call this device is ringing on.
///
/// ⛔ THE NEGATIVE CASES ARE THE POINT OF THIS FILE, AND THEY ARE ABOUT WHICH
/// SENTENCE A RINGING SCREEN SHOWS RATHER THAN ABOUT DECODING. Three statuses
/// mean three different things to the person holding the phone — "the caller hung
/// up" (404/409), "you are a viewer and this workspace will not let you take it"
/// (403), and "something went wrong" (everything else) — and only the first two
/// are `.success` values a screen may word gently.
///
/// ⚠️ NO TEST HERE SENDS A SECOND REQUEST, and none may be added. `calls/answer`
/// writes the Redis rendezvous the agent's transfer is blocked on, so a retry
/// races a call that is being connected.
final class InboundCallRepositoryTests: XCTestCase {
    // MARK: - The answer that worked

    func testAnAnsweredCallPostsTheAnswerRouteAndCarriesTheCredentialVerbatim() async {
        let transport = RepositoryTransport(json: AnswerBodies.joinable)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        guard case let .joinable(response)? = result.successOnly else {
            return XCTFail("a 200 with a usable credential is a joinable call")
        }
        XCTAssertEqual(response.url, "wss://livekit-wss.distronode.com")
        XCTAssertEqual(response.token, "contract-livekit-answer-jwt")
        XCTAssertEqual(response.roomName, "call_ws-contract-test_inbound-1")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/calls/CA1/answer"
        )
        XCTAssertEqual(transport.bodies.first, #"{"workspaceId":"ws_1"}"#)
    }

    /// ⛔ THERE IS NO ROOM-PREFIX ASSERTION, UNLIKE THE DIAL PATH, AND ITS ABSENCE
    /// IS DELIBERATE ENOUGH TO PIN. `DialRepository` refuses a name without
    /// `direct_` because that prefix is what keeps the voice agent off a room this
    /// app created; an ANSWERED call is a `call_` room the agent is already in and
    /// is supposed to be in, so the same check here would refuse every legitimate
    /// answer.
    func testACallRoomIsAcceptedEvenThoughTheDialPathWouldRefuseTheName() async {
        let transport = RepositoryTransport(json: AnswerBodies.joinable)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        guard case let .joinable(response)? = result.successOnly else {
            return XCTFail("a call_ room is the ordinary inbound answer")
        }
        XCTAssertFalse(response.roomName.hasPrefix(DialRoom.directPrefix))
    }

    /// ⚠️ AN ID IS ONE PATH SEGMENT. A call id of `a/../../admin` addressed a
    /// different route entirely on the Kotlin client before its paths were built
    /// from segment lists.
    func testACallIdCannotTraverseIntoAnotherRoute() async {
        let transport = RepositoryTransport(json: AnswerBodies.joinable)

        _ = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "a/../../admin",
            workspaceId: "ws_1"
        )

        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/calls/a%2F..%2F..%2Fadmin/answer"
        )
    }

    // MARK: - The two refusals a screen must word gently

    /// ⛔ NOT AN ERROR. The overwhelmingly common way to reach a 404 is that the
    /// caller hung up between the phone ringing and a thumb arriving; the server
    /// answers 404 for a call this workspace cannot see on purpose, so "wrong id"
    /// and "gone" are one answer by design.
    func testACallThisWorkspaceCannotSeeIsTheCallerHavingGone() async {
        let transport = RepositoryTransport(json: #"{"error":"Call not found"}"#, status: 404)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        guard case .callerGone? = result.successOnly else {
            return XCTFail("a 404 is the ordinary race, not a failure")
        }
    }

    /// ⚠️ 409 IS THE SAME ANSWER FROM THE OTHER DIRECTION: the call exists and its
    /// status is no longer answerable. Collapsed here, once, so a screen never has
    /// to match on a status.
    func testACallThatIsNoLongerAnswerableIsAlsoTheCallerHavingGone() async {
        let transport = RepositoryTransport(json: #"{"error":"Call is no longer ringing"}"#, status: 409)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        guard case .callerGone? = result.successOnly else {
            return XCTFail("a 409 is the ordinary race, not a failure")
        }
    }

    /// ⛔ A VIEWER'S PHONE GENUINELY RINGS. The push is fanned out to every
    /// registered device in the workspace without consulting roles, so this is
    /// reachable by an ordinary user and carries the server's own sentence.
    func testAViewerIsRefusedWithTheServersOwnSentence() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Forbidden: Insufficient workspace privileges"}"#,
            status: 403
        )

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        guard case let .refused(message)? = result.successOnly else {
            return XCTFail("a 403 is a role refusal rather than a fault")
        }
        XCTAssertEqual(message, "Forbidden: Insufficient workspace privileges")
    }

    /// ⚠️ AN EDGE 403 IS HTML. `ApiErrorEnvelope.lenient` answers nil, so the
    /// refusal carries no message and the screen owns the fallback — rather than
    /// putting a captive portal's markup on a ringing phone.
    func testANonJsonForbiddenBodyIsARefusalWithNoSentence() async {
        let transport = RepositoryTransport(json: "<html>403 Forbidden</html>", status: 403)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        guard case let .refused(message)? = result.successOnly else {
            return XCTFail("a 403 is a role refusal whatever the body is made of")
        }
        XCTAssertNil(message)
    }

    /// ⚠️ A BLANK `error` COUNTS AS ABSENT, which is the shared normalisation rule
    /// both clients follow so their copy cannot diverge for the same bytes.
    func testABlankSentenceIsTreatedAsNoSentence() async {
        let transport = RepositoryTransport(json: #"{"error":"   "}"#, status: 403)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        guard case let .refused(message)? = result.successOnly else {
            return XCTFail("a 403 is a role refusal")
        }
        XCTAssertNil(message)
    }

    // MARK: - The failures that stay failures

    /// ⛔ ONE REQUEST, WHATEVER HAPPENS. A 5xx may already have released the
    /// agent's transfer, so a second attempt races a call that is being connected.
    func testAServerErrorSendsExactlyOneRequestAndIsNotRetried() async {
        let transport = RepositoryTransport(json: #"{"error":"Something broke"}"#, status: 500)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        XCTAssertNil(result.successOnly)
        XCTAssertEqual(result.failureOnly, .http(status: 500, message: "Something broke"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// ⚠️ A 401 IS A DEAD SESSION AND MUST NOT READ AS "the caller hung up". It is
    /// the shape an answer takes on a handset whose session ended while the push
    /// was in flight.
    func testAnExpiredSessionIsAFailureRatherThanTheCallerHavingGone() async {
        let transport = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        XCTAssertNil(result.successOnly)
        XCTAssertEqual(result.failureOnly?.httpStatus, 401)
    }

    /// ⛔ A 200 THAT DOES NOT AFFIRM SUCCESS IS NOT A CALL TO JOIN. The route's own
    /// catch branch produces exactly this shape once the headers are written.
    func testATwoHundredThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: AnswerBodies.unaffirmed)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        XCTAssertEqual(result.failureOnly, .decoding("CallAnswerResponse did not affirm success=true"))
    }

    /// ⛔ AN AFFIRMED ENVELOPE WITH A BLANK CREDENTIAL IS STILL NOT A CALL. `{}`
    /// cannot reach here (every field is required), but `""` decodes perfectly —
    /// and a blank url would surface at `engine.connect` as a media-plane error on
    /// a screen already showing a connected call.
    func testAnAffirmedEnvelopeWithABlankCredentialIsADecodeFailure() async {
        let transport = RepositoryTransport(json: AnswerBodies.blankCredential)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        XCTAssertEqual(result.failureOnly, .decoding("CallAnswerResponse carried no join credential"))
    }

    /// ⚠️ AND WHITESPACE COUNTS AS BLANK, matching the Kotlin `isBlank()` check.
    func testAWhitespaceOnlyTokenIsAlsoNoCredential() async {
        let transport = RepositoryTransport(json: AnswerBodies.whitespaceToken)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        XCTAssertEqual(result.failureOnly, .decoding("CallAnswerResponse carried no join credential"))
    }

    /// ⚠️ A 200 THAT IS NOT A `CallAnswerResponse` IS CONTRACT DRIFT, NOT
    /// CONNECTIVITY.
    func testATwoHundredThatIsNotAnAnswerResponseIsAShapeMismatch() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await InboundCallRepository(client: .repositoryTest(transport)).answer(
            callId: "CA1",
            workspaceId: "ws_1"
        )

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
    }

    /// ⛔ NOTHING IS SENT WITHOUT A BEARER. The rendezvous must not be written on
    /// behalf of a session that no longer exists.
    func testAMissingCredentialFailsBeforeAnythingIsSent() async {
        let transport = RepositoryTransport([])
        let client = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { nil }
        )

        let result = await InboundCallRepository(client: client).answer(callId: "CA1", workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .http(status: 401, message: nil))
        XCTAssertEqual(transport.requests.count, 0, "an unauthenticated answer must not write the rendezvous")
    }
}

/// ⚠️ LOCAL TO THIS FILE RATHER THAN IN `Bodies`, because every one of them is
/// about this route's own edge cases and none is reused. The first is
/// byte-identical to the contract fixture `district-call-answer.json`,
/// which is what the strict gate pins; the rest are deliberate corruptions of it.
private enum AnswerBodies {
    static let joinable = #"""
    {"success":true,"url":"wss://livekit-wss.distronode.com",
     "token":"contract-livekit-answer-jwt","roomName":"call_ws-contract-test_inbound-1"}
    """#

    static let unaffirmed = #"""
    {"success":false,"url":"wss://livekit-wss.distronode.com",
     "token":"contract-livekit-answer-jwt","roomName":"call_ws-contract-test_inbound-1"}
    """#

    static let blankCredential = #"""
    {"success":true,"url":"","token":"contract-livekit-answer-jwt",
     "roomName":"call_ws-contract-test_inbound-1"}
    """#

    static let whitespaceToken = #"""
    {"success":true,"url":"wss://livekit-wss.distronode.com","token":"   ",
     "roomName":"call_ws-contract-test_inbound-1"}
    """#
}
