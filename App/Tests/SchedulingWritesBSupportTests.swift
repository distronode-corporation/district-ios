@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The fixtures and the request reader the bookings, team, settings and recordings
/// write tests share.
///
/// ⛔ IT ASSERTS ON THE ENCODED BODY, NOT ON ARGUMENTS, AND THAT IS THE WHOLE POINT
/// OF THE SURFACE. `JSONValue.object(_:)` DROPS a nil pair silently by design, so
/// "was the reason omitted rather than sent empty", "did the add really leave
/// `routing_priority` out" and "is the member id spelled `userId` on this op and
/// `user_id` on that one" are all questions about bytes. An assertion on what a
/// model was handed cannot answer any of them.
///
/// ⚠️ NAMED `…SupportTests.swift` TO MATCH ITS SIBLINGS' FILE PATTERN even though it
/// holds no test case. The target globs `App/Tests` by directory, so the name is
/// for the reader rather than for the build.
enum SchedulingWritesBFixtures {
    static let workspaceId = "ws-1"

    static func repository(_ transport: SettingsTransport) -> SchedulingAdminRepository {
        // ⛔ `reportUnknownOp` IS OVERRIDDEN TO A NO-OP. Its default traps in a debug
        // build, and a test bundle IS a debug build — so a test that ever drove an
        // `unknown_op` through the default would crash the runner rather than fail.
        SchedulingAdminRepository(client: client(transport), reportUnknownOp: { _ in })
    }

    static func media(_ transport: SettingsTransport) -> SchedulingAdminMediaRepository {
        SchedulingAdminMediaRepository(client: client(transport))
    }

