import AuthenticationServices
@testable import DistrictAI
import DistrictAuthCore
import DistrictNetwork
import Foundation
import XCTest

/// ``AppleSignInController``, as far as a simulator can drive it.
///
/// ⛔ THE ONE THING THESE CASES CANNOT REACH IS THE SUCCESS PATH THROUGH
/// `complete(_:)`, AND IT IS A HARD LIMIT RATHER THAN A GAP TO CLOSE.
/// `ASAuthorization` has no public initialiser and no subclassable surface, so
/// nothing outside AuthenticationServices can produce one; a mock would have to
/// be a mock of Apple's framework. That is exactly why ``exchange(identityToken:
/// nonce:)`` takes the raw `Data` rather than the credential — everything below
/// the unwrap is driven here, and the unwrap itself is two lines with no
/// branching of ours in them.
///
/// ⚠️ SO THE END-TO-END PROOF IS A SIGNED DEVICE INSTALL, not this file and not
/// the XCUITest. A simulator cannot authenticate a real Apple ID, and the
/// entitlement these tests run without is signing-consumed.
final class AppleSignInControllerTests: XCTestCase {
    private static let host = URL(string: "https://auth.example.test")!

    private static let tokenBody = """
    {
      "tokenType": "Bearer",
      "accessToken": "at.jwt",
      "accessTokenExpiresAt": 1750000000000,
      "refreshToken": "rt-opaque",
      "refreshTokenExpiresAt": 1755000000000
    }
    """

