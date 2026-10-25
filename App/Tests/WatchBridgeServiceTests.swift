@testable import DistrictAI
import DistrictAuthCore
import DistrictData
import DistrictNetwork
import Foundation
import UIKit
import XCTest

/// The iPhone's half of the watch app: the reply comes after the work, every write goes
/// through the phone's own paths, and a sign-out clears the watch.
@MainActor
final class WatchBridgeServiceTests: XCTestCase {
    // MARK: - Writes

    /// ⛔ THE REPLY HANDLER IS CALLED AFTER THE WORK, NEVER BEFORE IT.
    func testTheReplyComesAfterTheWriteAndASnapshotFollows() async throws {
        let rig = ServiceRig()
        let reply = ReplyRecorder(log: rig.log)

        try await rig.service.handle(
            requestData: Self.request(.markRead(workspaceId: "ws_1", threadKey: "contact:c_1")),
            reply: reply.record
        )

        XCTAssertEqual(rig.log.all, [
            "perform markRead contact:c_1",
            "reply ok",
            "snapshot",
            "publish",
        ])
        XCTAssertEqual(reply.replies, [.success])
        XCTAssertEqual(rig.tasks.ended.sorted { $0.rawValue < $1.rawValue }, rig.tasks.begun)
    }

    func testAFailedWriteRepliesWithItsSentence() async throws {
        let rig = ServiceRig(outcome: .failure(WatchActionFailure(sentence: "Reply refused.")))
        let reply = ReplyRecorder(log: rig.log)

        try await rig.service.handle(
            requestData: Self.request(.reply(workspaceId: "ws_1", threadKey: "contact:c_1", text: "Hi")),
            reply: reply.record
        )

        XCTAssertEqual(reply.replies, [.failure("Reply refused.")])
        XCTAssertEqual(rig.actions.performed, [.reply(workspaceId: "ws_1", threadKey: "contact:c_1", text: "Hi")])
    }

    func testAvailabilityGoesToTheActionsForTheNamedWorkspace() async throws {
        let rig = ServiceRig()
        let reply = ReplyRecorder(log: rig.log)

        try await rig.service.handle(
            requestData: Self.request(.setAvailability(workspaceId: "ws_2", available: false)),
            reply: reply.record
        )

        XCTAssertEqual(rig.actions.performed, [.setAvailability(workspaceId: "ws_2", available: false)])
        XCTAssertEqual(reply.replies, [.success])
    }

    /// A tapped notification's message, answered with its thread's key, and a snapshot after.
    func testAResolveRepliesWithTheThreadKeyThenASnapshot() async throws {
        let rig = ServiceRig()
        let reply = ReplyRecorder(log: rig.log)

        try await rig.service.handle(
            requestData: Self.request(.resolveMessage(workspaceId: "ws_1", messageId: "msg_1")),
            reply: reply.record
        )

        XCTAssertEqual(reply.replies, [.thread("contact:c_1")])
        XCTAssertEqual(rig.actions.resolved, ["ws_1/msg_1"])
        XCTAssertTrue(rig.actions.performed.isEmpty)
        XCTAssertEqual(rig.log.all, ["resolve msg_1", "reply ok", "snapshot", "publish"])
    }

    func testAnUnresolvedMessageRepliesWithAFailure() async throws {
        let rig = ServiceRig(threadKey: .failure(WatchActionFailure(sentence: "Could not open.")))
        let reply = ReplyRecorder(log: rig.log)

        try await rig.service.handle(
            requestData: Self.request(.resolveMessage(workspaceId: "ws_1", messageId: "msg_1")),
            reply: reply.record
        )

        XCTAssertEqual(reply.replies, [.failure("Could not open.")])
    }

