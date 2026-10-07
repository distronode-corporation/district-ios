@testable import DistrictAI
import DistrictAuthCore
import DistrictNetwork
import Foundation
import XCTest

/// The authenticator-code step after Sign in with Apple: the Apple route's
/// `401 mfa_required`, ``AppleSignInController/submitCode(_:for:now:)``, and what the
/// session gate does with each answer.
///
/// ⚠️ THE BODIES ARE THE SERVICE'S RECORDED FIXTURES, INLINED. This app keeps no
/// contract copies (district-core-swift holds them and gates them strictly); these two
/// strings are `district-native-apple-mfa-required.json` and `district-native-mfa.json`
/// as recorded.
final class AppleMfaStepTests: XCTestCase {
    /// One row of the status map. ⚠️ A struct, since SwiftLint caps tuples at two members.
    private struct Row {
        let status: Int
        let body: String
        let expected: MfaCodeOutcome

        init(_ status: Int, _ body: String, _ expected: MfaCodeOutcome) {
            self.status = status
            self.body = body
            self.expected = expected
        }
    }

    private static let host = URL(string: "https://auth.example.test")!

    private static let mfaRequiredBody = """
    {
      "error": "mfa_required",
      "code": "MFA_REQUIRED",
      "message": "Enter the code from your authenticator app.",
      "mfaTicket": "q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s",
      "mfaTicketExpiresAt": "2026-08-15T14:35:00.000Z"
    }
    """

    private static let grantBody = """
    {
      "tokenType": "Bearer",
      "accessToken": "access-contract-token",
      "accessTokenExpiresAt": 1786804800000,
      "refreshToken": "refresh-contract-token",
      "refreshTokenExpiresAt": 1791988200000
    }
    """

    private static let ticket = "q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s"
    private static let expiresAt = Date(timeIntervalSince1970: 1_786_804_500)
    private static let challenge = NativeMfaChallenge(ticket: ticket, expiresAt: expiresAt)
    /// A moment the fixture's ticket is still live.
    private static let beforeExpiry = expiresAt.addingTimeInterval(-60)

    @MainActor
    private func makeController(
        _ transport: AppleTestTransport,
        store: InMemoryTokenStore = InMemoryTokenStore()
    ) -> AppleSignInController {
        let auth = AppNativeAuthClient(baseURL: Self.host, transport: transport)
        return AppleSignInController(
            auth: auth,
            coordinator: TokenRefreshCoordinator(store: store, refreshClient: auth),
            deviceId: "install-0123456789",
            deviceName: "Test iPhone"
        )
    }

    // ── The Apple leg ────────────────────────────────────────────────────────

    /// ⛔ THE RECORDED 401 OPENS THE CODE STEP, AND NOTHING IS ADOPTED. Before the step
    /// existed this was `.unreachable`, "check your connection", for an account that had
    /// done everything right.
    @MainActor
    func testTheMfaRequiredAnswerOpensTheCodeStepWithoutSigningIn() async throws {
        let store = InMemoryTokenStore()
        let controller = makeController(AppleTestTransport(json: Self.mfaRequiredBody, status: 401), store: store)

        let outcome = await controller.exchange(identityToken: Data("t".utf8), nonce: AppleNonce(raw: "n"))

        XCTAssertEqual(outcome, .mfaRequired(Self.challenge))
        let persisted = try await store.read()
        XCTAssertNil(persisted, "no credential until the code is accepted")
    }

    // ── The code ─────────────────────────────────────────────────────────────

