@testable import DistrictAI
import DistrictData
import DistrictNetwork
import Foundation
import XCTest

/// A transport for the scheduling admin RPC that answers a queued list and keeps
/// every request.
///
/// ⛔ ITS OWN TYPE RATHER THAN `SettingsTransport`, FOR ONE REASON THAT MATTERS:
/// that helper applies ONE status to every queued body, and half of what is under
/// test here is the difference between a **200** carrying `{ok:false}` (the
/// scheduler refused) and a real 403 (our route refused). A harness that cannot
/// express both cannot tell the two failures apart, which is exactly the
/// distinction `SchedulingAdminError` exists to preserve.
///
/// ⛔ AND IT DECODES THE SENT BODY INTO `op` AND `params`, BECAUSE THAT IS THE
/// ASSERTION. Every op crosses the wire as a STRING inside one descriptor, so
/// "did this sheet send `apiKeys.create` with `{name}`" is a question about the
/// encoded document and nothing typed can answer it. `JSONValue.object(_:)` drops
/// a nil pair silently by design, so an absent key is only visible in the bytes.
final class SchedulingWritesCTransport: HTTPTransport, @unchecked Sendable {
    struct Answer {
        let status: Int
        let body: String
    }

    /// One decoded request, as the assertions read it.
    struct Sent {
        let workspaceId: String
        let op: String
        let params: [String: Any]

        func string(_ key: String) -> String? {
            params[key] as? String
        }

        func strings(_ key: String) -> [String]? {
            params[key] as? [String]
        }

        func objects(_ key: String) -> [[String: Any]]? {
            params[key] as? [[String: Any]]
        }
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var requests: [HTTPRequest] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    // MARK: - Recording

    var bodies: [String] {
        lock.withLock { requests }.compactMap(\.body).compactMap { String(data: $0, encoding: .utf8) }
    }

