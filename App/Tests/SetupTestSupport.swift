@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// A transport that answers by ROUTE (`"GET /api/district/setup"`), each route its own queue,
/// and keeps every request.
///
/// ⚠️ BY ROUTE, NOT ONE QUEUE LIKE ``SettingsTransport``, because the wizard's steps read two
/// or three routes at once with `async let`, and the order those requests reach a transport
/// is not the order they were written in. A route whose queue has one answer left keeps
/// giving it, so a poll can read the same body twice; a route with none answers 500.
final class SetupTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [(status: Int, body: String)]]
    private(set) var requests: [HTTPRequest] = []
    /// Waits this long before answering, so a test can tap twice while one write is in flight.
    var delay: Duration?

    init(_ routes: [String: [(status: Int, body: String)]]) {
        self.routes = routes
    }

    func add(_ route: String, status: Int = 200, _ body: String) {
        lock.withLock { routes[route, default: []].append((status, body)) }
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        if let delay {
            try? await Task.sleep(for: delay)
        }
        let key = "\(request.method.rawValue) \(request.url.path)"
        let next: (status: Int, body: String)? = lock.withLock {
            requests.append(request)
            guard var queue = routes[key], let first = queue.first else { return nil }
            if queue.count > 1 {
                queue.removeFirst()
                routes[key] = queue
            }
            return first
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

    func sent(_ route: String) -> [HTTPRequest] {
        lock.withLock { requests }.filter { route == "\($0.method.rawValue) \($0.url.path)" }
    }

    /// The JSON bodies sent to `route`, parsed.
    func bodies(_ route: String) -> [[String: Any]] {
        sent(route).compactMap { request in
            request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    var client: ApiClient {
        ApiClient(baseURL: ApiClient.productionBaseURL, transport: self, accessToken: { "session-token" })
    }
}

/// Bodies shaped like district-core-swift 8.5.0's vendored `contracts/mobile` fixtures.
enum SetupFixture {
    static let setupRoute = "GET /api/district/setup"
    static let patchRoute = "PATCH /api/district/setup"
    static let lookupRoute = "POST /api/district/setup/lookup"
    static let testCallRoute = "POST /api/district/setup/test-call"
    static let forwardingRoute = "GET /api/district/setup/forwarding-check"
    static let forwardingStartRoute = "POST /api/district/setup/forwarding-check"
    static let configRoute = "GET /api/district/workspace/config"
    static let optionsRoute = "GET /api/district/workspace/persona/options"
    static let personaRoute = "PATCH /api/district/workspace/persona"
    static let renameRoute = "PATCH /api/district/workspace/rename"
    static let callHandlingRoute = "GET /api/district/workspace/call-handling"
    static let callHandlingSaveRoute = "PATCH /api/district/workspace/call-handling"
    static let connectionsRoute = "GET /api/district/connections"

    /// `district-setup.json`, with each step's state given.
    static func setup(
        _ states: [String] = ["todo", "todo", "todo", "todo", "todo", "todo"],
        facts: String = "null",
        numbersHeld: Int = 1,
        completed: Bool = false
    ) -> String {
        let keys = ["business", "number", "receptionist", "callers", "calls", "golive"]
        let steps = zip(keys, states).map { "\"\($0)\":\"\($1)\"" }.joined(separator: ",")
        let completedAt = completed ? ",\"completedAt\":\"2026-11-08T12:00:00.000Z\"" : ""
        return """
        {"setupProgress":{"steps":{\(steps)},"paidAt":"2026-09-23T15:04:05.000Z"\(completedAt)},\
        "businessFacts":\(facts),"region":"ca","tier":"VoicePro","includedNumbers":3,"numbersHeld":\(numbersHeld)}
        """
    }

    static let lookup = """
    {"draft":{"services":[{"name":"Cleaning","price":"$120","enabled":false},{"name":"Whitening","enabled":false}],\
    "faqs":[{"question":"Do you take new patients?","answer":"Yes, call to book.","enabled":false}],"dropped":1,\
    "address":{"line1":"100 Example Street","city":"Toronto","region":"ON","postalCode":"M5V 1A1","country":"CA"},\
    "weeklyHours":{"mon":[{"open":"09:00","close":"17:00"}]}},"source":{"kind":"website","url":"https://example.com/"}}
    """

    static let unreadable = """
    {"error":"That website could not be read.","code":"website_unreadable","reason":"host_unavailable"}
    """

    static func config(name: String? = "Ada", greeting: String? = nil, tier: String? = "VoicePro") -> String {
        let persona = if let name {
            """
            {"name":"\(name)","voice":"Joanna","greeting":\(greeting.map { "\"\($0)\"" } ?? "null"),\
            "modelId":"aws-pipeline","language":"en-US","dgiEnabled":false}
            """
        } else {
            "null"
        }
        return """
        {"success":true,"config":{"aiPersona":\(persona),"toolConfig":{"allowedTools":["transfer_to_agent"],\
        "supportPhoneNumber":"+14165550199"},"routingRules":[],"callDirectory":[],"messagingConfig":null,\
        "campaignSettings":null,"creatorCellNumber":null,"plan":null,\
        "subscriptionTier":\(tier.map { "\"\($0)\"" } ?? "null"),"updatedAt":"2026-08-15T14:30:00.000Z"}}
        """
    }

    static let options = """
    {"success":true,"region":"ca","engines":[{"id":"aws-pipeline","label":"AWS","inRegion":true,\
    "responseLengths":[]}],"languages":{"deepgram":[],"general":[{"value":"en-US","label":"English"}]},\
    "voices":[{"engine":"aws-pipeline","language":"en-US","groups":[{"label":"Voices","options":\
    [{"value":"Joanna","label":"Joanna"},{"value":"Matthew","label":"Matthew"}]}]},\
    {"engine":"aws-pipeline","language":"fr-CA","groups":[{"label":"Voix","options":\
    [{"value":"Gabrielle","label":"Gabrielle"},{"value":"Liam","label":"Liam"}]}]}],"voiceStyles":[],\
    "defaults":{"voiceByEngine":{"aws-pipeline":"Joanna"},"voiceByDeepgramLanguage":{},\
    "responseLength":"concise","temperature":0.7}}
    """

    static func callHandling(_ mode: String = "ai_first", ring: Int = 20) -> String {
        "{\"success\":true,\"callHandling\":\"\(mode)\",\"appRingSeconds\":\(ring)}"
    }

    static let connections = """
    {"connections":[{"provider":"google-calendar","status":"active"}],\
    "calendar":{"activeProvider":"google","source":"preference"}}
    """

    static func forwarding(_ status: String?, attemptsLeft: Int = 4, failure: String? = nil) -> String {
        guard let status else {
            return "{\"available\":true,\"forwardingCheck\":null,\"attemptsLeft\":\(attemptsLeft)}"
        }
        let failed = failure.map { ",\"failure\":\"\($0)\"" } ?? ""
        return """
        {"available":true,"forwardingCheck":{"id":"fwd_1","status":"\(status)","mode":"all",\
        "businessLine":"+14165550123","startedAt":"2026-09-23T15:10:00.000Z","at":"2026-09-23T15:10:00.000Z",\
        "verifierNumber":"+14165550142","carrier":"twilio"\(failed)},"attemptsLeft":\(attemptsLeft)}
        """
    }

    static let success = "{\"success\":true}"
}

extension SetupWizardModel {
    /// A wizard over `transport`, with a throwaway draft store.
    static func test(_ transport: SetupTransport, workspaceName: String = "Northside Dental") -> SetupWizardModel {
        SetupWizardModel(
            repository: SetupWizardRepository(client: transport.client),
            workspaceId: "ws_1",
            workspaceName: workspaceName,
            store: SetupDraftStore(defaults: SetupDefaults.fresh())
        )
    }
}

enum SetupDefaults {
    /// A suite of its own per call, so no test reads another's draft.
    static func fresh() -> UserDefaults {
        let name = "setup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

/// The helpers every step's tests share: a wizard loaded over a transport, and the
/// workspace repository over the same one.
@MainActor
class SetupStepTestCase: XCTestCase {
    func wizard(
        _ transport: SetupTransport,
        states: [String] = ["todo", "todo", "todo", "todo", "todo", "todo"],
        facts: String = "null",
        numbersHeld: Int = 1
    ) async -> SetupWizardModel {
        transport.add(SetupFixture.setupRoute, SetupFixture.setup(states, facts: facts, numbersHeld: numbersHeld))
        let model = SetupWizardModel.test(transport)
        await model.load()
        return model
    }

    func workspaces(_ transport: SetupTransport) -> WorkspaceRepository {
        WorkspaceRepository(client: transport.client)
    }
}
