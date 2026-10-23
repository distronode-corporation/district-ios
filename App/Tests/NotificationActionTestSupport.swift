@testable import DistrictAI
import DistrictAuthCore
import DistrictData
import DistrictNetwork
import Foundation
import UIKit

/// One ordered record of what happened, across the refresh, the transport and the
/// completion handler, so a test can assert ORDER and not only counts.
final class ActionEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var all: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func count(where match: (String) -> Bool) -> Int {
        all.filter(match).count
    }
}

/// A one-shot gate a fake can park on until the test opens it.
actor ActionGate {
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { parked.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }
}

/// Rotates once, to `access-fresh`, and logs that it did.
actor LoggingRefreshClient: RefreshClient {
    private let log: ActionEventLog

    init(log: ActionEventLog) {
        self.log = log
    }

    func refresh(refreshToken _: String) async -> RefreshResult {
        log.append("refresh")
        let farFuture = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        return .success(NativeTokens(
            accessToken: "access-fresh",
            accessTokenExpiresAt: farFuture,
            refreshToken: "refresh-2",
            refreshTokenExpiresAt: farFuture
        ))
    }
}

/// Answers the three inbox routes the handler uses, by the path's last segment, and logs
/// each request as `METHOD segment bearer`.
///
/// ⚠️ ITS OWN TYPE RATHER THAN ``SettingsTransport``'s QUEUE: the order of requests is
/// what is under test, so the answer has to depend on the route, not on the position.
final class InboxActionTransport: HTTPTransport, @unchecked Sendable {
    private let log: ActionEventLog
    private let writeStatus: Int
    private let writeBody: String
    private let threadGate: ActionGate?
    private let lock = NSLock()
    private(set) var bodies: [String] = []

    init(log: ActionEventLog, writeStatus: Int = 200, writeBody: String? = nil, threadGate: ActionGate? = nil) {
        self.log = log
        self.writeStatus = writeStatus
        self.writeBody = writeBody ?? ""
        self.threadGate = threadGate
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let segment = request.url.lastPathComponent
        let bearer = request.headers["Authorization"] ?? "none"
        log.append("\(request.method.rawValue) \(segment) \(bearer)")
        if let text = request.body.flatMap({ String(data: $0, encoding: .utf8) }) {
            lock.withLock { bodies.append(text) }
        }
        switch segment {
        case "send":
            return Self.json(writeStatus, writeBody.isEmpty ? Self.sent : writeBody)
        case "mark-read":
            return Self.json(writeStatus, writeBody.isEmpty ? #"{"success":true,"marked":1}"# : writeBody)
        default:
            await threadGate?.wait()
            return Self.json(200, Self.thread)
        }
    }

    private static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    /// ⚠️ THE CORE'S OWN RESOLVER FIXTURE SHAPE (`InboxThreadResolveTests.contactKeyed`).
    private static let thread = #"""
    {"success":true,
     "message":{"id":"msg_1","direction":"inbound","type":"sms","readAt":null,
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"contact:c_1","contactId":"c_1","counterpart":"+14165550134","channel":"sms"}}
    """#

    private static let sent = #"""
    {"success":true,"message":{"id":"msg_2","messageSid":"SM_1","workspaceId":"ws_1",
     "from":"+16475550100","to":"+14165550134","body":"On my way.","direction":"outbound",
     "type":"sms","status":"queued","createdAt":"2026-08-15T14:30:00.000Z","externalId":"SM_1",
     "provider":"twilio","accountId":"acct_1"}}
    """#
}

/// Keeps every failure the handler reported.
@MainActor
final class RecordingFailureReporter: MessageActionFailureReporting {
    private(set) var reports: [(failure: MessageActionFailure, action: MessageAction)] = []

    func report(_ failure: MessageActionFailure, for action: MessageAction) {
        reports.append((failure, action))
    }
}

/// Hands out identifiers, keeps each expiration handler, and records every end.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskScheduling {
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expirations: [@MainActor @Sendable () -> Void] = []
    private var next = 100

    func begin(_ name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        _ = name
        next += 1
        let identifier = UIBackgroundTaskIdentifier(rawValue: next)
        begun.append(identifier)
        expirations.append(expiration)
        return identifier
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    /// What the system does when the background time runs out.
    func expireAll() {
        expirations.forEach { $0() }
    }
}