    /// Every admin-RPC call this transport saw, decoded.
    ///
    /// ⚠️ SKIPS ANYTHING THAT IS NOT THAT SHAPE, so a test may queue a non-RPC leg
    /// (the SSO 302) beside the ops without the decoder throwing on it.
    var calls: [Sent] {
        bodies.compactMap { body in
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workspaceId = object["workspaceId"] as? String,
                  let op = object["op"] as? String
            else {
                return nil
            }
            return Sent(
                workspaceId: workspaceId,
                op: op,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    var ops: [String] {
        calls.map(\.op)
    }

    /// ⚠️ A QUEUE THAT HAS RUN DRY ANSWERS 500 rather than hanging or crashing, so
    /// a test that drives one request too many fails on an assertion about
    /// behaviour instead of on a fatal error somewhere in the client.
    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let next: Answer? = lock.withLock {
            requests.append(request)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        guard let next else {
            return HTTPResponse(statusCode: 500, headers: [:], body: nil)
        }
        return HTTPResponse(
            statusCode: next.status,
            headers: ["Content-Type": "application/json"],
            body: Data(next.body.utf8)
        )
    }
}

/// The canned answers, hung off ``SchedulingWritesCTransport/Answer`` rather than off
/// the transport.
///
/// ⛔ THE NESTING IS WHAT MAKES `[.ok(…)]` COMPILE, AND IT IS NOT A STYLE CHOICE.
/// Every call site writes the answers as an array literal, so Swift resolves `.ok`
/// as an implicit member of the ELEMENT type — `Answer` — and a static declared one
/// level up on the transport class is not a member of it. Declared there, all
/// thirteen `.ok(…)` and four `.refusal(…)` sites fail to compile with
/// "type 'Answer' has no member 'ok'", and the errors land on the call sites rather
/// than on the declaration.
extension SchedulingWritesCTransport.Answer {
    /// A successful op: HTTP 200, `{"ok":true,"data":<json>}`.
    static func ok(_ json: String) -> Self {
        Self(status: 200, body: #"{"ok":true,"data":\#(json)}"#)
    }

    /// ⛔ THE SIXTEEN NO-CONTENT OPS ANSWER AN OBJECT, NOT AN EMPTY BODY. The
    /// catalog rewrites a 204 into `{"ok":true}` before it reaches this client, so
    /// the wire carries an outer flag and an inner one that mean different things.
    static var noContent: Self {
        ok(#"{"ok":true}"#)
    }

    /// ⛔ A SCHEDULER REFUSAL IS HTTP **200**. `failureResponse` answers
    /// `{ok:false, failure, status}` at 200 on purpose: the request reached us, was
    /// authorised, cleared the role bar and validated, and the far end refused.
    static func refusal(_ failure: String, schedulerStatus: Int = 503) -> Self {
        Self(status: 200, body: #"{"ok":false,"failure":"\#(failure)","status":\#(schedulerStatus)}"#)
    }

    /// Our own route declining before it spent a request.
    static func refused(status: Int, error: String = "") -> Self {
        Self(status: status, body: #"{"error":"\#(error)"}"#)
    }
}

extension SchedulingAdminRepository {
    /// ⛔ `reportUnknownOp` IS SILENCED, DELIBERATELY. The app's reporter is an
    /// `assertionFailure`, which in a debug test run is a trap rather than a
    /// failure — so a test that ever exercised a `400 unknown_op` would abort the
    /// whole bundle instead of reporting one red case.
    static func writesCTest(_ transport: SchedulingWritesCTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(
            client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            ),
            reportUnknownOp: { _ in }
        )
    }
}

/// Rows built from BYTES rather than from an initialiser.
///
/// ⛔ NOT A CHOICE OF STYLE: the DTOs in `DistrictModel` declare `public let`
/// properties and no public initialiser, so their memberwise one is `internal` to
/// that module and unreachable from the app's test bundle. Decoding is the only
/// way to make one — and it is the better way anyway, because it is the server's
/// shape rather than a Swift value that happens to have the same fields.
///
/// ⚠️ `throws` RATHER THAN `try!`. `force_try` is a default SwiftLint rule and
/// `--strict` promotes it to an error; an `XCTestCase` method may simply be
/// `throws`, and a malformed fixture then reports as a failed test instead of
/// trapping the whole bundle.
enum SchedulingWritesCRows {
    static func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static let apiKey = #"{"id":"key_1","name":"Zapier","created_at":null,"last_used_at":null}"#

    static let oauthConnection = #"""
    {"id":"conn_1","client_name":"Raycast","created_at":null,"last_used_at":null,"expires_at":null}
    """#

    static let webhook = #"""
    {"id":"wh_1","url":"https://example.com/hooks","events":["booking.created"],
     "fields":["id","status"],"is_active":true,"created_at":null}
    """#

    /// ⚠️ CARRIES AN EVENT NAME THIS BUILD DOES NOT KNOW, which is legitimate on
    /// the response side: `SchedulingWebhook.events` is `[String]` precisely so a
    /// row created before a rename does not take out the whole tab.
    static let webhookWithUnknownEvent = #"""
    {"id":"wh_2","url":"https://example.com/two","events":["booking.created","booking.moved"],
     "fields":null,"is_active":true,"created_at":null}
    """#

    static let calendarConnection = #"""
    {"id":"cal_1","provider":"google","account_email":"host@example.com",
     "is_destination":true,"check_conflicts":true}
    """#

    /// ⛔ ROW 1 IS THE READ-ONLY HOLIDAY CALENDAR WITH ONLY `id` AND `name`. Its
    /// four flags are ABSENT rather than false, and a client that sent them back as
    /// false would be inventing a statement the fork never made.
    static let calendars = #"""
    {"calendars":[{"id":"holidays","name":"Holidays"},
      {"id":"work","name":"Work","primary":true,"writable":true,
       "check_conflicts":false,"is_destination":false}]}
    """#
}

/// The harness's own two promises, because every other file in this group leans on
/// them.
final class SchedulingWritesCSupportTests: XCTestCase {
    func test_IOS_SCHW_C00_theHarnessDecodesTheOpAndParamsOutOfTheSentBody() async {
        let transport = SchedulingWritesCTransport([.ok(#"{"id":"k1","name":"Zapier","key":"sk_live"}"#)])
        _ = try? await SchedulingAdminRepository.writesCTest(transport)
            .createAPIKey(workspaceId: "ws_1", name: "Zapier")

        XCTAssertEqual(transport.ops, ["apiKeys.create"])
        XCTAssertEqual(transport.calls.first?.workspaceId, "ws_1")
        XCTAssertEqual(transport.calls.first?.string("name"), "Zapier")
    }

    /// ⚠️ AN EXHAUSTED QUEUE MUST FAIL RATHER THAN HANG. A model that sends two
    /// requests where a test queued one should red on the assertion it was written
    /// for, not time out.
    func test_IOS_SCHW_C01_anExhaustedQueueAnswersAFailureRatherThanHanging() async {
        let transport = SchedulingWritesCTransport([])
        do {
            _ = try await SchedulingAdminRepository.writesCTest(transport)
                .deleteAPIKey(workspaceId: "ws_1", keyId: "k1")
            XCTFail("an empty queue must not resolve as a successful op")
        } catch {
            XCTAssertEqual(error as? SchedulingAdminError, .unavailable)
        }
    }
}
