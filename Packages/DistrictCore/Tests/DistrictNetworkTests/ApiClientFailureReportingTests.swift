import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// What ``ApiClient`` reports about a failure: the refused bearer on a 401, and
/// the key path of a body that did not decode.
///
/// ⚠️ ITS OWN CLASS BECAUSE `ApiClientTests` IS AT SWIFTLINT'S `type_body_length`.
final class ApiClientFailureReportingTests: XCTestCase {
    // MARK: - A 401 is reported, never resent

    /// ⛔ THE SERVER REFUSED THIS BEARER, SO ITS ISSUER IS TOLD WHICH ONE. Without
    /// the report the coordinator keeps handing the dead token out for the rest of
    /// its TTL and every screen reads "your session has ended".
    func testA401ReportsTheExactBearerAndIsNotResent() async throws {
        let transport = TestTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let rejected = RejectedTokens()
        let client = try ApiClient(
            baseURL: XCTUnwrap(URL(string: EndpointTable.host)),
            transport: transport,
            accessToken: { "session-token" },
            rejectedToken: { await rejected.record($0) }
        )

        let result = await client.send(DistrictEndpoints.hqConfirm(
            workspaceId: "ws_1",
            tool: "delete_contact",
            args: .object(["id": .string("c_1")])
        ))

        XCTAssertEqual(result.failureOnly?.httpStatus, 401)
        XCTAssertEqual(transport.recorded.count, 1, "a 401 is never resent: this route deletes")
        let tokens = await rejected.tokens
        XCTAssertEqual(tokens, ["session-token"])
    }

    /// ⚠️ ONLY A 401. A 403 is "authenticated but not permitted", which a fresh
    /// token cannot fix, and a missing credential never reached the server.
    func testOtherFailuresAndALocal401ReportNothing() async throws {
        let rejected = RejectedTokens()
        for (status, token) in [(403, "session-token"), (500, "session-token"), (200, nil)] as [(Int, String?)] {
            let client = try ApiClient(
                baseURL: XCTUnwrap(URL(string: EndpointTable.host)),
                transport: TestTransport(json: "{}", status: status),
                accessToken: { token },
                rejectedToken: { await rejected.record($0) }
            )
            _ = await client.send(DistrictEndpoints.overview(workspaceId: "ws_1"))
        }

        let tokens = await rejected.tokens
        XCTAssertEqual(tokens, [])
    }

    // MARK: - A decode failure names the field, never its value

    func testADecodeFailureNamesTheKeyPath() async {
        let json = #"{"items":[{"name":"a"},{"nam":"b"}],"hosts":{}}"#
        let client = ApiClient.test(TestTransport(json: json))

        let result = await client.send(DistrictEndpoints.overview(workspaceId: "ws_1"), as: KeyPathProbe.self)

        XCTAssertEqual(
            result.failureOnly?.message,
            ApiErrorNormalizer.decodingReason(statusCode: 200, byteCount: json.utf8.count) + " Field: items[1].name."
        )
    }

    /// ⛔ A DICTIONARY KEY IS DATA, so it is masked rather than written out.
    func testADictionaryKeyOnThePathIsMasked() async {
        let transport = TestTransport(json: #"{"items":[],"hosts":{"usr_private":{"name":7}}}"#)
        let client = ApiClient.test(transport)

        let result = await client.send(DistrictEndpoints.overview(workspaceId: "ws_1"), as: KeyPathProbe.self)

        let message = result.failureOnly?.message ?? ""
        XCTAssertTrue(message.hasSuffix(" Field: hosts.*.name."), message)
        XCTAssertFalse(message.contains("usr_private"))
    }

    /// ⚠️ A ROOT-LEVEL FAILURE HAS NO PATH, and the sentence is then exactly the
    /// one it always was.
    func testARootLevelFailureAddsNoPath() async {
        let client = ApiClient.test(TestTransport(json: "[]"))

        let result = await client.send(DistrictEndpoints.overview(workspaceId: "ws_1"), as: KeyPathProbe.self)

        XCTAssertEqual(result.failureOnly, .decoding(ApiErrorNormalizer.decodingReason(statusCode: 200, byteCount: 2)))
    }

    func testEveryDecodingErrorShapeYieldsItsPath() {
        let context = DecodingError.Context(codingPath: [KeyPathProbe.CodingKeys.items], debugDescription: "")
        XCTAssertEqual(ApiErrorNormalizer.keyPath(of: DecodingError.dataCorrupted(context)), "items")
        XCTAssertEqual(ApiErrorNormalizer.keyPath(of: DecodingError.valueNotFound(String.self, context)), "items")
        XCTAssertEqual(ApiErrorNormalizer.keyPath(of: DecodingError.typeMismatch(String.self, context)), "items")
        XCTAssertEqual(
            ApiErrorNormalizer.keyPath(of: DecodingError.keyNotFound(KeyPathProbe.CodingKeys.hosts, context)),
            "items.hosts"
        )
        XCTAssertEqual(ApiErrorNormalizer.keyPath(of: TransportStub.offline), "")
    }
}

/// A DTO shaped to put an array index and a dictionary key on a failing path.
private struct KeyPathProbe: Decodable, Sendable {
    struct Entry: Decodable {
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case items
        case hosts
    }

    let items: [Entry]
    let hosts: [String: Entry]
}

private actor RejectedTokens {
    private(set) var tokens: [String] = []

    func record(_ token: String) {
        tokens.append(token)
    }
}