    /// ⛔ A REQUEST FROM ANOTHER PROTOCOL VERSION IS REFUSED UNREAD, and nothing is written.
    func testAnotherVersionIsRefusedAndNothingIsWritten() async throws {
        let rig = ServiceRig()
        let reply = ReplyRecorder(log: rig.log)
        let request = WatchRequest(
            action: .markRead(workspaceId: "ws_1", threadKey: "contact:c_1"),
            protocolVersion: 99
        )

        try await rig.service.handle(requestData: WatchWire.encoder.encode(request), reply: reply.record)

        XCTAssertTrue(rig.actions.performed.isEmpty)
        XCTAssertEqual(reply.replies, [.failure(WatchBridgeCopy.updateBothApps)])
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun)
    }

    // MARK: - Snapshots

    /// ⛔ A SIGNED-OUT PHONE CLEARS THE WATCH AT ONCE, WITH NO READ.
    func testSignOutPublishesASignedOutSnapshotWithoutBuilding() {
        let rig = ServiceRig()

        rig.service.publishSignedOut()

        XCTAssertEqual(rig.link.published.count, 1)
        XCTAssertEqual(rig.service.lastPublished?.signedIn, false)
        XCTAssertNil(rig.service.lastPublished?.workspace)
        XCTAssertFalse(rig.log.all.contains("snapshot"))
    }

    func testNoWatchAppMeansNoReads() async {
        let rig = ServiceRig(installed: false)

        rig.service.setNeedsSnapshot()
        await rig.service.settle()

        XCTAssertFalse(rig.log.all.contains("snapshot"))
        XCTAssertTrue(rig.link.published.isEmpty)
    }

    /// ⚠️ TRIGGERS DURING A BUILD COALESCE INTO ONE MORE BUILD, NOT ONE EACH.
    func testTriggersDuringABuildCoalesce() async {
        let rig = ServiceRig()
        let service = rig.service
        rig.source.duringFirstBuild = {
            service.setNeedsSnapshot()
            service.setNeedsSnapshot()
            service.setNeedsSnapshot()
        }

        service.setNeedsSnapshot()
        service.setNeedsSnapshot()
        await service.settle()

        XCTAssertEqual(rig.log.count { $0 == "snapshot" }, 2)
        XCTAssertEqual(rig.link.published.count, 2)
    }

    /// ⚠️ "COULD NOT CHECK" PUBLISHES NOTHING: the watch keeps its picture and its age.
    func testAnUncheckableSessionPublishesNothing() async {
        let rig = ServiceRig(snapshot: nil)

        rig.service.setNeedsSnapshot()
        await rig.service.settle()

        XCTAssertTrue(rig.link.published.isEmpty)
    }

    // MARK: - The real write path, from a thread key

    /// ⛔ MARK READ FROM THE WATCH GOES THROUGH THE NOTIFICATION HANDLER: the one coordinator
    /// refreshes first, and the thread key becomes the selector with no extra read.
    func testMarkReadByThreadKeyRefreshesThenMarks() async {
        let rig = await HandlerRig()
        let actions = ContainerWatchActions(
            notificationActions: rig.handler,
            callHandling: CallHandlingRepository(client: rig.api)
        )

        let outcome = await actions.perform(.markRead(workspaceId: "ws_1", threadKey: "contact:c_1"))

        XCTAssertNoThrow(try outcome.get())
        XCTAssertEqual(rig.log.all, ["refresh", "POST mark-read Bearer access-fresh"])
        XCTAssertTrue(rig.transport.bodies.contains { $0.contains("c_1") })
    }

    /// ⛔ A REPLY'S CHANNEL IS THE CONVERSATION LIST'S OWN, read fresh, never assembled.
    func testReplyByThreadKeySendsToTheServersReplyTarget() async {
        let rig = await HandlerRig()
        let actions = ContainerWatchActions(
            notificationActions: rig.handler,
            callHandling: CallHandlingRepository(client: rig.api)
        )

        let outcome = await actions.perform(
            .reply(workspaceId: "ws_1", threadKey: "addr:14165558888", text: "On my way.")
        )

        XCTAssertNoThrow(try outcome.get())
        XCTAssertEqual(rig.log.all, [
            "refresh",
            "GET conversations Bearer access-fresh",
            "POST send Bearer access-fresh",
        ])
        XCTAssertTrue(rig.transport.bodies.contains { $0.contains("+14165558888") && $0.contains("On my way.") })
    }

    func testAThreadNoLongerListedIsNotSentAndSaysWhy() async {
        let rig = await HandlerRig()
        let actions = ContainerWatchActions(
            notificationActions: rig.handler,
            callHandling: CallHandlingRepository(client: rig.api)
        )

        let outcome = await actions.perform(.reply(workspaceId: "ws_1", threadKey: "contact:gone", text: "Hi"))

        guard case let .failure(failure) = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.sentence, NavigationCopy.conversationCouldNotOpened)
        XCTAssertEqual(rig.log.count { $0.hasPrefix("POST send") }, 0)
    }

    func testARefusedMarkReadCarriesTheServersSentence() async {
        let rig = await HandlerRig(writeStatus: 403, writeBody: #"{"success":false,"error":"Not a member."}"#)
        let actions = ContainerWatchActions(
            notificationActions: rig.handler,
            callHandling: CallHandlingRepository(client: rig.api)
        )

        let outcome = await actions.perform(.markRead(workspaceId: "ws_1", threadKey: "contact:c_1"))

        guard case let .failure(failure) = outcome else { return XCTFail("expected a failure") }
        XCTAssertFalse(failure.sentence.isEmpty)
    }

    /// ⛔ THE MESSAGE BECOMES ITS THREAD ON THE PHONE, under the one coordinator: refresh,
    /// then `GET messages/{id}`, and the server's own thread key comes back.
    func testResolveByMessageIdRefreshesThenReadsTheMessage() async {
        let rig = await HandlerRig()
        let actions = ContainerWatchActions(
            notificationActions: rig.handler,
            callHandling: CallHandlingRepository(client: rig.api)
        )

        let outcome = await actions.threadKey(workspaceId: "ws_1", messageId: "msg_1")

        XCTAssertEqual(try? outcome.get(), "contact:c_1")
        XCTAssertEqual(rig.log.all, ["refresh", "GET msg_1 Bearer access-fresh"])
    }

    func testAMessageTheServerRefusesIsNotResolved() async {
        let rig = await HandlerRig(writeStatus: 404, writeBody: #"{"success":false,"error":"Not found."}"#)
        let actions = ContainerWatchActions(
            notificationActions: rig.handler,
            callHandling: CallHandlingRepository(client: rig.api)
        )

        let outcome = await actions.threadKey(workspaceId: "ws_1", messageId: "msg_1")

        guard case let .failure(failure) = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.sentence, InboxCopy.conversationCouldNotOpened)
    }

    // MARK: - Helpers

    static func request(_ action: WatchAction) throws -> Data {
        try WatchWire.encoder.encode(WatchRequest(action: action))
    }
}

