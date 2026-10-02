@testable import DistrictModel
@testable import DistrictNetwork
import XCTest

/// ⛔ THE URL IN THIS RESPONSE GOES STRAIGHT TO A BROWSER, so the guards below are
/// the security surface rather than tidiness: an influenced body that got past them
/// would redirect a signed-in operator wherever it liked.
final class SchedulingHandoffClientTests: XCTestCase {
    private static let host = "www.distronode.com"

    private func client(status: Int, body: String) -> SchedulingHandoffClient {
        let transport = TestTransport(json: body, status: status)
        return SchedulingHandoffClient(
            client: ApiClient(
                baseURL: URL(string: "https://\(Self.host)")!,
                transport: transport,
                accessToken: { "bearer-for-tests" }
            )
        )
    }

    private func mint(status: Int, body: String) async -> Result<SchedulingHandoff, SchedulingHandoffFailure> {
        await client(status: status, body: body).mint(workspaceId: "ws-1")
    }

    // MARK: - The happy path

    func test_IOS_SCH_06_aWellFormedResponseDecodes() async {
        let result = await mint(
            status: 200,
            body: #"{"url":"https://\#(Self.host)/dashboard/handoff?c=abc","expiresIn":60}"#
        )
        guard case let .success(handoff) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(handoff.expiresIn, 60)
        XCTAssertEqual(handoff.url.host, Self.host)
    }

    // MARK: - Status mapping, probed on production rather than read off a doc

