@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// What the composer says when a draft write does not land.
///
/// ⛔ A DRAFT THAT SURVIVES ITS OWN SEND IS A MESSAGE SENT TWICE: restored on another
/// device and sent again. So the post-send delete is retried once and then named, and
/// a failed autosave is said quietly rather than swallowed.
@MainActor
final class ThreadModelDraftWriteTests: XCTestCase {
    func testAPostSendDeleteThatFailsTwiceIsNamed() async {
        let transport = ScriptedTransport([Self.timeline, Self.sent, Self.refused, Self.refused])
        let model = Self.model(transport)
        await model.load()
        model.composerTextChanged("On my way.")

        await model.send()

        XCTAssertEqual(transport.count(of: .delete), 2, "retried exactly once")
        XCTAssertEqual(model.draftNotice, ThreadModel.sentDraftSurvived)
    }

    func testAPostSendDeleteThatSucceedsOnTheRetryLeavesNothingToSay() async {
        let transport = ScriptedTransport([Self.timeline, Self.sent, Self.refused, Self.deleted, Self.timeline])
        let model = Self.model(transport)
        await model.load()
        model.composerTextChanged("On my way.")

        await model.send()

        XCTAssertEqual(transport.count(of: .delete), 2)
        XCTAssertNil(model.draftNotice)
    }

    func testAPostSendDeleteThatLandsFirstTimeIsNotRetried() async {
        let transport = ScriptedTransport([Self.timeline, Self.sent, Self.deleted, Self.timeline])
        let model = Self.model(transport)
        await model.load()
        model.composerTextChanged("On my way.")

        await model.send()

        XCTAssertEqual(transport.count(of: .delete), 1)
        XCTAssertNil(model.draftNotice)
    }

    /// ⚠️ QUIET, AND CLEARED BY THE NEXT SAVE THAT LANDS.
    func testAFailedAutosaveIsSaidAndTheNextSaveClearsIt() async {
        let transport = ScriptedTransport([Self.refused, Self.saved])
        let model = Self.model(transport)

        await model.persistDraft("Half a reply")
        let afterFailure = model.draftNotice
        await model.persistDraft("Half a reply, finished")

        XCTAssertEqual(afterFailure, ThreadModel.draftNotSaved)
        XCTAssertNil(model.draftNotice)
    }

    func testAFailedBlankBoxDeleteIsSaidToo() async {
        let transport = ScriptedTransport([Self.refused])
        let model = Self.model(transport)

        let handled = await model.deleteDraftIfBlank("   ")

        XCTAssertTrue(handled)
        XCTAssertEqual(model.draftNotice, ThreadModel.draftNotSaved)
    }

    // MARK: - Helpers

    private static func model(_ transport: ScriptedTransport) -> ThreadModel {
        ThreadModel(
            inbox: InboxRepository(client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            )),
            workspaceId: "ws_1",
            role: .client,
            threadKey: "contact:c_1",
            replyTargets: [ReplyTarget(to: "+14165551234", channel: MessageChannel.sms)]
        )
    }

    private static let timeline = (200, #"""
    {"success":true,"timeline":[{"id":"msg_1","type":"sms","timestamp":"2026-08-15T14:05:00.000Z",
     "direction":"inbound","body":"Are you coming?","status":"received"}],
     "pageInfo":{"hasMore":false,"oldest":"2026-08-15T14:05:00.000Z","oldestId":"msg_1"}}
    """#)

    private static let sent = (200, #"""
    {"success":true,"message":{"id":"msg_2","messageSid":"SM_1","workspaceId":"ws_1",
     "from":"+16475550100","to":"+14165551234","body":"On my way.","direction":"outbound",
     "type":"sms","status":"queued","createdAt":"2026-08-15T14:30:00.000Z","externalId":"SM_1",
     "provider":"twilio","accountId":"acct_1"}}
    """#)

    private static let deleted = (200, #"{"success":true}"#)

    private static let saved = (200, #"""
    {"success":true,"draft":{"threadKey":"contact:c_1","body":"Half a reply, finished",
     "subject":null,"mediaUrls":[],"updatedAt":"2026-08-15T14:30:00.000Z"}}
    """#)

    /// ⚠️ A 400, NOT A 5xx, so no transport-level retry can blur the count this
    /// suite is about.
    private static let refused = (400, #"{"error":"refused"}"#)
}

/// Answers a fixed script of `(status, body)` in order, and records every request.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(Int, String)]
    private var methods: [HTTPMethod] = []

    init(_ script: [(Int, String)]) {
        self.script = script
    }

    func count(of method: HTTPMethod) -> Int {
        lock.withLock { methods.filter { $0 == method }.count }
    }

    /// ⚠️ A SCRIPT THAT HAS RUN DRY ANSWERS 500 rather than hanging.
    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let next: (Int, String)? = lock.withLock {
            methods.append(request.method)
            return script.isEmpty ? nil : script.removeFirst()
        }
        guard let (status, body) = next else {
            return HTTPResponse(statusCode: 500, headers: [:], body: nil)
        }
        return HTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }
}
