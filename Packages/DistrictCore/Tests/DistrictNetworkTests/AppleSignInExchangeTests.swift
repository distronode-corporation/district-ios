@testable import DistrictNetwork
import Foundation
import XCTest

/// `POST /api/auth/native/apple`: the body it is handed, and what this client
/// makes of every status it can answer.
///
/// ⛔ THE BODY ASSERTIONS READ THE ENCODED BYTES, NOT THE STRUCT. A test that
/// compared `request.identityToken` to what it had just put there would prove
/// nothing about the wire, and the wire is the only thing the server sees: a
/// `CodingKeys` enum, a property rename or a hand-written `encode(to:)` could
/// change every key and leave such a test green. The route answers one opaque
/// `invalid_grant` for a schema failure, indistinguishable from a rejected
/// token, so nothing downstream would say which it was.
final class AppleSignInExchangeTests: XCTestCase {
    /// One row of the status map. ⚠️ A STRUCT RATHER THAN A TUPLE, which SwiftLint
    /// caps at two members — and it earns the type by carrying its own source line,
    /// so a failing row names itself instead of naming the loop.
    private struct Row {
        let status: Int
        let body: String
        let expected: CodeExchangeResult<MirrorTokens>
        let line: UInt

        init(_ status: Int, _ body: String, _ expected: CodeExchangeResult<MirrorTokens>, line: UInt = #line) {
            self.status = status
            self.body = body
            self.expected = expected
            self.line = line
        }
    }

    private enum Fixture {
        static let host = "https://auth.example.test"

        static let tokenBody = """
        {
          "tokenType": "Bearer",
          "accessToken": "at.jwt",
          "accessTokenExpiresAt": 1750000000000,
          "refreshToken": "rt-opaque",
          "refreshTokenExpiresAt": 1755000000000
        }
        """

        static let tokens = MirrorTokens(
            accessToken: "at.jwt",
            accessTokenExpiresAt: 1_750_000_000_000,
            refreshToken: "rt-opaque",
            refreshTokenExpiresAt: 1_755_000_000_000
        )

        /// ⚠️ A THREE-SEGMENT PLACEHOLDER, NOT A REAL TOKEN. Nothing on this tier
        /// parses it — the server does, against Apple's JWKS — so a value that
        /// merely looks like a JWS is the honest fixture.
        static let request = AppleNativeSignInRequest(
            identityToken: "header.payload.signature",
            nonce: "0011223344556677",
            deviceId: "install-0123456789",
            deviceName: "Test iPhone"
        )
    }

    private func makeClient(_ transport: TestTransport) -> TestNativeAuthClient {
        TestNativeAuthClient(baseURL: URL(string: Fixture.host)!, transport: transport)
    }

    // ── The status map ───────────────────────────────────────────────────────

