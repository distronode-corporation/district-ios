@testable import DistrictAI
import DistrictAuthCore
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Reply and Mark read from a notification on a COLD launch: no scene, no workspace
/// loaded, and an access token that has expired (it is memory-only, so a cold wake never
/// has a usable one).
///
/// ⚠️ THE COORDINATOR, THE API CLIENT AND THE BEARER CLOSURES ARE THE REAL ONES, wired
/// with ``AppContainer``'s own helpers; only the refresh client, the transport, the
/// reporter and the background-task seam are fakes. A stubbed token would not prove the
/// refresh happens before the request.
@MainActor
final class NotificationActionHandlerTests: XCTestCase {
    // MARK: - The cold path

    /// ⛔ THE BUG THIS FIXES: the reply used to wait for a view and a loaded workspace,
    /// neither of which a background launch has, and was dropped.
    func testAColdReplyRefreshesThenSendsThenCompletes() async {
        let rig = await Rig()
        let inbox = NotificationActionInbox()
        inbox.adopt(rig.handler)

        await inbox.receive(Self.payload(MessageNotificationAction.reply, text: "On my way.")) {
            rig.log.append("completion")
        }?.value

        XCTAssertEqual(rig.log.all, [
            "refresh",
            "GET msg_1 Bearer access-fresh",
            "POST send Bearer access-fresh",
            "completion",
        ])
        XCTAssertTrue(rig.transport.bodies.contains { $0.contains("On my way.") && $0.contains("+14165550134") })
        XCTAssertTrue(rig.reporter.reports.isEmpty)
        XCTAssertEqual(rig.tasks.begun.count, 1)
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun)
    }

    func testAColdMarkReadRefreshesThenMarksThenCompletes() async {
        let rig = await Rig()
        let inbox = NotificationActionInbox()
        inbox.adopt(rig.handler)

        await inbox.receive(Self.payload(MessageNotificationAction.markRead)) {
            rig.log.append("completion")
        }?.value

        XCTAssertEqual(rig.log.all, [
            "refresh",
            "GET msg_1 Bearer access-fresh",
            "POST mark-read Bearer access-fresh",
            "completion",
        ])
        XCTAssertTrue(rig.reporter.reports.isEmpty)
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun)
    }

    /// ⛔ A RESPONSE THAT ARRIVES BEFORE `DistrictApp.init` HAS ADOPTED THE HANDLER IS
    /// HELD, NOT DROPPED, and its completion waits with it.
    func testAnActionDeliveredBeforeTheHandlerIsHeldUntilAdopted() async {
        let rig = await Rig()
        let inbox = NotificationActionInbox()

        XCTAssertNil(inbox.receive(Self.payload(MessageNotificationAction.markRead)) {
            rig.log.append("completion")
        })
        XCTAssertTrue(rig.log.all.isEmpty)

        inbox.adopt(rig.handler)
        await waitUntil(state: "\(rig.log.all)") { rig.log.all.last == "completion" }
        XCTAssertEqual(rig.log.count { $0.hasPrefix("POST mark-read") }, 1)
    }

    // MARK: - Failure

    /// ⛔ THE SERVER DECIDES PERMISSIONS, AND A REFUSAL IS SAID OUT LOUD. There is no
    /// client-side role gate any more; a 403 is reported and the completion still runs.
    func testAServer403PostsTheFailureAndStillCompletes() async {
        let rig = await Rig(writeStatus: 403, writeBody: #"{"error":"Viewers cannot send messages"}"#)
        let inbox = NotificationActionInbox()
        inbox.adopt(rig.handler)

        await inbox.receive(Self.payload(MessageNotificationAction.reply, text: "On my way.")) {
            rig.log.append("completion")
        }?.value

        XCTAssertEqual(rig.log.all.last, "completion")
        XCTAssertEqual(rig.reporter.reports.count, 1)
        let report = rig.reporter.reports.first
        XCTAssertEqual(report?.action, .reply("On my way."))
        guard case let .refused(error)? = report?.failure else {
            return XCTFail("expected a refusal, got \(String(describing: report?.failure))")
        }
        XCTAssertEqual(error.httpStatus, 403)
        XCTAssertEqual(report?.failure.reason(for: .reply("On my way.")), "Viewers cannot send messages")
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun)
    }

    func testASignedOutHandsetSendsNothingAndSaysSo() async {
        let rig = await Rig(signedIn: false)

        await rig.handler.handleNotificationResponse(Self.payload(MessageNotificationAction.markRead))

        XCTAssertTrue(rig.log.all.isEmpty, "no refresh and no request: \(rig.log.all)")
        XCTAssertEqual(rig.reporter.reports.first?.failure, .signedOut(.noSession))
        XCTAssertEqual(
            MessageActionFailure.signedOut(.noSession).reason(for: .markRead),
            SessionCopy.sessionHasEndedPlease
        )
    }

    func testAPayloadWithNoMessageIsReportedNotDropped() async {
        let rig = await Rig()
        var payload = Self.payload(MessageNotificationAction.reply, text: "Hello")
        payload[PushPayload.keyMessageId] = nil

        await rig.handler.handleNotificationResponse(payload)

        XCTAssertTrue(rig.log.all.isEmpty)
        XCTAssertEqual(rig.reporter.reports.first?.failure, .unreadablePayload)
    }

    func testAnEmptyReplyIsNeitherSentNorReported() async {
        let rig = await Rig()

        await rig.handler.handleNotificationResponse(Self.payload(MessageNotificationAction.reply, text: "  "))

        XCTAssertTrue(rig.log.all.isEmpty)
        XCTAssertTrue(rig.reporter.reports.isEmpty)
    }

    // MARK: - Background time

    /// ⛔ ENDED EXACTLY ONCE: by the expiration handler, and NOT again when the work
    /// finishes afterwards.
    func testAnExpiredBackgroundTaskIsEndedExactlyOnce() async {
        let gate = ActionGate()
        let rig = await Rig(threadGate: gate)

        let work = Task { await rig.handler.perform(.markRead, workspaceId: "ws_1", messageId: "msg_1") }
        await waitUntil(state: "\(rig.log.all)") { rig.log.all.contains { $0.hasPrefix("GET") } }

        rig.tasks.expireAll()
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun, "the expiration handler ends the task")

        await gate.open()
        let outcome = await work.value

        XCTAssertNoThrow(try outcome.get())
        XCTAssertEqual(rig.tasks.begun.count, 1)
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun, "and the finished work does not end it again")
    }

    // MARK: - One tap, one request

    func testTheSameReplyDeliveredTwiceSendsOnce() async {
        let gate = ActionGate()
        let rig = await Rig(threadGate: gate)

        let first = Task { await rig.handler.perform(.reply("Hi"), workspaceId: "ws_1", messageId: "msg_1") }
        await waitUntil(state: "\(rig.log.all)") { rig.log.all.contains { $0.hasPrefix("GET") } }
        let second = Task { await rig.handler.perform(.reply("Hi"), workspaceId: "ws_1", messageId: "msg_1") }
        // ⚠️ YIELD THE MAIN ACTOR so the second caller reaches the in-flight check while
        // the first is still parked on the gate.
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        await gate.open()
        let outcomes = await [first.value, second.value]

        XCTAssertEqual(outcomes.count { (try? $0.get()) != nil }, 2)
        XCTAssertEqual(rig.log.count { $0 == "refresh" }, 1)
        XCTAssertEqual(rig.log.count { $0.hasPrefix("GET") }, 1)
        XCTAssertEqual(rig.log.count { $0.hasPrefix("POST send") }, 1)
        XCTAssertEqual(rig.tasks.begun.count, 1)
    }

    /// ⚠️ THE JOIN IS PER IN-FLIGHT REQUEST, NOT FOREVER: a second tap after the first
    /// finished is a second request.
    func testASecondTapAfterTheFirstFinishedIsASecondRequest() async {
        let rig = await Rig()

        _ = await rig.handler.perform(.markRead, workspaceId: "ws_1", messageId: "msg_1")
        _ = await rig.handler.perform(.markRead, workspaceId: "ws_1", messageId: "msg_1")

        XCTAssertEqual(rig.log.count { $0.hasPrefix("POST mark-read") }, 2)
        XCTAssertEqual(rig.log.count { $0 == "refresh" }, 1, "the second reuses the refreshed token")
    }

    // MARK: - Support

    private static func payload(_ action: String, text: String? = nil) -> [String: String] {
        var payload = [
            PushPayload.keyType: "message",
            PushPayload.keyWorkspaceId: "ws_1",
            PushPayload.keyMessageId: "msg_1",
            MessageNotificationAction.identifierKey: action,
        ]
        payload[MessageNotificationAction.replyTextKey] = text
        return payload
    }
}

