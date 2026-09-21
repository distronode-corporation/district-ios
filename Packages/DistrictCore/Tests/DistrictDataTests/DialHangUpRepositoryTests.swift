import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Telling the server to end a direct softphone call.
///
/// ⛔ THE DEFECT THESE EXIST FOR IS A BILL RATHER THAN AN ERROR. Ending a call
/// locally is `Room.disconnect()`, which drops this device from the room and says
/// nothing to the SIP participant, so the carrier leg goes on and goes on being
/// billed — a call ended in under a second can bill roughly 90 seconds at the
/// carrier, with nothing failing anywhere.
///
/// ⛔ ITS OWN FILE RATHER THAN MORE CASES IN `DialRepositoryTests.swift`, WHICH
/// OPENS BY DECLARING "NO TEST HERE SENDS A SECOND REQUEST, AND NONE MAY BE ADDED".
/// That rule is the dial's and is load bearing there — a second request rings a
/// second telephone — and this route's rule is the exact opposite: it is idempotent
/// and is deliberately sent on endings that may have sent it already. Putting both
/// under one header would leave the file's own invariant reading as false.
final class DialHangUpRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> DialRepository {
        DialRepository(client: .repositoryTest(transport))
    }

    // MARK: - The request

    /// ⛔ THE ID IS IN THE PATH AND THE WORKSPACE IS IN THE BODY, which is the same
    /// split `calls/{id}/answer` uses and is not interchangeable: the workspace
    /// scopes the ownership check the route makes before it touches anything.
    func testTheHangUpPostsTheCallsIdRouteWithTheWorkspaceInTheBody() async {
        let transport = RepositoryTransport(json: #"{"success":true,"ended":true}"#)

        _ = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/calls/CA1/hangup"
        )
        XCTAssertEqual(transport.bodies.first, #"{"workspaceId":"ws_1"}"#)
    }

    /// ⛔ THE ID IS ONE PATH SEGMENT AND IS PERCENT-ENCODED. It comes off the wire
    /// in `DialResponse`, so a server that ever answered a `/` would otherwise
    /// address a different route entirely with this workspace's bearer.
    func testACallIdCannotTraverseIntoAnotherRoute() async {
        let transport = RepositoryTransport(json: #"{"success":true,"ended":true}"#)

        _ = await repository(transport).hangUp(workspaceId: "ws_1", callId: "a/../../admin")

        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/calls/a%2F..%2F..%2Fadmin/hangup"
        )
    }

    // MARK: - The four answers

    func testEndedTrueIsTheRequestThatToreTheRoomDown() async {
        let transport = RepositoryTransport(json: #"{"success":true,"ended":true}"#)

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.successOnly, .ended)
    }

    /// ⛔ `ended:false` IS A SUCCESS AND MUST NEVER READ AS A FAILED HANG-UP. It is
    /// the ordinary answer whenever the callee hung up first, and it is what a
    /// second send of this idempotent route returns — which is a path the client
    /// deliberately takes.
    func testEndedFalseIsAlreadyEndedRatherThanAFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true,"ended":false}"#)

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.successOnly, .alreadyEnded)
        XCTAssertNil(result.failureOnly)
    }

    /// ⚠️ 404 IS INDISTINGUISHABLE FROM ANOTHER TENANT'S ID by design — the route
    /// reads by id and checks ownership afterwards — so it says "we cannot end
    /// this", never "that id was malformed".
    func testAMissingCallIsAnAnswerRatherThanAnError() async {
        let transport = RepositoryTransport(json: #"{"error":"Call not found"}"#, status: 404)

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.successOnly, .notFound)
    }

    /// ⛔ 409 IS "not a direct softphone call". Unreachable from this client today,
    /// because the only id it can spend came from its own dial, and modelled so that
    /// a server-side reclassification is visible rather than folded into a 5xx-shaped
    /// failure.
    func testACallThatIsNotADirectSoftphoneCallIsItsOwnOutcome() async {
        let transport = RepositoryTransport(json: #"{"error":"Not a direct call"}"#, status: 409)

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.successOnly, .notDirectCall)
    }

    // MARK: - The things that are genuinely faults

    /// ⛔ A 200 THAT DOES NOT AFFIRM SUCCESS IS NOT A HANG-UP. A route falling into
    /// its error branch after the headers are written answers exactly this, and
    /// reading `ended` off it would record a carrier leg as ended on the one path
    /// where the server has just said it could not do it.
    func testATwoHundredThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"ended":true}"#)

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.failureOnly, .decoding("CallHangUpResponse did not affirm success=true"))
    }

    /// ⚠️ BOTH FIELDS ARE REQUIRED, so a body missing `ended` is contract drift
    /// rather than a hang-up whose outcome is unknown.
    func testABodyWithoutTheEndedKeyIsAShapeMismatch() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
    }

    /// ⛔ THE ROLE 403 IS A REAL FAILURE HERE, WHICH IS NOT THE DIAL'S ANSWER FOR
    /// THE SAME STATUS. On the dial a 403 may be the uncoded compliance refusal and
    /// has to be told apart by envelope shape; on this route the only 403 is the
    /// role guard, and a viewer cannot have placed the call they are ending.
    func testTheRoleRefusalPassesThroughAsAFailure() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Forbidden: Insufficient workspace privileges"}"#,
            status: 403
        )

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertNil(result.successOnly)
        XCTAssertEqual(
            result.failureOnly,
            .http(status: 403, message: "Forbidden: Insufficient workspace privileges")
        )
    }

    /// ⛔ ONE REQUEST PER CALL, EVEN ON A 5xx. The route being idempotent makes a
    /// retry SAFE and does not make it right: nobody is on the call, and the
    /// failures that reach here are offline and signed-out, which a second
    /// immediate attempt does not fix.
    func testAServerErrorIsNotRetried() async {
        let transport = RepositoryTransport(json: #"{"success":false,"error":"boom"}"#, status: 500)

        let result = await repository(transport).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.failureOnly, .http(status: 500, message: "boom"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// ⚠️ NO CREDENTIAL, NOTHING SENT. The client refuses before the transport, so
    /// a hang-up fired from a session that has just been signed out costs no
    /// request and reports the 401 the same way every other route does.
    func testAnUnauthenticatedHangUpNeverReachesTheTransport() async {
        let transport = RepositoryTransport([])
        let client = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { nil }
        )

        let result = await DialRepository(client: client).hangUp(workspaceId: "ws_1", callId: "CA1")

        XCTAssertEqual(result.failureOnly, .http(status: 401, message: nil))
        XCTAssertEqual(transport.requests.count, 0)
    }
}