    private static func client(_ transport: SettingsTransport) -> ApiClient {
        ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" },
            // ⚠️ A FIXED BOUNDARY so a multipart assertion reads the same on every
            // run. `ApiClient` exposes it for exactly this.
            boundary: { "test-boundary" }
        )
    }

    // MARK: - Envelopes

    static func ok(_ data: String) -> String {
        "{\"ok\":true,\"data\":\(data)}"
    }

    /// ⛔ HTTP **200** CARRYING `{ok:false}`. That is what a scheduler refusal looks
    /// like on this route: the request reached Distronode, cleared auth, cleared the
    /// role bar, validated, and the far end said no. A test that used a 5xx here
    /// would be exercising a different arm of the mapping entirely.
    static func refusal(_ failure: String) -> String {
        "{\"ok\":false,\"failure\":\"\(failure)\",\"status\":503}"
    }

    /// ⛔ THE FIVE NO-CONTENT OPS ANSWER AN OBJECT INSIDE `data`, NOT A BARE
    /// ENVELOPE. The catalog rewrites a 204 into `{"ok":true}` and the route then
    /// wraps THAT as the `data` payload, so the wire carries an outer flag and an
    /// inner one that mean different things — and every op here decodes
    /// ``SchedulingNoContent`` out of the inner one. A bare `{"ok":true}` parses as
    /// a success envelope with no `data` and throws on decode, which surfaces as the
    /// write having silently failed rather than as a malformed fixture.
    static let noContent = ok("{\"ok\":true}")

    // MARK: - Rows

    static func booking(id: String = "bk-1", status: String = "confirmed") -> String {
        """
        {"id":"\(id)","start_at":"2026-09-20T15:00:00Z","end_at":"2026-09-20T15:30:00Z",
        "status":"\(status)","event_type_slug":"intro","host_id":"u-1"}
        """
    }

    static func user(id: String, name: String = "Ada", archived: Bool = false) -> String {
        """
        {"id":"\(id)","email":"\(id)@example.com","name":"\(name)","is_admin":false,
        "is_owner":false,"role":"member","archived":\(archived)}
        """
    }

    static func team(id: String = "t-1", name: String = "Front desk", members: String = "null") -> String {
        """
        {"id":"\(id)","name":"\(name)","slug":"front-desk","member_count":1,"members":\(members)}
        """
    }

    static func member(id: String, priority: Int) -> String {
        """
        {"id":"\(id)","name":"Ada","email":"\(id)@example.com","routing_priority":\(priority),
        "archived":false}
        """
    }

    static let me = """
    {"id":"u-1","email":"ada@example.com","name":"Ada","timezone":"Europe/Tallinn",
    "time_format":"24h","week_start":1,"date_format":"dmy","is_admin":true,"is_owner":false,
    "role":"admin","notify_confirmation":true,"notify_cancellation":true,
    "notify_reschedule":true,"notify_reminder":false,"notify_host_booking":true,
    "notify_host_cancel":false,"notify_host_reschedule":true,"avatar_url":"https://x/a.png"}
    """

    static let branding = """
    {"business_name":"Acme","logo_url":"https://x/l.png","logo_height":32,"logo_opacity":100,
    "banner_url":"","banner_opacity":60,"privacy_url":"https://acme.test/privacy",
    "terms_url":"","fallback_locale":"en","supported_locales":[{"code":"en","name":"English"}]}
    """

    static func storage(enabled: Bool, ready: Bool) -> String {
        "{\"recordings_enabled\":\(enabled),\"recordings_storage_ready\":\(ready)}"
    }

    static func notetaker(_ enabled: Bool) -> String {
        "{\"enabled\":\(enabled)}"
    }

    static func llm(enabled: Bool, instructions: String) -> String {
        "{\"enabled\":\(enabled),\"extra_instructions\":\"\(instructions)\"}"
    }

    // MARK: - Reading a write's verdict

    /// ⚠️ THE SENTENCE, NOT THE CASE. Every one of these assertions is about what a
    /// person is told, and a test that only checked "it failed" would pass against a
    /// failure explaining the wrong thing.
    static func done(_ state: SchedulingWritesBState) -> String? {
        guard case let .done(message) = state else { return nil }
        return message
    }

    static func failure(_ state: SchedulingWritesBState) -> String? {
        guard case let .failed(text) = state else { return nil }
        return text.message
    }

    // MARK: - Reading what was sent

    /// The `op` of the nth request, or nil if the body is not an RPC call.
    static func op(_ transport: SettingsTransport, _ index: Int = 0) -> String? {
        envelope(transport, index)?["op"] as? String
    }

    static func params(_ transport: SettingsTransport, _ index: Int = 0) -> [String: Any] {
        envelope(transport, index)?["params"] as? [String: Any] ?? [:]
    }

    /// ⚠️ EVERY RPC BODY CARRIES `workspaceId` BESIDE `op` AND `params`, which is
    /// this route's shape rather than the catalog's; the catalog sees only `params`.
    static func envelope(_ transport: SettingsTransport, _ index: Int = 0) -> [String: Any]? {
        let bodies = transport.bodies
        guard index < bodies.count, let data = bodies[index].data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The raw multipart body, as text.
    ///
    /// ⛔ `isoLatin1`, NOT `utf8`, AND THAT IS WHAT MAKES IT TOTAL. A multipart body
    /// carries image bytes, which are not valid UTF-8 — so `String(bytes:encoding:
    /// .utf8)` returns **nil** for a real upload and every assertion would then be
    /// made against `""`, passing or failing for a reason unrelated to the test.
    /// ISO-8859-1 maps all 256 byte values, never fails, and leaves the ASCII part
    /// HEADERS (which are the whole of what these tests read) byte-identical.
    /// ⚠️ `String(decoding:as:)` would also be total, and SwiftLint's
    /// `optional_data_string_conversion` refuses it.
    static func multipart(_ transport: SettingsTransport, _ index: Int = 0) -> String {
        let requests = transport.requests
        guard index < requests.count, let body = requests[index].body else { return "" }
        return String(bytes: body, encoding: .isoLatin1) ?? ""
    }
}
