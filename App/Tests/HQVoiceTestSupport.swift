@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation

/// A transport answering the HQ voice routes by their last path component, recording every
/// request it saw. A route with no reply answers 500.
final class HQVoiceTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
    }

    private let lock = NSLock()
    private var replies: [String: Reply]
    private var seen: [(path: String, body: String)] = []

    init(_ replies: [String: Reply] = [:]) {
        self.replies = replies
    }

    func reply(_ route: String, _ status: Int = 200, _ body: String) {
        lock.withLock { replies[route] = Reply(status: status, body: body) }
    }

    /// The paths called, in order.
    var paths: [String] {
        lock.withLock { seen.map(\.path) }
    }

    /// The bodies sent to one route, in order.
    func bodies(_ route: String) -> [String] {
        lock.withLock { seen.filter { $0.path.hasSuffix("/" + route) }.map(\.body) }
    }

    func count(_ route: String) -> Int {
        bodies(route).count
    }

    func send(_ request: HTTPRequest, followRedirects _: Bool) async throws -> HTTPResponse {
        let path = request.url.path
        let route = path.hasSuffix("/proposals/cancel") ? "proposals/cancel" : request.url.lastPathComponent
        return lock.withLock {
            seen.append((path, String(bytes: request.body ?? Data(), encoding: .utf8) ?? ""))
            let reply = replies[route] ?? Reply(status: 500, body: #"{"error":"no stub for \#(route)"}"#)
            return HTTPResponse(
                statusCode: reply.status,
                headers: ["Content-Type": "application/json"],
                body: Data(reply.body.utf8)
            )
        }
    }

    var repository: HQRepository {
        HQRepository(client: ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: self,
            accessToken: { "session-token" }
        ))
    }

    static func token(micMode: String = "open", region: String = "us") -> String {
        #"""
        {"success":true,"token":"tok-secret","url":"wss://hq.example.test","roomName":"hq_ws1_abc",
        "processingRegion":"\#(region)","micMode":"\#(micMode)","sessionId":"sess-secret","e2ee":{"key":"k3y"}}
        """#
    }

    static let allowance = #"""
    {"success":false,"error":"This workspace has used all 120 of this month's District HQ voice minutes.",
    "code":"hq_voice_allowance_reached"}
    """#
}

/// An HQ voice room that records what the session asked of it and emits what a test says.
@MainActor
final class FakeHQVoiceEngine: HQVoiceEngine {
    let events: AsyncStream<HQVoiceEngineEvent>
    private let continuation: AsyncStream<HQVoiceEngineEvent>.Continuation
    private(set) var joined: (url: String, token: String)?
    private(set) var microphone: [Bool] = []
    private(set) var disconnects = 0
    var failsToJoin = false

    init() {
        (events, continuation) = AsyncStream<HQVoiceEngineEvent>.makeStream()
    }

    func emit(_ event: HQVoiceEngineEvent) {
        continuation.yield(event)
    }

    func connect(url: String, token: String) async throws {
        if failsToJoin {
            throw URLError(.cannotConnectToHost)
        }
        joined = (url, token)
    }

    /// While true, each microphone change waits for ``releaseMicrophone()``, as a slow
    /// track publish would.
    var holdsMicrophone = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var pendingMicrophone: Int {
        waiting.count
    }

    func releaseMicrophone() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }

    func setMicrophone(enabled: Bool) async -> Bool {
        microphone.append(enabled)
        if holdsMicrophone {
            await withCheckedContinuation { waiting.append($0) }
        }
        return enabled
    }

    func disconnect() async {
        disconnects += 1
        continuation.finish()
    }
}

/// Polls until `condition` holds, for work the session hands to a task (the event pump, a
/// fire-and-forget screen report). Fails the wait, not the process, after two seconds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