    /// ⛔ 401 IS "NO BEARER SENT" AND 403 IS "A BEARER THAT DOES NOT VERIFY". They are
    /// different remedies — sign in again versus you may not do this — and the route
    /// really does answer both, so both are pinned.
    func test_IOS_SCH_07_noBearerIsAnUnauthorized() async {
        let result = await mint(status: 401, body: #"{"error":"Unauthorized"}"#)
        guard case let .failure(.api(.http(status, _))) = result
        else { return XCTFail("expected .http, got \(result)") }
        XCTAssertEqual(status, 401)
    }

    func test_IOS_SCH_08_aBearerThatDoesNotVerifyIsForbidden() async {
        let result = await mint(status: 403, body: #"{"error":"Forbidden"}"#)
        guard case let .failure(.api(.http(status, _))) = result
        else { return XCTFail("expected .http, got \(result)") }
        XCTAssertEqual(status, 403)
    }

    func test_IOS_SCH_09_rateLimitAndContractStatusesSurvive() async {
        for expected in [429, 400] {
            let result = await mint(status: expected, body: #"{"error":"nope"}"#)
            guard case let .failure(.api(.http(status, _))) = result else { return XCTFail("expected .http") }
            XCTAssertEqual(status, expected)
        }
    }

    // MARK: - The guards

    func test_IOS_SCH_10_aNonHttpsAddressIsRefused() async {
        let result = await mint(status: 200, body: #"{"url":"http://\#(Self.host)/x","expiresIn":60}"#)
        guard case .failure(.api(.decoding)) = result else { return XCTFail("http:// must be refused, got \(result)") }
    }

    /// ⛔ THE ONE THAT MATTERS MOST. A valid https URL on somebody else's host is
    /// exactly what an influenced response body would carry.
    func test_IOS_SCH_11_aForeignHostIsRefusedEvenOverHttps() async {
        let result = await mint(status: 200, body: #"{"url":"https://evil.example.com/x","expiresIn":60}"#)
        guard case .failure(.api(.decoding)) = result else {
            return XCTFail("a foreign host must be refused, got \(result)")
        }
    }

    // MARK: - Strict decoding

    func test_IOS_SCH_12_anExtraKeyIsAContractFailureRatherThanIgnored() async {
        let result = await mint(
            status: 200,
            body: #"{"url":"https://\#(Self.host)/x","expiresIn":60,"surprise":1}"#
        )
        guard case .failure(.api(.decoding)) = result else { return XCTFail("an unknown key must fail, got \(result)") }
    }

    func test_IOS_SCH_13_aMissingKeyFails() async {
        let result = await mint(status: 200, body: #"{"url":"https://\#(Self.host)/x"}"#)
        guard case .failure(.api(.decoding)) = result else { return XCTFail("a missing key must fail, got \(result)") }
    }

    func test_IOS_SCH_14_aWrongTypeFails() async {
        let result = await mint(
            status: 200,
            body: #"{"url":"https://\#(Self.host)/x","expiresIn":"soon"}"#
        )
        guard case .failure(.api(.decoding)) = result
        else { return XCTFail("a string expiresIn must fail, got \(result)") }
    }

    /// ⚠️ `send` HANDS BACK ANY 2xx BODY, so a 200 whose body is not an object at all
    /// reaches this decoder and must be refused here.
    func test_IOS_SCH_15_aBodyThatIsNotAnObjectFails() async {
        for body in ["[]", #""https://www.distronode.com/x""#, "not json"] {
            let result = await mint(status: 200, body: body)
            guard case let .failure(.api(.decoding(reason))) = result else {
                return XCTFail("a non-object body must fail, got \(result) for \(body)")
            }
            XCTAssertEqual(reason, "The hand-off response was not a JSON object.")
        }
    }

    /// An empty string is a `url` Foundation will not make a URL from, on Darwin and on
    /// Linux, and it must be a refusal rather than a crash further on.
    func test_IOS_SCH_16_anAddressFoundationCannotParseFails() async {
        let result = await mint(status: 200, body: #"{"url":"","expiresIn":60}"#)
        guard case let .failure(.api(.decoding(reason))) = result else {
            return XCTFail("an empty url must fail, got \(result)")
        }
        XCTAssertEqual(reason, "The hand-off address was not a URL.")
    }

    // MARK: - The nonce (S33)

    private static let nonce = String(repeating: "n", count: 43)
    private static let minted = #"{"url":"https://www.distronode.com/dashboard/handoff?code=c","expiresIn":60}"#

    private func body(of transport: TestTransport) throws -> [String: JSONValue] {
        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else {
            XCTFail("the mint body must be an object, got \(body)")
            return [:]
        }
        return fields
    }

    /// ⛔ THE BOUND PATH SENDS THE NONCE IT WAS GIVEN, VERBATIM, beside the two keys it
    /// always sent. The response is decoded by the same strict two-key rule.
    func test_IOS_SCH_17_theBoundMintSendsTheNonce() async throws {
        let transport = TestTransport(json: Self.minted)
        let client = SchedulingHandoffClient(client: .test(transport))
        let result = await client.mint(workspaceId: "ws_1", next: "/dashboard/district/scheduling", nonce: Self.nonce)

        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        let sent = try body(of: transport)
        XCTAssertEqual(sent["nonce"], .string(Self.nonce))
        XCTAssertEqual(sent["workspaceId"], .string("ws_1"))
        XCTAssertEqual(sent["next"], .string("/dashboard/district/scheduling"))
        XCTAssertEqual(Set(sent.keys), ["workspaceId", "next", "nonce"])
    }

    /// ⛔ THE BOUND REQUEST, BYTE FOR BYTE: the route, the bearer, the content type and
    /// the exact body the server's zod schema parses. Keys are sorted
    /// (``JSONWire/encode(_:)``) and `/` is escaped, which JSON allows and the route reads
    /// as the same string. A body that only decoded to the right keys could still carry
    /// the nonce under another spelling or type.
    func test_IOS_SCH_28_theBoundRequestIsPinnedByteForByte() async throws {
        let transport = TestTransport(json: Self.minted)
        let client = SchedulingHandoffClient(client: .test(transport))
        _ = await client.mint(workspaceId: "ws_1", next: "/dashboard/district/scheduling", nonce: Self.nonce)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.absoluteString, "\(EndpointTable.host)/api/district/scheduling/handoff")
        XCTAssertEqual(request.headers["Authorization"], "Bearer session-token")
        XCTAssertEqual(request.headers["Content-Type"], "application/json; charset=utf-8")
        let raw = try XCTUnwrap(request.body)
        XCTAssertEqual(
            String(bytes: raw, encoding: .utf8),
            #"{"next":"\/dashboard\/district\/scheduling","nonce":"\#(Self.nonce)","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ THE UNBOUND PATH SENDS NO `nonce` KEY AT ALL: not null, not empty. That body is
    /// byte for byte what every installed build sends today.
    func test_IOS_SCH_18_theUnboundMintSendsNoNonceKey() async throws {
        let transport = TestTransport(json: Self.minted)
        let client = SchedulingHandoffClient(client: .test(transport))
        _ = await client.mint(workspaceId: "ws_1")

        let raw = try XCTUnwrap(transport.lastRequest?.body)
        XCTAssertEqual(String(bytes: raw, encoding: .utf8), #"{"workspaceId":"ws_1"}"#)
        XCTAssertFalse(try body(of: transport).keys.contains("nonce"))
    }

    /// ⛔ `nonce_required` CARRIES THE SENTENCE THE USER SEES, copied from the spec's
    /// body, key order included.
    func test_IOS_SCH_19_nonceRequiredCarriesItsSentence() async {
        let result = await mint(
            status: 400,
            body: #"{"error":"Update the app to open the website from it.","code":"nonce_required"}"#
        )
        XCTAssertEqual(result, .failure(.nonceRequired(message: "Update the app to open the website from it.")))
    }

    func test_IOS_SCH_20_nonceRequiredWithNoSentenceIsStillThatRefusal() async {
        let result = await mint(status: 400, body: #"{"code":"nonce_required"}"#)
        XCTAssertEqual(result, .failure(.nonceRequired(message: nil)))
    }

    func test_IOS_SCH_21_invalidNonceIsItsOwnFailure() async {
        let result = await mint(status: 400, body: #"{"error":"nonce is malformed","code":"invalid_nonce"}"#)
        XCTAssertEqual(result, .failure(.invalidNonce))
    }

    /// ⚠️ THE CODES MEAN SOMETHING ONLY ON A 400. The same code on another status, or
    /// another code on a 400, keeps the ordinary mapping and its sentence.
    func test_IOS_SCH_22_theNonceCodesAreReadOnlyOnA400() async {
        let other = await mint(status: 409, body: #"{"error":"Not ready","code":"nonce_required"}"#)
        XCTAssertEqual(other, .failure(.api(.http(status: 409, message: "Not ready"))))
        let invalidElsewhere = await mint(status: 403, body: #"{"error":"No","code":"invalid_nonce"}"#)
        XCTAssertEqual(invalidElsewhere, .failure(.api(.http(status: 403, message: "No"))))
        let unknown = await mint(status: 400, body: #"{"error":"Bad","code":"something_else"}"#)
        XCTAssertEqual(unknown, .failure(.api(.http(status: 400, message: "Bad"))))
    }

    func test_IOS_SCH_23_aTransportFailureIsAnApiFailure() async {
        let client = SchedulingHandoffClient(client: .test(TestTransport(throwing: TransportStub.offline)))
        let result = await client.mint(workspaceId: "ws_1")
        guard case .failure(.api(.transport)) = result else { return XCTFail("expected .transport, got \(result)") }
    }

    /// ⛔ LEG 1 IS A PAGE ON THE API'S OWN HOST, so the host-only nonce cookie lands
    /// where leg 3 redeems. The state travels unescaped because it is unreserved.
    func test_IOS_SCH_24_theStartURLIsOnTheApiHost() throws {
        let client = SchedulingHandoffClient(client: .test(TestTransport([])))
        let url = try XCTUnwrap(client.startURL(state: "abc_DEF-123.456~xyz"))
        XCTAssertEqual(url.absoluteString, "\(EndpointTable.host)/dashboard/handoff/start?state=abc_DEF-123.456~xyz")
    }
}