/// The handler with real credential wiring and fake edges.
@MainActor
private struct Rig {
    let log: ActionEventLog
    let transport: InboxActionTransport
    let reporter: RecordingFailureReporter
    let tasks: FakeBackgroundTasks
    let handler: NotificationActionHandler

    init(
        signedIn: Bool = true,
        writeStatus: Int = 200,
        writeBody: String? = nil,
        threadGate: ActionGate? = nil
    ) async {
        let log = ActionEventLog()
        let reporter = RecordingFailureReporter()
        let tasks = FakeBackgroundTasks()
        self.log = log
        self.reporter = reporter
        self.tasks = tasks
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let coordinator = TokenRefreshCoordinator(
            store: InMemoryTokenStore(),
            refreshClient: LoggingRefreshClient(log: log)
        )
        if signedIn {
            // ⚠️ AN ACCESS TOKEN THAT EXPIRED A MINUTE AGO beside a live refresh token:
            // what the coordinator holds after a cold launch, as far as using it goes.
            await coordinator.adopt(
                NativeTokens(
                    accessToken: "access-stale",
                    accessTokenExpiresAt: now - 60000,
                    refreshToken: "refresh-1",
                    refreshTokenExpiresAt: now + 3_600_000
                ),
                deviceId: "device-test"
            )
        }
        let transport = InboxActionTransport(
            log: log,
            writeStatus: writeStatus,
            writeBody: writeBody,
            threadGate: threadGate
        )
        self.transport = transport
        let api = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: AppContainer.bearer(coordinator),
            rejectedToken: AppContainer.rejected(coordinator)
        )
        handler = NotificationActionHandler(
            coordinator: coordinator,
            inbox: InboxRepository(client: api),
            whisper: CallsRepository(client: api),
            reporter: reporter,
            backgroundTasks: tasks
        )
    }
}
