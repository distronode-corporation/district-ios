import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The softphone dial.
///
/// ⛔ THESE ASSERTIONS ARE ABOUT WHICH SENTENCE AN OPERATOR SEES, NOT ABOUT
/// DECODING. Three of this route's refusals need three different remedies —
/// "that number opted out", "billing lapsed, fix it on the web", "ask us to turn
/// this workspace back on" — and only two of them publish a `code`. The third is
/// separated from the role refusal and from the route's own 400s and 500 by the
/// SHAPE of its envelope, so the negative cases below are the load-bearing half
/// of this file: each one proves a body that must NOT become a DNC refusal.
///
/// ⚠️ NO TEST HERE SENDS A SECOND REQUEST, and none may be added. The property
/// under test everywhere else in this package is "what did the client decode";
/// here it is also "how many telephones rang".
final class DialRepositoryTests: XCTestCase {
    // MARK: - The call that went out

    func testAPlacedDialPostsTheDialRouteAndAnswersTheCredential() async {
        let transport = RepositoryTransport(json: Bodies.dial())

        let result = await DialRepository(client: .repositoryTest(transport)).dial(
            workspaceId: "ws_1",
            to: "(416) 555-0134"
        )

        guard case let .placed(session)? = result.successOnly else {
            return XCTFail("a 200 with a usable credential is a placed call")
        }
        XCTAssertEqual(session.callId, "CA1")
        XCTAssertTrue(session.roomName.hasPrefix(DialRoom.directPrefix))
        XCTAssertEqual(session.url, "wss://livekit-wss.distronode.com")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/calls/dial"
        )
    }

    /// ⚠️ THE NUMBER GOES AS TYPED, PUNCTUATION AND ALL. The server normalises
    /// and then checks DNC against ITS form, so a client-side canonicaliser would
    /// place a call the compliance check never ran against. Asserted on the
    /// encoded bytes because that is the only place a silently-rewritten
    /// argument would show.
    func testTheNumberIsSentExactlyAsTyped() async {
        let transport = RepositoryTransport(json: Bodies.dial())

        _ = await DialRepository(client: .repositoryTest(transport)).dial(
            workspaceId: "ws_1",
            to: "(416) 555-0134"
        )

        XCTAssertEqual(transport.bodies.first, #"{"to":"(416) 555-0134","workspaceId":"ws_1"}"#)
    }

    /// ⛔ ONE REQUEST, WHATEVER HAPPENS. A retry after a 5xx rings the callee a
    /// second time and bills for it, because the row is written and the carrier
    /// instructed before the credential is minted.
    func testAServerErrorPlacesExactlyOneRequestAndIsNotRetried() async {
        let transport = RepositoryTransport(json: #"{"success":false,"error":"Something broke"}"#, status: 500)

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertEqual(result.failureOnly, .http(status: 500, message: "Something broke"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - The three refusals

    /// ⛔ THE UNCODED ONE. A `{success:false, error}` at 403 is the route's own
    /// compliance refusal, and the sentence carried here is the server's rather
    /// than this client's — see the ⛔ on `DialRepository`.
    func testAnOptedOutNumberIsADoNotCallRefusalCarryingTheServersSentence() async {
        let transport = RepositoryTransport(json: Bodies.dncRefusal, status: 403)

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        guard case let .doNotCall(message)? = result.successOnly else {
            return XCTFail("a 403 with an explicit success:false and no code is the DNC refusal")
        }
        XCTAssertEqual(message, "This number has opted out of calls from this workspace (DNC).")
    }

    /// ⛔ 402, AND THE REMEDY IS ON THE WEB. Nothing in this app may offer a way
    /// to pay (App Store Review Guideline 3.1.3(b)), so what the branch buys is a
    /// sentence naming the website instead of a generic "that did not work".
    func testALapsedSubscriptionIsItsOwnRefusalRatherThanAGenericPaymentError() async {
        let transport = RepositoryTransport(json: Bodies.subscriptionRefusal, status: 402)

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        guard case let .subscriptionInactive(message)? = result.successOnly else {
            return XCTFail("code subscription_inactive is its own outcome")
        }
        XCTAssertEqual(message?.hasPrefix("This workspace's subscription is not active"), true)
    }

    /// ⛔ THE 403 WITH A WAY OUT. Dormancy is shaped exactly like the DNC refusal
    /// plus a `code`, so the code is matched FIRST; rendered as DNC it would tell
    /// an operator a number opted out when the workspace is simply paused, and
    /// rendered as a generic 403 it reads as an account they have lost.
    func testADormantWorkspaceIsToldApartFromTheDncRefusalItsShapeMatches() async {
        let transport = RepositoryTransport(json: Bodies.dormantRefusal, status: 403)

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        guard case let .workspaceDormant(message)? = result.successOnly else {
            return XCTFail("code workspace_dormant wins over the DNC shape it shares")
        }
        XCTAssertEqual(message?.contains("Request reactivation from your dashboard"), true)
    }

    // MARK: - The bodies that must NOT become a DNC refusal

    /// ⛔ THE ROLE REFUSAL IS A BARE `{error}` WITH NO `success` KEY, and that
    /// absence is the whole discriminator. The Kotlin client cannot see it —
    /// `ApiResult.HttpFailure` keeps status, message and code and drops
    /// `success` — which is why it folds DNC into its catch-all and this one does
    /// not.
    func testTheRoleRefusalPassesThroughRatherThanReadingAsADoNotCall() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Forbidden: Insufficient workspace privileges"}"#,
            status: 403
        )

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertNil(result.successOnly)
        XCTAssertEqual(
            result.failureOnly,
            .http(status: 403, message: "Forbidden: Insufficient workspace privileges")
        )
    }

    /// ⛔ THE STATUS TERM IS LOAD-BEARING. The route's own catch branch answers
    /// `{success:false, error}` on a **500**, byte-identical in shape to the DNC
    /// 403; without the status check an estate fault would tell an operator the
    /// number is on a do-not-call list.
    func testTheRoutesOwnFiveHundredIsNotADoNotCallRefusal() async {
        let transport = RepositoryTransport(json: Bodies.dncRefusal, status: 500)

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertNil(result.successOnly)
        XCTAssertEqual(result.failureOnly?.httpStatus, 500)
    }

    /// ⚠️ AND SO ARE THE 400s. "Invalid phone number", "No phone number
    /// configured for workspace" and the Sinch constraint all carry the same
    /// envelope shape; each is something the operator can act on and none of them
    /// is a compliance refusal.
    func testAnUnusableNumberIsNotADoNotCallRefusal() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"Invalid phone number"}"#,
            status: 400
        )

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "nope")

        XCTAssertNil(result.successOnly)
        XCTAssertEqual(result.failureOnly, .http(status: 400, message: "Invalid phone number"))
    }

    /// ⚠️ THE RATE LIMIT IS A 429 BARE `{error}` — a backstop against a stuck
    /// finger, not a refusal with a remedy. It passes through so the dialer can
    /// say "try again shortly" rather than anything about the number.
    func testTheRateLimitPassesThrough() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Too many calls placed from this workspace. Please try again shortly."}"#,
            status: 429
        )

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 429)
    }

    /// ⚠️ AN EDGE 403 IS HTML, NOT JSON. `ApiErrorEnvelope.lenient` answers nil,
    /// so `success` is absent rather than false and the structural test cannot
    /// fire — which is the behaviour that keeps a captive portal from
    /// impersonating a compliance refusal.
    func testANonJsonForbiddenBodyPassesThroughWithNoMessage() async {
        let transport = RepositoryTransport(json: "<html>403 Forbidden</html>", status: 403)

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertEqual(result.failureOnly, .http(status: 403, message: nil))
    }

    // MARK: - The 200s that are not a call

    /// ⛔ A 200 THAT DOES NOT AFFIRM SUCCESS IS NOT A PLACED CALL, and this is the
    /// one route where reporting a refusal for a call that WAS placed is
    /// possible: the row is written and the carrier instructed before the body is
    /// built. Joining a room on an unaffirmed envelope is still worse — it shows
    /// a working call over a failure — so it fails, and the dialer's copy owns
    /// the "the attempt may have gone out" caveat.
    func testATwoHundredThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(
            json: #"""
            {"success":false,"callId":"CA1","roomName":"direct_CA1","token":"t","url":"wss://x"}
            """#
        )

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertEqual(result.failureOnly, .decoding("DialResponse did not affirm success=true"))
    }

    /// ⚠️ A 200 MISSING A CREDENTIAL IS CONTRACT DRIFT, NOT CONNECTIVITY. Every
    /// field of `DialResponse` is required, so `{}` fails to decode rather than
    /// producing a well-formed response holding an empty token — which is the
    /// shape Kotlin has to guard by hand, because its DTO defaults every field.
    func testATwoHundredThatIsNotADialResponseIsAShapeMismatch() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await DialRepository(client: .repositoryTest(transport)).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
    }

    /// ⚠️ A DEAD SOCKET NEVER PRODUCED A RESPONSE, so there is nothing to
    /// classify and the transport failure passes through untouched.
    func testAMissingCredentialFailsBeforeAnythingIsSent() async {
        let transport = RepositoryTransport([])
        let client = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { nil }
        )

        let result = await DialRepository(client: client).dial(workspaceId: "ws_1", to: "+1")

        XCTAssertEqual(result.failureOnly, .http(status: 401, message: nil))
        XCTAssertEqual(transport.requests.count, 0, "an unauthenticated dial must not reach the carrier")
    }
}
