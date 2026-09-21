@testable import DistrictNetwork
import Foundation
import XCTest

/// Fixtures for the two unauthenticated routes.
private enum Fixture {
    static let host = "https://auth.example.test"

    /// The five-key body BOTH routes answer, built from the two
    /// `NextResponse.json({...})` calls rather than assumed.
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

    static let exchange = CodeExchangeRequest(
        code: "one-time-code",
        codeVerifier: "verifier-43-chars",
        redirectUri: "districtai://auth",
        deviceId: "install-0123456789",
        deviceName: "Test iPhone"
    )
}

/// One row of a status map: what the server answered, and what this client must
/// make of it. ⚠️ Carries its own source line so a failing row names itself.
private struct StatusRow<Expected> {
    let status: Int
    let body: String
    let expected: Expected
    let line: UInt

    init(_ status: Int, _ body: String, _ expected: Expected, line: UInt = #line) {
        self.status = status
        self.body = body
        self.expected = expected
        self.line = line
    }
}

/// One row of the `notSent` boundary: what the transport threw, and whether the
/// refresh token may be presented again.
private struct ErrorRow {
    let error: any Error
    let expected: MirrorRefreshResult
    let line: UInt

    init(_ error: any Error, _ expected: MirrorRefreshResult, line: UInt = #line) {
        self.error = error
        self.expected = expected
        self.line = line
    }
}

final class NativeAuthClientTests: XCTestCase {
    private func makeClient(_ transport: TestTransport, base: String = Fixture.host) -> TestNativeAuthClient {
        TestNativeAuthClient(baseURL: URL(string: base)!, transport: transport)
    }

    // ── The two status maps ──────────────────────────────────────────────────