// MARK: - Fakes

@MainActor
private final class FakeWatchLink: WatchSessionLinking {
    let isCompanionInstalled: Bool
    let log: ActionEventLog
    private(set) var published: [[String: Any]] = []

    init(installed: Bool, log: ActionEventLog) {
        isCompanionInstalled = installed
        self.log = log
    }

    func activate(
        onReady _: @escaping @MainActor @Sendable () -> Void,
        onRequest _: @escaping @MainActor @Sendable (Data, @escaping @Sendable ([String: Any]) -> Void) -> Void
    ) {}

    func publish(_ context: [String: Any]) throws {
        log.append("publish")
        published.append(context)
    }
}

@MainActor
private final class FakeSnapshotSource: WatchSnapshotSourcing {
    let log: ActionEventLog
    let snapshot: WatchSnapshot?
    var duringFirstBuild: (@MainActor () -> Void)?

    init(log: ActionEventLog, snapshot: WatchSnapshot?) {
        self.log = log
        self.snapshot = snapshot
    }

    func snapshot(at _: Date) async -> WatchSnapshot? {
        log.append("snapshot")
        let during = duringFirstBuild
        duringFirstBuild = nil
        during?()
        // ⚠️ A REAL SUSPENSION, so a trigger made while this runs finds a build in flight.
        await Task.yield()
        return snapshot
    }
}

@MainActor
private final class FakeWatchActions: WatchActionPerforming {
    let log: ActionEventLog
    let outcome: Result<Void, WatchActionFailure>
    let threadKey: Result<String, WatchActionFailure>
    private(set) var performed: [WatchAction] = []
    private(set) var resolved: [String] = []

    init(log: ActionEventLog, outcome: Result<Void, WatchActionFailure>, threadKey: Result<
        String,
        WatchActionFailure
    >) {
        self.log = log
        self.outcome = outcome
        self.threadKey = threadKey
    }

    func threadKey(workspaceId: String, messageId: String) async -> Result<String, WatchActionFailure> {
        resolved.append("\(workspaceId)/\(messageId)")
        log.append("resolve \(messageId)")
        return threadKey
    }

    func perform(_ action: WatchAction) async -> Result<Void, WatchActionFailure> {
        performed.append(action)
        if case let .markRead(_, threadKey) = action {
            log.append("perform markRead \(threadKey)")
        }
        return outcome
    }
}

private final class ReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let log: ActionEventLog
    private var received: [WatchReply] = []

    init(log: ActionEventLog) {
        self.log = log
    }

    var replies: [WatchReply] {
        lock.withLock { received }
    }

    var record: @Sendable ([String: Any]) -> Void {
        { [self] message in
            let reply = WatchReply.read(message)
            log.append(reply?.ok == true ? "reply ok" : "reply error")
            lock.withLock { received.append(reply ?? .failure("unreadable")) }
        }
    }
}

@MainActor
private struct ServiceRig {
    let log = ActionEventLog()
    let link: FakeWatchLink
    let actions: FakeWatchActions
    let source: FakeSnapshotSource
    let tasks = FakeBackgroundTasks()
    let service: WatchBridgeService