    /// ⛔ STATUS BY STATUS, READ OFF THE ROUTE. Every refusal it can make — a
    /// signature that does not verify, a wrong audience, an expired token, a
    /// nonce mismatch, an unresolvable subject, an address whose verification
    /// was withdrawn — is the SAME opaque 400, and all of them mean "start the
    /// sign-in over".
    ///
    /// ⚠️ A 200 THIS BUILD CANNOT PARSE IS AMBIGUOUS, NOT A REFUSAL: the server
    /// minted a session and this build cannot read it, so the user must not be
    /// told their sign-in was rejected.
    func testTheAppleStatusMap() async {
        let rows = [
            Row(200, Fixture.tokenBody, .success(Fixture.tokens)),
            Row(200, #"{"success":true}"#, .transportFailure),
            Row(200, "<html>captive portal</html>", .transportFailure),
            Row(400, #"{"error":"invalid_grant"}"#, .rejected),
            Row(403, #"{"error":"no_account"}"#, .noAccount),
            Row(429, #"{"error":"rate_limited"}"#, .rateLimited),
            // The route does not answer any of these; all are ambiguous.
            Row(401, "{}", .transportFailure),
            Row(404, "", .transportFailure),
            Row(500, #"{"error":"server_error"}"#, .transportFailure),
            Row(503, "", .transportFailure),
        ]

        for row in rows {
            let client = makeClient(TestTransport(json: row.body, status: row.status))
            let result = await client.exchangeAppleIdentityToken(Fixture.request)
            XCTAssertEqual(result, row.expected, "HTTP \(row.status)", line: row.line)
        }
    }

    /// ⛔ 403 IS `noAccount`, KEYED ON THE STATUS ALONE. The route answers it
    /// for a verified Apple ID that no account uses, since sign-in never creates
    /// one. The body is the server's `no_account` JSON today, but an empty or
    /// unparseable body (a proxy's page, a future rewording) must reach the same
    /// case: the alternative is `transportFailure`, which tells the user to check
    /// their connection and reads as broken sign-in.
    func testA403IsNoAccountWhateverTheBody() async {
        let bodies = [
            #"{"error":"no_account","message":"No District AI account uses this Apple ID."}"#,
            #"{"error":"something_else"}"#,
            "",
            "<html>forbidden</html>",
        ]

        for body in bodies {
            let client = makeClient(TestTransport(json: body, status: 403))
            let result = await client.exchangeAppleIdentityToken(Fixture.request)
            XCTAssertEqual(result, .noAccount, "body: \(body)")
        }
    }

    /// ⚠️ A 200 WITH NO BODY AT ALL takes the same ambiguous branch as an
    /// unparseable one.
    func testA200WithNoBodyIsAmbiguous() async {
        let result = await makeClient(TestTransport(status: 200)).exchangeAppleIdentityToken(Fixture.request)

        XCTAssertEqual(result, .transportFailure)
    }

    /// ⛔ NO `notSent` HERE, AND NONE IS NEEDED. `notSent` exists so a refresh
    /// token that provably never left the device is not treated as spent; an
    /// identity token is single-use against this route and the flow restarts
    /// from a fresh `ASAuthorizationController` either way, so every I/O failure
    /// is one outcome.
    func testEveryIoFailureIsTransportFailure() async {
        let errors: [any Error] = [
            URLError(.dnsLookupFailed),
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            StubTransportError(isProvablyUnsent: true),
            TransportStub.offline,
        ]

        for error in errors {
            let client = makeClient(TestTransport(throwing: error))
            let result = await client.exchangeAppleIdentityToken(Fixture.request)
            XCTAssertEqual(result, .transportFailure, "\(error)")
        }
    }

    // ── The body ─────────────────────────────────────────────────────────────

    /// ⛔ FIVE KEYS, AND `authorizationCode` IS NOT ONE OF THEM. The credential
    /// Apple hands the app also carries an authorization code, which is what the
    /// WEB leg spends against Apple's token endpoint; this route verifies the
    /// identity token against Apple's JWKS directly and its schema has no such
    /// field, so sending it is a 400 that reads exactly like a rejected token.
    ///
    /// ⛔ AND `platform` IS `"ios"`: `z.enum(["ios", "android"])`.
    func testTheBodyIsTheRouteSchema() async throws {
        let transport = TestTransport(json: Fixture.tokenBody)

        _ = await makeClient(transport).exchangeAppleIdentityToken(Fixture.request)

        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else { return XCTFail("the body is not a JSON object") }
        XCTAssertEqual(
            Set(fields.keys),
            ["identityToken", "nonce", "deviceId", "deviceName", "platform"]
        )
        XCTAssertNil(body["authorizationCode"])
        XCTAssertEqual(body["identityToken"]?.stringValue, "header.payload.signature")
        XCTAssertEqual(body["nonce"]?.stringValue, "0011223344556677")
        XCTAssertEqual(body["deviceId"]?.stringValue, "install-0123456789")
        XCTAssertEqual(body["deviceName"]?.stringValue, "Test iPhone")
        XCTAssertEqual(body["platform"]?.stringValue, "ios")
    }

    /// ⛔ OMITTED, NOT SENT EMPTY OR NULL. The settings device list renders
    /// whatever arrives, so a null would be a blank row in a security screen.
    /// ⚠️ This is synthesised `Encodable` behaviour (`encodeIfPresent` for an
    /// Optional stored property) rather than something the type arranges, which
    /// is exactly why it is asserted: a hand-written `encode(to:)` added later
    /// would change it silently.
    func testTheDeviceNameIsOmittedRatherThanSentNull() async throws {
        let transport = TestTransport(json: Fixture.tokenBody)
        let request = AppleNativeSignInRequest(
            identityToken: "header.payload.signature",
            nonce: "0011223344556677",
            deviceId: "install-0123456789",
            deviceName: nil
        )

        _ = await makeClient(transport).exchangeAppleIdentityToken(request)

        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else { return XCTFail("the body is not a JSON object") }
        XCTAssertEqual(Set(fields.keys), ["identityToken", "nonce", "deviceId", "platform"])
        XCTAssertNil(body["deviceName"])
    }

    /// ⛔ THE **RAW** NONCE TRAVELS IN THE BODY, NEVER THE HASHED ONE. The server
    /// SHA-256s this value and compares the digest to the token's `nonce` claim,
    /// so sending the digest here means the server hashes a hash and refuses.
    /// ⚠️ The pairing is `DistrictAuthCore.AppleNonce`'s to make; this asserts
    /// only that the field is carried verbatim, which is what a caller holding
    /// the right value depends on.
    func testTheNonceIsCarriedVerbatim() async throws {
        let transport = TestTransport(json: Fixture.tokenBody)
        let raw = String(repeating: "ab", count: 32)
        let request = AppleNativeSignInRequest(
            identityToken: "t",
            nonce: raw,
            deviceId: "install-0123456789",
            deviceName: nil
        )

        _ = await makeClient(transport).exchangeAppleIdentityToken(request)

        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        XCTAssertEqual(body["nonce"]?.stringValue, raw)
    }

    /// ⛔ `platform` IS NOT A PARAMETER, so no caller can list this device as an
    /// Android one in the settings device list.
    func testThePlatformIsNotSettable() {
        XCTAssertEqual(Fixture.request.platform, "ios")
        XCTAssertEqual(
            AppleNativeSignInRequest(identityToken: "t", nonce: "n", deviceId: "d", deviceName: nil).platform,
            "ios"
        )
    }

    // ── The request ──────────────────────────────────────────────────────────

    /// ⛔ NO BEARER, ONE REQUEST, AND ITS OWN PATH. Acquiring an access token is
    /// what this call is FOR, and it is a SIBLING of `native/token` rather than
    /// a variant: the two authenticate completely different things and carry
    /// separate rate-limit buckets server-side.
    func testItPostsOnceToItsOwnPathWithNoBearer() async {
        let transport = TestTransport(json: Fixture.tokenBody)

        _ = await makeClient(transport).exchangeAppleIdentityToken(Fixture.request)

        XCTAssertEqual(NativeAuthPaths.apple, ["api", "auth", "native", "apple"])
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(transport.lastRequest?.method, .post)
        XCTAssertEqual(
            transport.lastRequest?.url.absoluteString,
            "https://auth.example.test/api/auth/native/apple"
        )
        XCTAssertNil(transport.lastRequest?.headers["Authorization"])
        XCTAssertEqual(transport.lastRequest?.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(transport.lastRequest?.headers["Accept"], "application/json")
        // ⛔ REDIRECTS FOLLOWED, like both sibling exchanges. A credential
        // exchange that stopped at a 308 would report `transportFailure` and
        // read as an outage.
        XCTAssertEqual(transport.lastFollowedRedirects, true)
        XCTAssertNil(transport.lastRequest?.url.query)
    }

    /// ⚠️ A TRAILING SLASH ON THE BASE URL IS ABSORBED. `//api/auth/...`
    /// addresses a different path, and a configured host is the kind of value
    /// that carries one.
    func testATrailingSlashOnTheBaseUrlIsAbsorbed() async {
        let transport = TestTransport(json: Fixture.tokenBody)
        let client = TestNativeAuthClient(baseURL: URL(string: Fixture.host + "/")!, transport: transport)

        _ = await client.exchangeAppleIdentityToken(Fixture.request)

        XCTAssertEqual(
            transport.lastRequest?.url.absoluteString,
            "https://auth.example.test/api/auth/native/apple"
        )
    }
}
