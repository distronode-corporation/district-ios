import DistrictNetwork
import Foundation
import XCTest

/// The service, answered from its recorded responses, for the screen snapshot tests.
///
/// ⛔ THE BODIES ARE THE SERVICE'S OWN CONTRACT FIXTURES, NOT JSON WRITTEN HERE. They are the
/// files district-core-swift's `ContractFixtureTests` holds every model to, read from the
/// resolved checkout (`SourcePackages/checkouts/district-core-swift/contracts/mobile`), so a
/// screen is drawn from the response the service really sends. A state the fixtures do not
/// record (empty, refused) is a small reply a test states in its own file.
///
/// ⚠️ A REQUEST IS ANSWERED BY PATH. Without an override, `/api/district/contacts/blocked`
/// reads `district-contacts-blocked.json`, which is the fixtures' own naming; an override
/// names the reply for one path. A path with neither answers 404 and is RECORDED, so a test
/// can assert that its screen asked for nothing it did not stub (``unanswered``).
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    /// One answer.
    struct Reply: Sendable {
        let status: Int
        let body: Data

        /// The named fixture file, as recorded.
        static func fixture(_ name: String) -> Reply {
            Reply(status: 200, body: FixtureTransport.fixtureData(name))
        }

        /// A body this test states.
        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    private let lock = NSLock()
    private var overrides: [String: Reply]
    private var inFlightCount = 0
    private(set) var requested: [String] = []
    private(set) var unanswered: [String] = []

    /// - Parameter overrides: keyed by path (`/api/district/contacts`), or by `METHOD path`
    ///   (`POST /api/district/contacts`) when one path answers two methods differently.
    init(_ overrides: [String: Reply] = [:]) {
        self.overrides = overrides
    }

    /// Requests sent and not yet answered.
    var inFlight: Int {
        lock.withLock { inFlightCount }
    }

    /// Every path asked for so far, in order.
    var requestCount: Int {
        lock.withLock { requested.count }
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let path = request.url.path
        let reply: Reply? = lock.withLock {
            inFlightCount += 1
            requested.append("\(request.method.rawValue) \(path)")
            if path == "/api/district/scheduling/admin", let op = Self.op(in: request.body) {
                requested[requested.count - 1] += " \(op)"
                return overrides["op:\(op)"] ?? Self.schedulingOps[op].map(Reply.fixture)
            }
            let flag = Self.historyFlag(request.url)
            return overrides["\(request.method.rawValue) \(path)"] ?? overrides[path + flag]
                ?? overrides[path] ?? Self.paths[path + flag].map(Reply.fixture)
                ?? Self.paths[path].map(Reply.fixture) ?? Self.unrecorded[path].map { Reply.json($0) }
                ?? Self.byName(path)
        }
        // A suspension point, as a real network is, so a screen's loading state is drawn first.
        await Task.yield()
        defer { lock.withLock { inFlightCount -= 1 } }
        guard let reply else {
            lock.withLock { unanswered.append("\(request.method.rawValue) \(path)") }
            return HTTPResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"no fixture for \#(path)"}"#.utf8)
            )
        }
        return HTTPResponse(statusCode: reply.status, headers: ["Content-Type": "application/json"], body: reply.body)
    }

    /// The recorded reply for each path whose fixture is not named after it (the service
    /// records several states of one route, and these are the ordinary ones).
    static let paths: [String: String] = [
        "/api/district/scheduling/status": "district-scheduling-status-ready",
        "/api/district/workspace/persona/voice-studio": "district-voice-studio",
        "/api/district/messages/drafts": "district-drafts-list",
        "/api/district/setup/forwarding-check": "district-forwarding-check",
        // ⚠️ ONE PATH, TWO RESPONSES: the usage history is the same route with `history=true`.
        "/api/district/workspace/usage?history=true": "district-usage-history",
    ]

    /// The routes the service records no fixture for, answered with the model's own shape
    /// (district-core-swift's `CallHandlingResponse`).
    static let unrecorded: [String: String] = [
        "/api/district/workspace/call-handling": #"{"success":true,"callHandling":"ai_then_app","appRingSeconds":20}"#,
    ]

    // MARK: - Scheduling

    /// ⚠️ EVERY SCHEDULING ADMIN CALL POSTS TO ONE PATH and names its operation in the body,
    /// so those are answered by `op` (an override is keyed `op:<name>`). The recorded reply
    /// for each read op the screens send.
    static let schedulingOps: [String: String] = [
        "me.get": "district-scheduling-me",
        "eventTypes.list": "district-scheduling-event-types",
        "eventTypes.get": "district-scheduling-event-type",
        "eventTypes.hosts.get": "district-scheduling-hosts",
        "eventTypes.questions.list": "district-scheduling-questions",
        "eventTypes.slots": "district-scheduling-slots",
        "availability.rules.list": "district-scheduling-rules",
        "availability.overrides.list": "district-scheduling-overrides",
        "bookings.list": "district-scheduling-bookings",
        "bookings.answers": "district-scheduling-booking-answers",
        "calendar.status": "district-scheduling-calendar-status",
        "calendar.connections.calendars.get": "district-scheduling-calendars",
        "zoom.status": "district-scheduling-zoom-status",
        "users.list": "district-scheduling-users",
        "users.upcomingBookings": "district-scheduling-user-upcoming",
        "teams.list": "district-scheduling-teams",
        "teams.get": "district-scheduling-team",
        "settings.branding.get": "district-scheduling-branding",
        "settings.llm.get": "district-scheduling-llm",
        "apiKeys.list": "district-scheduling-api-keys",
        "oauth.connections.list": "district-scheduling-oauth-connections",
        "webhooks.list": "district-scheduling-webhooks",
        "webhooks.deliveries": "district-scheduling-webhook-deliveries",
    ]

    /// `?history=true` when the request asks for a history, else empty: the one query that
    /// selects a different recorded response on the same path.
    private static func historyFlag(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "history" && $0.value == "true" } ? "?history=true" : ""
    }

    private static func op(in body: Data?) -> String? {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["op"] as? String
    }

    // MARK: - Fixtures

    /// The recorded fixtures, beside this repository's checkout of the packages.
    static let fixtureDirectory: URL = .init(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // App/Tests/Snapshots
        .deletingLastPathComponent() // App/Tests
        .deletingLastPathComponent() // App
        .deletingLastPathComponent() // the checkout
        .appendingPathComponent("SourcePackages/checkouts/district-core-swift/contracts/mobile")

    /// `/api/district/contacts/blocked` -> `district-contacts-blocked.json`, and a workspace
    /// route without its `workspace-` (`/api/district/workspace/members` ->
    /// `district-members.json`), the two ways the fixtures are named, if the file exists.
    private static func byName(_ path: String) -> Reply? {
        guard path.hasPrefix("/api/") else { return nil }
        let name = path.dropFirst("/api/".count).replacingOccurrences(of: "/", with: "-")
        let short = name.replacingOccurrences(of: "district-workspace-", with: "district-")
        for candidate in [name, short, "district-\(name)"] {
            let url = fixtureDirectory.appendingPathComponent("\(candidate).json")
            if let data = try? Data(contentsOf: url) {
                return Reply(status: 200, body: data)
            }
        }
        return nil
    }

    /// ⛔ A MISSING FIXTURE IS A FAILED TEST, NOT AN EMPTY BODY: an empty body would draw the
    /// screen's failure state and record it as the reference.
    static func fixtureData(_ name: String) -> Data {
        let url = fixtureDirectory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("no contract fixture \(name).json in \(fixtureDirectory.path)")
            return Data()
        }
        return data
    }
}