    /// ⛔ THE EXCHANGE MAP, STATUS BY STATUS. A 400 here is `rejected` — the
    /// token route answers one opaque `invalid_grant` for expired, replayed,
    /// PKCE-mismatched and redirect-mismatched codes alike, and all four mean
    /// "start the login over".
    ///
    /// ⚠️ A 200 THAT WILL NOT PARSE IS `transportFailure`, NOT `rejected`: the
    /// server minted a session this build cannot read, which is ambiguous rather
    /// than a refusal.
    func testTheExchangeStatusMap() async {
        let rows: [StatusRow<CodeExchangeResult<MirrorTokens>>] = [
            StatusRow(200, Fixture.tokenBody, .success(Fixture.tokens)),
            StatusRow(200, #"{"success":true}"#, .transportFailure),
            StatusRow(200, "<html>captive portal</html>", .transportFailure),
            StatusRow(400, #"{"error":"invalid_grant"}"#, .rejected),
            StatusRow(429, #"{"error":"rate_limited"}"#, .rateLimited),
            // Everything else is ambiguous, including a 401 (which the exchange
            // route does not answer) and a redirect that arrived anyway.
            StatusRow(401, "{}", .transportFailure),
            // ⚠️ `noAccount` is the APPLE route's 403, never this one's.
            StatusRow(403, #"{"error":"no_account"}"#, .transportFailure),
            StatusRow(302, "", .transportFailure),
            StatusRow(500, "", .transportFailure),
            StatusRow(503, "", .transportFailure),
        ]

        for row in rows {
            let client = makeClient(TestTransport(json: row.body, status: row.status))
            let result = await client.exchangeCode(Fixture.exchange)
            XCTAssertEqual(result, row.expected, "HTTP \(row.status)", line: row.line)
        }
    }

    /// ⛔ THE REFRESH MAP, STATUS BY STATUS, AND IT IS THE SECURITY-RELEVANT ONE.
    /// It is `RefreshResult`'s own table: 401 is the only dead credential, and
    /// **429 and 400 are both `rateLimited`** because the route rate-limits and
    /// validates its body BEFORE `rotateNativeSession` — so in both cases the
    /// token is provably unspent. Mapping either onto `rejected` signs a user out
    /// while their credential is still valid.
    func testTheRefreshStatusMap() async {
        let rows: [StatusRow<MirrorRefreshResult>] = [
            StatusRow(200, Fixture.tokenBody, .success(Fixture.tokens)),
            StatusRow(200, #"{"success":true}"#, .transportFailure),
            StatusRow(401, #"{"error":"invalid_grant"}"#, .rejected),
            StatusRow(429, #"{"error":"rate_limited"}"#, .rateLimited),
            StatusRow(400, #"{"error":"invalid_request"}"#, .rateLimited),
            StatusRow(403, "", .transportFailure),
            StatusRow(500, "", .transportFailure),
            StatusRow(502, "", .transportFailure),
        ]

        for row in rows {
            let client = makeClient(TestTransport(json: row.body, status: row.status))
            let result = await client.refresh(refreshToken: "rt-opaque")
            XCTAssertEqual(result, row.expected, "HTTP \(row.status)", line: row.line)
        }
    }

    /// ⚠️ A 200 WITH NO BODY AT ALL takes the same ambiguous branch as an
    /// unparseable one, on both routes.
    func testA200WithNoBodyIsAmbiguousOnBothRoutes() async {
        let exchange = await makeClient(TestTransport(status: 200)).exchangeCode(Fixture.exchange)
        XCTAssertEqual(exchange, .transportFailure)

        let refresh = await makeClient(TestTransport(status: 200)).refresh(refreshToken: "rt-opaque")
        XCTAssertEqual(refresh, .transportFailure)
    }

    /// ⛔ THE REVOKE MAP, AND IT IS THE OPPOSITE SHAPE TO THE REFRESH ONE.
    /// There, a 4xx is fatal to the session and a 5xx is ambiguous. Here ONLY a
    /// 200 releases the credential: the route answers 200 for an unknown token
    /// on purpose, and split the 503 out precisely so a failed database write
    /// stops being reported as a completed sign-out. Every other status keeps
    /// the token in the outbox for a later launch.
    ///
    /// ⚠️ THIS IS DELIBERATELY STRICTER THAN `NativeAuthApi.kt`, which maps every
    /// 4xx to its `Done`. See the ⛔ on `RevokeOutcome`: a stuck outbox entry
    /// costs one store read per cold start, and dropping a credential the server
    /// still honours strands it for up to 60 days.
    func testTheRevokeStatusMap() async {
        let rows: [StatusRow<MirrorRevokeOutcome>] = [
            StatusRow(200, #"{"success":true}"#, .accepted),
            StatusRow(503, #"{"error":"revoke_failed"}"#, .deferred(.serverUnavailable)),
            StatusRow(429, #"{"error":"rate_limited"}"#, .deferred(.rateLimited)),
            // ⚠️ A 400 is NOT accepted, unlike on Android. The body this client
            // sends is a single string, so a 400 means something upstream
            // rewrote it, and nothing about that says the session is gone.
            StatusRow(400, #"{"error":"invalid_request"}"#, .deferred(.unexpected(status: 400))),
            StatusRow(401, "", .deferred(.unexpected(status: 401))),
            StatusRow(500, "", .deferred(.unexpected(status: 500))),
            StatusRow(502, "", .deferred(.unexpected(status: 502))),
        ]

        for row in rows {
            let client = makeClient(TestTransport(json: row.body, status: row.status))
            let result = await client.revoke(refreshToken: "rt-opaque")
            XCTAssertEqual(result, row.expected, "HTTP \(row.status)", line: row.line)
        }
    }

    /// ⛔ THE STATUS IS THE CONTRACT, NOT THE BODY. A 200 this build cannot parse
    /// is STILL `accepted`, because the route's only successful body is
    /// `{"success":true}` and nothing branches on it — treating an unreadable
    /// 200 as a failure would leave an outbox entry chasing a token the server
    /// has already forgotten. ⚠️ This is the exact opposite of the refresh path,
    /// where an unreadable 200 hides a rotation that really happened.
    func testAnUnparseable200IsStillAccepted() async {
        let bodies = ["<html>captive portal</html>", "", "null", #"{"unexpected":1}"#]

        for body in bodies {
            let client = makeClient(TestTransport(json: body, status: 200))
            let result = await client.revoke(refreshToken: "rt-opaque")
            XCTAssertEqual(result, .accepted, body)
        }

        // And a 200 with no body at all, which is a different branch again.
        let noBody = await makeClient(TestTransport(status: 200)).revoke(refreshToken: "rt")
        XCTAssertEqual(noBody, .accepted)
    }

    /// ⛔ A TRANSPORT FAILURE IS `notSent` AND KEEPS THE CREDENTIAL. ⚠️ Note that
    /// `isProvablyUnsent` is NOT consulted: it exists so a refresh can tell an
    /// unspent token from a possibly-spent one, and a revoke has no such
    /// distinction — every failure to get an answer means "try again later". So
    /// a `.timedOut`, which the refresh path calls ambiguous, is the same answer
    /// here as a DNS failure.
    func testEveryTransportFailureIsNotSent() async {
        let errors: [any Error] = [
            URLError(.dnsLookupFailed),
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            StubTransportError(isProvablyUnsent: true),
            StubTransportError(isProvablyUnsent: false),
            TransportStub.offline,
        ]

        for error in errors {
            let client = makeClient(TestTransport(throwing: error))
            let result = await client.revoke(refreshToken: "rt-opaque")
            XCTAssertEqual(result, .deferred(.notSent), "\(error)")
        }
    }

    /// ⚠️ ONE KEY, MATCHING `RevokeSchema`, and never in the URL — a query
    /// parameter would reach logs, proxies and anything that ever opened it.
    func testTheRevokeBodyCarriesTheTokenAndNothingElse() async throws {
        let transport = TestTransport(json: #"{"success":true}"#)

        _ = await makeClient(transport).revoke(refreshToken: "rt-opaque")

        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else { return XCTFail("the body is not a JSON object") }
        XCTAssertEqual(Set(fields.keys), ["refreshToken"])
        XCTAssertEqual(body["refreshToken"]?.stringValue, "rt-opaque")
        XCTAssertEqual(transport.lastRequest?.url.query, nil)
    }

    /// ⛔ NO BEARER, AND EXACTLY ONE REQUEST. The refresh token IS the credential
    /// this route authenticates with, and the client does NOT retry — the retry
    /// is the revoke outbox, on a later launch.
    func testRevokePostsOnceWithNoBearer() async {
        let transport = TestTransport(status: 503)

        _ = await makeClient(transport).revoke(refreshToken: "rt-opaque")

        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(transport.lastRequest?.method, .post)
        XCTAssertNil(transport.lastRequest?.headers["Authorization"])
        XCTAssertEqual(transport.lastRequest?.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(transport.lastFollowedRedirects, true)
        XCTAssertEqual(
            transport.lastRequest?.url.absoluteString,
            "https://auth.example.test/api/auth/native/revoke"
        )
    }

    // ── The notSent boundary ─────────────────────────────────────────────────

    /// ⛔ "NEVER LEFT THE DEVICE" IS NOT "MIGHT HAVE ROTATED THE TOKEN", AND
    /// COLLAPSING THEM BURNS SESSIONS. Opening the app offline marks the token
    /// pending, fails to send it, and the next launch reads marker == stored
    /// token as an interrupted refresh — one offline app-open costing a re-login.
    ///
    /// ⚠️ AND AN UNCLASSIFIED ERROR IS AMBIGUOUS, NEVER UNSENT: an error type
    /// that does not answer the question at all falls through to
    /// `transportFailure`.
    func testTheRefreshNotSentBoundary() async {
        let rows: [ErrorRow] = [
            ErrorRow(URLError(.dnsLookupFailed), .notSent),
            ErrorRow(URLError(.notConnectedToInternet), .notSent),
            ErrorRow(URLError(.secureConnectionFailed), .notSent),
            // ⚠️ A read timeout and a connect timeout arrive as the same code.
            ErrorRow(URLError(.timedOut), .transportFailure),
            ErrorRow(URLError(.networkConnectionLost), .transportFailure),
            // Any transport, not just a URLSession-backed one.
            ErrorRow(StubTransportError(isProvablyUnsent: true), .notSent),
            ErrorRow(StubTransportError(isProvablyUnsent: false), .transportFailure),
            // An error that does not answer the question is ambiguous.
            ErrorRow(TransportStub.offline, .transportFailure),
        ]

        for row in rows {
            let client = makeClient(TestTransport(throwing: row.error))
            let result = await client.refresh(refreshToken: "rt-opaque")
            XCTAssertEqual(result, row.expected, "\(row.error)", line: row.line)
        }
    }

    /// ⚠️ THE EXCHANGE HAS NO `notSent` CASE AND DOES NOT NEED ONE. A refresh
    /// token must not be re-presented; an authorization code is single-use and
    /// the login flow restarts either way, so every I/O failure is one outcome.
    func testAnExchangeIoFailureIsAlwaysTransportFailure() async {
        let client = makeClient(TestTransport(throwing: URLError(.dnsLookupFailed)))

        let result = await client.exchangeCode(Fixture.exchange)

        XCTAssertEqual(result, .transportFailure)
    }

    // ── The bodies ───────────────────────────────────────────────────────────

    /// ⛔ camelCase, AND THE AUTHORIZE LEG IS snake_case. The authorize page reads
    /// `code_challenge` / `state` / `redirect_uri`; this route's zod schema reads
    /// `codeVerifier` / `redirectUri`. Mixing them up fails with a 400 that is
    /// indistinguishable from a rejected code.
    ///
    /// ⛔ AND `platform` IS `"ios"`: the schema is `z.enum(["ios", "android"])`.
    func testTheExchangeBodyIsTheRouteSchema() async throws {
        let transport = TestTransport(json: Fixture.tokenBody)

        _ = await makeClient(transport).exchangeCode(Fixture.exchange)

        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else { return XCTFail("the body is not a JSON object") }
        XCTAssertEqual(
            Set(fields.keys),
            ["code", "codeVerifier", "redirectUri", "deviceId", "platform", "deviceName"]
        )
        XCTAssertEqual(body["code"]?.stringValue, "one-time-code")
        XCTAssertEqual(body["codeVerifier"]?.stringValue, "verifier-43-chars")
        XCTAssertEqual(body["redirectUri"]?.stringValue, "districtai://auth")
        XCTAssertEqual(body["deviceId"]?.stringValue, "install-0123456789")
        XCTAssertEqual(body["deviceName"]?.stringValue, "Test iPhone")
        XCTAssertEqual(body["platform"]?.stringValue, "ios")
        XCTAssertEqual(CodeExchangeRequest.platform, "ios")
    }

    /// ⛔ OMITTED, NOT SENT EMPTY. The settings device list renders whatever
    /// arrives, so an empty string would be a blank row in a security screen.
    func testTheDeviceNameIsOmittedRatherThanSentEmpty() async throws {
        let transport = TestTransport(json: Fixture.tokenBody)
        let request = CodeExchangeRequest(
            code: "c",
            codeVerifier: "v",
            redirectUri: "districtai://auth",
            deviceId: "install-0123456789",
            deviceName: nil
        )

        _ = await makeClient(transport).exchangeCode(request)

        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else { return XCTFail("the body is not a JSON object") }
        XCTAssertEqual(Set(fields.keys), ["code", "codeVerifier", "redirectUri", "deviceId", "platform"])
        XCTAssertNil(body["deviceName"])
    }

    /// ⚠️ ONE KEY, AND THE REFRESH TOKEN NEVER TRAVELS IN THE URL — a query
    /// parameter would reach logs, proxies and the browser history of anything
    /// that ever opened it.
    func testTheRefreshBodyCarriesTheTokenAndNothingElse() async throws {
        let transport = TestTransport(json: Fixture.tokenBody)

        _ = await makeClient(transport).refresh(refreshToken: "rt-opaque")

        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else { return XCTFail("the body is not a JSON object") }
        XCTAssertEqual(Set(fields.keys), ["refreshToken"])
        XCTAssertEqual(body["refreshToken"]?.stringValue, "rt-opaque")
        XCTAssertEqual(transport.lastRequest?.url.query, nil)
    }

    // ── The state of the seam ────────────────────────────────────────────────

    /// ⛔ REDIRECTS ARE FOLLOWED HERE, WHICH IS THE DEFAULT EVERYWHERE EXCEPT THE
    /// RECORDING ROUTE. `ApiClient.redirectTarget(_:)` passes `false` for
    /// `calls/{id}/recording` and nothing else; a credential exchange that
    /// silently stopped at a 308 would report `transportFailure` and read as an
    /// outage. The flag is asserted rather than assumed because it is invisible
    /// in the URL and in the response.
    func testBothRoutesPostJsonAndFollowRedirects() async {
        for (label, send) in Self.senders {
            let transport = TestTransport(json: Fixture.tokenBody)
            await send(makeClient(transport))

            XCTAssertEqual(transport.lastRequest?.method, .post, label)
            XCTAssertEqual(
                transport.lastRequest?.headers["Content-Type"],
                "application/json; charset=utf-8",
                label
            )
            XCTAssertEqual(transport.lastRequest?.headers["Accept"], "application/json", label)
            XCTAssertEqual(transport.lastFollowedRedirects, true, label)
            // ⛔ NO BEARER. Acquiring one is what these two calls are FOR.
            XCTAssertNil(transport.lastRequest?.headers["Authorization"], label)
            XCTAssertEqual(transport.recorded.count, 1, label)
        }
    }

    /// ⚠️ THE THREE ROUTES ARE SIBLINGS UNDER THE PUBLIC `/api/auth/native/`
    /// PREFIX, not under `/api/district/`. All would 404 under the district
    /// namespace, and the server's proxy would 401 them before the handler ran.
    ///
    /// ⚠️ AND NONE OF THEM HAS AN `EndpointID`, which is why `EndpointSurfaceTests`'
    /// partition over `EndpointID.allCases` is untouched by the revoke
    /// route. See the ⛔ on ``NativeAuthPaths``.
    func testBothRoutesAddressTheirOwnPath() async {
        XCTAssertEqual(NativeAuthPaths.token, ["api", "auth", "native", "token"])
        XCTAssertEqual(NativeAuthPaths.refresh, ["api", "auth", "native", "refresh"])
        XCTAssertEqual(NativeAuthPaths.revoke, ["api", "auth", "native", "revoke"])

        let exchangeTransport = TestTransport(json: Fixture.tokenBody)
        _ = await makeClient(exchangeTransport).exchangeCode(Fixture.exchange)
        XCTAssertEqual(
            exchangeTransport.lastRequest?.url.absoluteString,
            "https://auth.example.test/api/auth/native/token"
        )

        let refreshTransport = TestTransport(json: Fixture.tokenBody)
        _ = await makeClient(refreshTransport).refresh(refreshToken: "rt-opaque")
        XCTAssertEqual(
            refreshTransport.lastRequest?.url.absoluteString,
            "https://auth.example.test/api/auth/native/refresh"
        )
    }

    /// ⚠️ A BASE URL WITH A TRAILING SLASH MUST NOT DOUBLE UP. The production
    /// constant carries none, but a configured value could — and
    /// `//api/auth/native/token` addresses a different path.
    func testATrailingSlashOnTheBaseUrlIsAbsorbed() async {
        let transport = TestTransport(json: Fixture.tokenBody)

        _ = await makeClient(transport, base: "https://auth.example.test/").refresh(refreshToken: "rt")

        XCTAssertEqual(
            transport.lastRequest?.url.absoluteString,
            "https://auth.example.test/api/auth/native/refresh"
        )
    }

    /// ⚠️ THE DEFAULT IS PRODUCTION, and it is the same one host `ApiClient`
    /// uses. Cloudflare routes a request to the right origin, so there is no
    /// per-region variant to pick here either.
    func testTheDefaultBaseUrlIsTheProductionHost() async {
        let transport = TestTransport(json: Fixture.tokenBody)
        let client = TestNativeAuthClient(transport: transport)

        _ = await client.refresh(refreshToken: "rt")

        XCTAssertEqual(
            transport.lastRequest?.url.absoluteString,
            "https://www.distronode.com/api/auth/native/refresh"
        )
    }

    /// The two calls, so the seam assertions above run against both without
    /// being written twice.
    private static let senders: [(String, @Sendable (TestNativeAuthClient) async -> Void)] = [
        ("exchange", { _ = await $0.exchangeCode(Fixture.exchange) }),
        ("refresh", { _ = await $0.refresh(refreshToken: "rt-opaque") }),
    ]
}