    /// ⛔ THE GRANT IS ADOPTED BY THE SAME COORDINATOR, and the body carries the Apple
    /// leg's own install id and platform, which the ticket is bound to.
    @MainActor
    func testAnAcceptedCodeAdoptsTheGrantAndSendsTheAppleLegsDevice() async throws {
        let transport = AppleTestTransport(json: Self.grantBody)
        let store = InMemoryTokenStore()
        let controller = makeController(transport, store: store)

        let outcome = await controller.submitCode("123456", for: Self.challenge, now: Self.beforeExpiry)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "https://auth.example.test/api/auth/native/mfa")
        XCTAssertEqual(try transport.lastBodyField("mfaTicket"), Self.ticket)
        XCTAssertEqual(try transport.lastBodyField("code"), "123456")
        XCTAssertEqual(try transport.lastBodyField("deviceId"), "install-0123456789")
        XCTAssertEqual(try transport.lastBodyField("deviceName"), "Test iPhone")
        XCTAssertEqual(try transport.lastBodyField("platform"), "ios")
        let persisted = try await store.read()
        XCTAssertEqual(persisted?.refreshToken, "refresh-contract-token")
    }

    /// ⛔ A WRONG CODE AND A DEAD TICKET MUST NOT CROSS. The first keeps the sheet open
    /// for another try; the second sends the person back to the Apple button.
    @MainActor
    func testTheCodeStatusMap() async throws {
        let rows = [
            Row(401, #"{"error":"invalid_credentials","code":"invalid_credentials"}"#, .wrongCode),
            Row(400, #"{"error":"invalid_grant","code":"invalid_credentials"}"#, .expired),
            Row(429, #"{"error":"Too many requests. Please try again shortly."}"#, .rateLimited),
            Row(500, #"{"error":"server_error"}"#, .unreachable),
            Row(200, "<html>captive portal</html>", .unreachable),
        ]

        for row in rows {
            let store = InMemoryTokenStore()
            let controller = makeController(AppleTestTransport(json: row.body, status: row.status), store: store)
            let outcome = await controller.submitCode("123456", for: Self.challenge, now: Self.beforeExpiry)
            XCTAssertEqual(outcome, row.expected, "HTTP \(row.status)")
            let persisted = try await store.read()
            XCTAssertNil(persisted, "HTTP \(row.status) adopts nothing")
        }
    }

    /// ⚠️ A TICKET THAT HAS CERTAINLY EXPIRED IS NOT SENT: the answer would be the same
    /// 400, and the server counts every code it is sent.
    @MainActor
    func testAnExpiredTicketIsNotSent() async {
        let transport = AppleTestTransport(json: Self.grantBody)
        let controller = makeController(transport)

        let outcome = await controller.submitCode("123456", for: Self.challenge, now: Self.expiresAt)

        XCTAssertEqual(outcome, .expired)
        XCTAssertNil(transport.lastRequest)
    }

    /// ⚠️ AN EXPIRY THIS BUILD COULD NOT READ IS NOT "EXPIRED": the code is sent and the
    /// server decides.
    @MainActor
    func testAnUnknownExpiryIsSent() async {
        let transport = AppleTestTransport(json: Self.grantBody)
        let controller = makeController(transport)

        let outcome = await controller.submitCode(
            "ABCDE-FGHJK",
            for: NativeMfaChallenge(ticket: Self.ticket, expiresAt: nil),
            now: .distantFuture
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(try transport.lastBodyField("code"), "ABCDE-FGHJK")
    }

    // ── What the session gate does ───────────────────────────────────────────

    /// ⛔ ONLY `expired` CLOSES THE SHEET WITHOUT SIGNING IN. Every other refusal leaves
    /// the ticket usable, so the person types again on the same sheet.
    func testEachOutcomesReaction() {
        XCTAssertEqual(MfaCodeOutcome.success.reaction, .signedIn)
        XCTAssertEqual(MfaCodeOutcome.wrongCode.reaction, .stayOpen(MfaCopy.wrongCode))
        XCTAssertEqual(MfaCodeOutcome.expired.reaction, .startOver(MfaCopy.expired))
        XCTAssertEqual(MfaCodeOutcome.rateLimited.reaction, .stayOpen(SessionCopy.tooManyAttempts))
        XCTAssertEqual(MfaCodeOutcome.unreachable.reaction, .stayOpen(SessionCopy.unreachable))
    }

    /// ⚠️ THE EXPIRED SENTENCE LANDS ON THE SIGN-IN SCREEN AS A WARNING, recoverable by
    /// signing in again, and it tells the person how.
    func testTheExpiredSentenceIsAWarningThatSaysWhatToDo() {
        XCTAssertEqual(SignInStatusTone.forReason(MfaCopy.expired), .warning)
        XCTAssertTrue(MfaCopy.expired.contains("Sign in with Apple again"))
    }

    /// ⛔ A SHEET ITEM CARRIES ITS OWN IDENTITY, NOT THE TICKET'S, so two code steps for
    /// the same ticket are still two presentations and no credential is a view id.
    func testEachPendingStepHasItsOwnIdentity() {
        let first = PendingMfa(challenge: Self.challenge)
        let second = PendingMfa(challenge: Self.challenge)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.id.uuidString.contains(Self.ticket))
    }
}