    init(
        installed: Bool = true,
        snapshot: WatchSnapshot? = WatchSnapshotTests.full(rows: 2),
        outcome: Result<Void, WatchActionFailure> = .success(()),
        threadKey: Result<String, WatchActionFailure> = .success("contact:c_1")
    ) {
        link = FakeWatchLink(installed: installed, log: log)
        actions = FakeWatchActions(log: log, outcome: outcome, threadKey: threadKey)
        source = FakeSnapshotSource(log: log, snapshot: snapshot)
        service = WatchBridgeService(
            link: link,
            source: source,
            actions: actions,
            backgroundTasks: tasks
        )
    }
}

/// The real handler, coordinator and repositories, over a transport that answers the three
/// routes a thread-key action can reach.
@MainActor
private struct HandlerRig {
    let log = ActionEventLog()
    let transport: ThreadActionTransport
    let api: ApiClient
    let handler: NotificationActionHandler

    init(writeStatus: Int = 200, writeBody: String? = nil) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let coordinator = TokenRefreshCoordinator(
            store: InMemoryTokenStore(),
            refreshClient: LoggingRefreshClient(log: log)
        )
        await coordinator.adopt(
            NativeTokens(
                accessToken: "access-stale",
                accessTokenExpiresAt: now - 60000,
                refreshToken: "refresh-1",
                refreshTokenExpiresAt: now + 3_600_000
            ),
            deviceId: "device-test"
        )
        let transport = ThreadActionTransport(log: log, writeStatus: writeStatus, writeBody: writeBody)
        self.transport = transport
        api = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: AppContainer.bearer(coordinator),
            rejectedToken: AppContainer.rejected(coordinator)
        )
        handler = NotificationActionHandler(
            coordinator: coordinator,
            inbox: InboxRepository(client: api),
            whisper: CallsRepository(client: api),
            reporter: RecordingFailureReporter(),
            backgroundTasks: FakeBackgroundTasks()
        )
    }
}

private final class ThreadActionTransport: HTTPTransport, @unchecked Sendable {
    private let log: ActionEventLog
    private let writeStatus: Int
    private let writeBody: String?
    private let lock = NSLock()
    private var recorded: [String] = []

    var bodies: [String] {
        lock.withLock { recorded }
    }

    init(log: ActionEventLog, writeStatus: Int, writeBody: String?) {
        self.log = log
        self.writeStatus = writeStatus
        self.writeBody = writeBody
    }

    func send(_ request: HTTPRequest, followRedirects _: Bool) async throws -> HTTPResponse {
        let segment = request.url.lastPathComponent
        log.append("\(request.method.rawValue) \(segment) \(request.headers["Authorization"] ?? "none")")
        if let text = request.body.flatMap({ String(data: $0, encoding: .utf8) }) {
            lock.withLock { recorded.append(text) }
        }
        switch segment {
        case "conversations":
            return Self.json(200, Self.conversations)
        case "msg_1":
            // ⚠️ `GET messages/{id}`, answered with the write status so a test can refuse it.
            return Self.json(writeStatus, writeBody ?? Self.messageThread)
        case "send":
            return Self.json(writeStatus, writeBody ?? Self.sent)
        default:
            return Self.json(writeStatus, writeBody ?? #"{"success":true,"marked":1}"#)
        }
    }

    private static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    /// ⚠️ THE CONTRACT FIXTURE'S SMS-ONLY THREAD (`district-conversations.json`).
    private static let conversations = #"""
    {"success":true,"conversations":[
     {"key":"14165558888","threadKey":"addr:14165558888","counterpart":"+14165558888",
      "matchKeys":["14165558888"],"kind":"phone","channels":["sms"],"contactId":null,
      "contactName":null,"contactEmail":null,"contactPhone":null,"canSms":true,"canEmail":false,
      "lastMessage":{"body":"Is this the roofing company?","direction":"inbound","type":"sms",
       "status":"received","createdAt":"2026-08-15T13:10:00.000Z"},
      "unreadCount":1,"totalMessages":1}],
     "scanned":1,"scanLimit":500}
    """#

    /// ⚠️ THE CORE'S OWN RESOLVER FIXTURE SHAPE (`InboxThreadResolveTests.contactKeyed`).
    private static let messageThread = #"""
    {"success":true,
     "message":{"id":"msg_1","direction":"inbound","type":"sms","readAt":null,
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"contact:c_1","contactId":"c_1","counterpart":"+14165550134","channel":"sms"}}
    """#

    private static let sent = #"""
    {"success":true,"message":{"id":"msg_2","messageSid":"SM_1","workspaceId":"ws_1",
     "from":"+16475550100","to":"+14165558888","body":"On my way.","direction":"outbound",
     "type":"sms","status":"queued","createdAt":"2026-08-15T14:30:00.000Z","externalId":"SM_1",
     "provider":"twilio","accountId":"acct_1"}}
    """#
}
