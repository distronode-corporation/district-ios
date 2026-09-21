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

    private func mint(status: Int, body: String) async -> Result<SchedulingHandoff, ApiError> {
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
        guard case let .failure(.http(status, _)) = result else { return XCTFail("expected .http, got \(result)") }
        XCTAssertEqual(status, 401)
    }

    func test_IOS_SCH_08_aBearerThatDoesNotVerifyIsForbidden() async {
        let result = await mint(status: 403, body: #"{"error":"Forbidden"}"#)
        guard case let .failure(.http(status, _)) = result else { return XCTFail("expected .http, got \(result)") }
        XCTAssertEqual(status, 403)
    }

    func test_IOS_SCH_09_rateLimitAndContractStatusesSurvive() async {
        for expected in [429, 400] {
            let result = await mint(status: expected, body: #"{"error":"nope"}"#)
            guard case let .failure(.http(status, _)) = result else { return XCTFail("expected .http") }
            XCTAssertEqual(status, expected)
        }
    }

    // MARK: - The guards

    func test_IOS_SCH_10_aNonHttpsAddressIsRefused() async {
        let result = await mint(status: 200, body: #"{"url":"http://\#(Self.host)/x","expiresIn":60}"#)
        guard case .failure(.decoding) = result else { return XCTFail("http:// must be refused, got \(result)") }
    }

    /// ⛔ THE ONE THAT MATTERS MOST. A valid https URL on somebody else's host is
    /// exactly what an influenced response body would carry.
    func test_IOS_SCH_11_aForeignHostIsRefusedEvenOverHttps() async {
        let result = await mint(status: 200, body: #"{"url":"https://evil.example.com/x","expiresIn":60}"#)
        guard case .failure(.decoding) = result else { return XCTFail("a foreign host must be refused, got \(result)") }
    }

    // MARK: - Strict decoding

    func test_IOS_SCH_12_anExtraKeyIsAContractFailureRatherThanIgnored() async {
        let result = await mint(
            status: 200,
            body: #"{"url":"https://\#(Self.host)/x","expiresIn":60,"surprise":1}"#
        )
        guard case .failure(.decoding) = result else { return XCTFail("an unknown key must fail, got \(result)") }
    }

    func test_IOS_SCH_13_aMissingKeyFails() async {
        let result = await mint(status: 200, body: #"{"url":"https://\#(Self.host)/x"}"#)
        guard case .failure(.decoding) = result else { return XCTFail("a missing key must fail, got \(result)") }
    }

    func test_IOS_SCH_14_aWrongTypeFails() async {
        let result = await mint(
            status: 200,
            body: #"{"url":"https://\#(Self.host)/x","expiresIn":"soon"}"#
        )
        guard case .failure(.decoding) = result else { return XCTFail("a string expiresIn must fail, got \(result)") }
    }

    /// ⚠️ `send` HANDS BACK ANY 2xx BODY, so a 200 whose body is not an object at all
    /// reaches this decoder and must be refused here.
    func test_IOS_SCH_15_aBodyThatIsNotAnObjectFails() async {
        for body in ["[]", #""https://www.distronode.com/x""#, "not json"] {
            let result = await mint(status: 200, body: body)
            guard case let .failure(.decoding(reason)) = result else {
                return XCTFail("a non-object body must fail, got \(result) for \(body)")
            }
            XCTAssertEqual(reason, "The hand-off response was not a JSON object.")
        }
    }

    /// An empty string is a `url` Foundation will not make a URL from, on Darwin and on
    /// Linux, and it must be a refusal rather than a crash further on.
    func test_IOS_SCH_16_anAddressFoundationCannotParseFails() async {
        let result = await mint(status: 200, body: #"{"url":"","expiresIn":60}"#)
        guard case let .failure(.decoding(reason)) = result else {
            return XCTFail("an empty url must fail, got \(result)")
        }
        XCTAssertEqual(reason, "The hand-off address was not a URL.")
    }
}