    @MainActor
    private func makeController(
        _ transport: AppleTestTransport,
        store: InMemoryTokenStore = InMemoryTokenStore()
    ) -> (AppleSignInController, TokenRefreshCoordinator) {
        let auth = AppNativeAuthClient(baseURL: Self.host, transport: transport)
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: auth)
        let controller = AppleSignInController(
            auth: auth,
            coordinator: coordinator,
            deviceId: "install-0123456789",
            deviceName: "Test iPhone"
        )
        return (controller, coordinator)
    }

    // ── Leg one ──────────────────────────────────────────────────────────────

    /// ⛔ THE **HASHED** HALF GOES ON THE REQUEST. Apple echoes this value back
    /// verbatim as the token's `nonce` claim and the server compares it to the
    /// SHA-256 of what arrives in the body — so a controller that stamped the
    /// raw value here would be refused every time, with an opaque
    /// `invalid_grant` that reads exactly like a replayed token.
    @MainActor
    func testPrepareStampsTheHashedNonceAndBothScopes() throws {
        let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))
        let request = ASAuthorizationAppleIDProvider().createRequest()

        controller.prepare(request)

        let stamped = try XCTUnwrap(request.nonce)
        XCTAssertEqual(stamped.count, 64, "a SHA-256 in lower-case hex is 64 characters")
        XCTAssertEqual(Set(request.requestedScopes ?? []), [.fullName, .email])
    }

    /// ⛔ THE SWAPPED-HALVES TEST, AND IT IS THE ONE THAT MATTERS IN THIS FILE.
    /// The digest goes on the request; the raw value goes in the body. Swapping
    /// them produces two well-formed strings, a request Apple accepts, and a
    /// server refusal that is byte-identical to a replayed token — so nothing
    /// downstream could ever tell you which mistake was made.
    @MainActor
    func testTheStampedHalfIsTheDigestAndTheSentHalfIsTheRawValue() async throws {
        let transport = AppleTestTransport(json: Self.tokenBody)
        let (controller, _) = makeController(transport)
        let request = ASAuthorizationAppleIDProvider().createRequest()

        controller.prepare(request)
        let pending = try XCTUnwrap(controller.pending)

        XCTAssertEqual(request.nonce, pending.hashed)
        XCTAssertNotEqual(request.nonce, pending.raw)

        _ = await controller.exchange(identityToken: Data("header.payload.sig".utf8), nonce: pending)

        let sent = try XCTUnwrap(transport.lastBodyField("nonce"))
        XCTAssertEqual(sent, pending.raw)
        // ⚠️ THE SERVER'S OWN COMPARISON, RUN LOCALLY: it hashes what arrived in
        // the body and expects the token's `nonce` claim, which is whatever was
        // stamped on the request.
        XCTAssertEqual(AppleNonce.sha256Hex(sent), request.nonce)
    }

    /// ⚠️ A FRESH NONCE PER ATTEMPT. Reusing one would let a token captured from
    /// an earlier attempt be replayed into a later one.
    @MainActor
    func testEachPrepareMintsAFreshNonce() {
        let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))
        let first = ASAuthorizationAppleIDProvider().createRequest()
        let second = ASAuthorizationAppleIDProvider().createRequest()

        controller.prepare(first)
        controller.prepare(second)

        XCTAssertNotNil(first.nonce)
        XCTAssertNotEqual(first.nonce, second.nonce)
    }

    // ── Leg two ──────────────────────────────────────────────────────────────

    /// ⛔ THE BODY IS THE ROUTE'S SCHEMA, AND `authorizationCode` IS ABSENT.
    /// Including it is a 400 indistinguishable from a rejected token.
    @MainActor
    func testTheExchangeSendsTheRouteSchemaAndAdoptsTheTokens() async throws {
        let transport = AppleTestTransport(json: Self.tokenBody)
        let store = InMemoryTokenStore()
        let (controller, _) = makeController(transport, store: store)

        let outcome = await controller.exchange(
            identityToken: Data("header.payload.sig".utf8),
            nonce: AppleNonce(raw: String(repeating: "ab", count: 32))
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "https://auth.example.test/api/auth/native/apple")
        XCTAssertEqual(try transport.lastBodyField("identityToken"), "header.payload.sig")
        XCTAssertEqual(try transport.lastBodyField("nonce"), String(repeating: "ab", count: 32))
        XCTAssertEqual(try transport.lastBodyField("deviceId"), "install-0123456789")
        XCTAssertEqual(try transport.lastBodyField("deviceName"), "Test iPhone")
        XCTAssertEqual(try transport.lastBodyField("platform"), "ios")
        XCTAssertNil(try transport.lastBodyField("authorizationCode"))
        // ⛔ THE COORDINATOR ADOPTED, which is what makes the two doors
        // indistinguishable to everything above them.
        let persisted = try await store.read()
        XCTAssertEqual(persisted?.refreshToken, "rt-opaque")
    }

    /// ⛔ STATUS BY STATUS, AND `rejected` MUST NOT BECOME `unreachable`. One
    /// tells the user to try again, the other sends them to check their wifi.
    /// ⛔ AND 403 IS `noAccount`, NEITHER OF THEM: no retry can help an Apple ID
    /// that has no account, and "try again" for it reads as broken sign-in.
    @MainActor
    func testTheExchangeStatusMap() async {
        let rows: [(status: Int, expected: LoginOutcome)] = [
            (400, .rejected),
            (403, .noAccount),
            (429, .rateLimited),
            (500, .unreachable),
            (401, .unreachable),
        ]

        for row in rows {
            let (controller, _) = makeController(AppleTestTransport(json: "{}", status: row.status))
            let outcome = await controller.exchange(identityToken: Data("t".utf8), nonce: AppleNonce(raw: "n"))
            XCTAssertEqual(outcome, row.expected, "HTTP \(row.status)")
        }
    }

    /// ⛔ A MISSING OR UNREADABLE TOKEN IS A REFUSAL, NEVER AN EMPTY BODY. A
    /// compact JWS is ASCII by construction so this cannot fire in practice,
    /// which is exactly why it must not fall through to sending `""` and reading
    /// the 400 back as a rejected sign-in.
    @MainActor
    func testAnAbsentIdentityTokenIsRefusedWithoutARequest() async {
        let transport = AppleTestTransport(json: Self.tokenBody)
        let (controller, _) = makeController(transport)

        let outcome = await controller.exchange(identityToken: nil, nonce: AppleNonce(raw: "n"))

        XCTAssertEqual(outcome, .denied("apple_no_identity_token"))
        XCTAssertEqual(transport.recorded.count, 0, "nothing may be sent")
    }

    @MainActor
    func testAnEmptyIdentityTokenIsRefusedWithoutARequest() async {
        let transport = AppleTestTransport(json: Self.tokenBody)
        let (controller, _) = makeController(transport)

        let outcome = await controller.exchange(identityToken: Data(), nonce: AppleNonce(raw: "n"))

        XCTAssertEqual(outcome, .denied("apple_no_identity_token"))
        XCTAssertEqual(transport.recorded.count, 0)
    }

    /// ⚠️ INVALID UTF-8 TAKES THE SAME BRANCH. `String(data:encoding: .utf8)`
    /// returns nil rather than substituting replacement characters, so a
    /// corrupted token is refused rather than sent as mojibake.
    @MainActor
    func testAnUndecodableIdentityTokenIsRefused() async {
        let transport = AppleTestTransport(json: Self.tokenBody)
        let (controller, _) = makeController(transport)

        let outcome = await controller.exchange(
            identityToken: Data([0xFF, 0xFE, 0xFD]),
            nonce: AppleNonce(raw: "n")
        )

        XCTAssertEqual(outcome, .denied("apple_no_identity_token"))
        XCTAssertEqual(transport.recorded.count, 0)
    }

    // ── Failures and cancellation ────────────────────────────────────────────

    /// ⛔ A CANCELLATION IS A QUIET NO-OP. It is the commonest outcome after
    /// success, and `SessionModel` deliberately does nothing with it: a user who
    /// opens the sheet and changes their mind must not be told their sign-in
    /// failed.
    @MainActor
    func testACancellationIsQuiet() async {
        let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))
        controller.prepare(ASAuthorizationAppleIDProvider().createRequest())

        let outcome = await controller.complete(.failure(ASAuthorizationError(.canceled)))

        XCTAssertEqual(outcome, .cancelled)
    }

    /// ⛔ EVERY OTHER `ASAuthorizationError` IS `denied`, NOT `unreachable`. None
    /// of them is a network condition — 1000 is what a missing entitlement
    /// produces — and "check your connection" sends the user to fix their wifi.
    @MainActor
    func testEveryOtherAuthorizationErrorNamesItsCode() async {
        let rows: [(ASAuthorizationError.Code, String)] = [
            (.unknown, "apple_1000"),
            (.invalidResponse, "apple_1002"),
            (.notHandled, "apple_1003"),
            (.failed, "apple_1004"),
        ]

        for row in rows {
            let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))
            controller.prepare(ASAuthorizationAppleIDProvider().createRequest())
            let outcome = await controller.complete(.failure(ASAuthorizationError(row.0)))
            XCTAssertEqual(outcome, .denied(row.1), "\(row.0)")
        }
    }

    /// ⚠️ AN ERROR THAT IS NOT AN `ASAuthorizationError` AT ALL still lands on a
    /// sentence rather than on nothing.
    @MainActor
    func testAnUnclassifiedErrorIsStillDenied() async {
        let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))
        controller.prepare(ASAuthorizationAppleIDProvider().createRequest())

        let outcome = await controller.complete(.failure(URLError(.notConnectedToInternet)))

        XCTAssertEqual(outcome, .denied("apple_failed"))
    }

    /// ⛔ A RESULT WITH NO ATTEMPT IN FLIGHT IS BENIGN AND SPENDS NOTHING. It is
    /// the same distinction `WebAuthLoginController` draws between a stale
    /// callback and a hostile one.
    @MainActor
    func testAResultWithNoPendingAttemptIsANoOp() async {
        let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))

        let outcome = await controller.complete(.failure(ASAuthorizationError(.failed)))

        XCTAssertEqual(outcome, .noAttemptInProgress)
    }

    /// ⚠️ THE ATTEMPT IS SPENT WHATEVER HAPPENS, so a second result cannot reuse
    /// the same nonce.
    @MainActor
    func testAnAttemptIsSpentOnce() async {
        let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))
        controller.prepare(ASAuthorizationAppleIDProvider().createRequest())

        _ = await controller.complete(.failure(ASAuthorizationError(.canceled)))
        let second = await controller.complete(.failure(ASAuthorizationError(.canceled)))

        XCTAssertEqual(second, .noAttemptInProgress)
    }

    @MainActor
    func testCancelAbandonsThePendingAttempt() async {
        let (controller, _) = makeController(AppleTestTransport(json: Self.tokenBody))
        controller.prepare(ASAuthorizationAppleIDProvider().createRequest())

        controller.cancel()

        let outcome = await controller.complete(.failure(ASAuthorizationError(.canceled)))
        XCTAssertEqual(outcome, .noAttemptInProgress)
    }
}

// MARK: - Helpers

/// A transport double that records what it was asked to send.
///
/// ⚠️ ITS OWN, RATHER THAN `SchedulingTestTransport`. That one routes on a
/// scheduling `op` name and answers 500 for anything it does not recognise,
/// which is the wrong shape for a single unauthenticated POST.
private final class AppleTestTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: Result<HTTPResponse, any Error>
    private(set) var recorded: [HTTPRequest] = []

    init(json: String, status: Int = 200) {
        response = .success(
            HTTPResponse(
                statusCode: status,
                headers: ["Content-Type": "application/json"],
                body: Data(json.utf8)
            )
        )
    }

    var lastRequest: HTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last
    }

    /// One field of the last body, as a string. ⚠️ Reads the ENCODED bytes: a
    /// test that compared the struct it built would say nothing about the wire.
    func lastBodyField(_ name: String) throws -> String? {
        let body = try XCTUnwrap(lastRequest?.body)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        return object?[name] as? String
    }

    func send(_ request: HTTPRequest, followRedirects _: Bool) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        return try response.get()
    }
}
