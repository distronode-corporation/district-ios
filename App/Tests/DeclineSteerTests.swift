@testable import DistrictAI
import DistrictAuthCore
import DistrictCall
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import UserNotifications
import XCTest

/// "You declined the call. Tell the assistant what to say?" (3.2): posted after a person's
/// decline and only then, and its three actions reach `calls/whisper` through
/// ``NotificationActionHandler`` on a cold launch.
@MainActor
final class DeclineSteerTests: XCTestCase {
    private let workspace = WorkspaceID("ws_1")
    private let call = CallID("call_1")

    // MARK: - When it is posted

    func testAPersonsDeclinePostsTheSteerOnce() async {
        let steer = RecordingSteerPoster()
        let sender = Self.sender(steer: steer)
        var controller = ringing()

        await dispatch(controller.handle(IncomingCallEnding.systemEnd(in: .ringing)), to: sender)

        XCTAssertEqual(steer.posts, [RecordingSteerPoster.Post(workspaceId: "ws_1", callId: "call_1")])
    }

    /// ⛔ A TIMEOUT, A WITHDRAWAL AND A RING ENDED FOR NO SESSION POST NOTHING: nobody refused.
    func testNoSteerWithoutAPerson() async {
        for event in [IncomingCallEvent.ringTimedOut, .withdrawnLocally, IncomingCallEnding.noSession] {
            let steer = RecordingSteerPoster()
            var controller = ringing()
            await dispatch(controller.handle(event), to: Self.sender(steer: steer))
            XCTAssertEqual(steer.posts, [], "\(event)")
        }
    }

    // MARK: - What is posted

    /// ⛔ AN `incoming_call` PUSH'S SHAPE, ids only, so a tap opens the call.
    func testTheContentIsIdsOnlyInTheCallShape() {
        let content = DeclineSteerNotification.content(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(content.body, "You declined the call. Tell the assistant what to say?")
        XCTAssertEqual(content.categoryIdentifier, "district.declined_steer")
        XCTAssertNil(content.sound)
        let payload = NotificationPresenter.flatten(content.userInfo)
        XCTAssertEqual(payload, ["type": "incoming_call", "workspaceId": "ws_1", "callId": "call_1"])
        XCTAssertEqual(PushPayload.parse(payload), .incomingCall(workspaceId: "ws_1", callId: "call_1"))
        XCTAssertEqual(DeclineSteerNotification.identifier(callId: "call_1"), "district.declined-steer.call_1")
    }

    func testTheCategoryOffersTheTwoLinesAndATextBox() throws {
        let category = DeclineSteerNotification.registration()

        XCTAssertEqual(category.identifier, DeclineSteerNotification.category)
        XCTAssertEqual(category.actions.map(\.title), [
            "We will call them back today.",
            "Ask what the call is about.",
            "Tell the assistant",
        ])
        XCTAssertTrue(category.actions.allSatisfy(\.options.isEmpty), "non-foreground, like Reply")
        let typed = try XCTUnwrap(category.actions.last as? UNTextInputNotificationAction)
        XCTAssertEqual(typed.textInputPlaceholder, "What should the assistant say?")
    }

    /// ⛔ THE CANNED LINES ARE THE WATCH'S OWN, WORD FOR WORD, in both languages.
    func testTheCannedLinesMatchTheWatch() {
        XCTAssertEqual(IncomingCallCopy.steerCallBackToday, "We will call them back today.")
        XCTAssertEqual(IncomingCallCopy.steerAskWhatAbout, "Ask what the call is about.")
    }

    /// ⚠️ THE THREE ACTIONS GO TO THE HANDLER, NEVER TO THE TAP RELAY.
    func testTheActionsAreShadeActions() {
        for identifier in [
            DeclineSteerNotification.typed,
            DeclineSteerNotification.callBackToday,
            DeclineSteerNotification.askWhatAbout,
        ] {
            XCTAssertTrue(MessageNotificationAction.isShadeAction(identifier), identifier)
        }
        XCTAssertFalse(MessageNotificationAction.isShadeAction(UNNotificationDefaultActionIdentifier))
    }

    func testAnUnknownActionIsNotASteer() {
        XCTAssertNil(DeclineSteerAction(payload: Self.payload(MessageNotificationAction.reply, text: "Hi")))
        XCTAssertNil(DeclineSteerAction(payload: Self.payload(UNNotificationDefaultActionIdentifier)))
    }

    // MARK: - Sending

    func testACannedLineRefreshesThenWhispersInsideABackgroundTask() async {
        let rig = await SteerRig()

        await rig.handler.handleNotificationResponse(Self.payload(DeclineSteerNotification.callBackToday))

        XCTAssertEqual(rig.log.all, ["refresh", "POST whisper Bearer access-fresh"])
        XCTAssertEqual(rig.transport.bodies.count, 1)
        let body = rig.transport.bodies.first ?? ""
        XCTAssertTrue(body.contains("We will call them back today."), body)
        XCTAssertTrue(body.contains("call_1") && body.contains("ws_1"), body)
        XCTAssertTrue(rig.reporter.steerReports.isEmpty)
        XCTAssertEqual(rig.tasks.begun.count, 1)
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun)
    }

    func testTheOtherCannedLineAndATypedLineAreSentAsWritten() async {
        let rig = await SteerRig()

        await rig.handler.handleNotificationResponse(Self.payload(DeclineSteerNotification.askWhatAbout))
        await rig.handler.handleNotificationResponse(
            Self.payload(DeclineSteerNotification.typed, text: "  Book them for Tuesday. ")
        )

        XCTAssertEqual(rig.transport.bodies.count, 2)
        XCTAssertTrue(rig.transport.bodies.first?.contains("Ask what the call is about.") == true)
        XCTAssertTrue(rig.transport.bodies.last?.contains("\"Book them for Tuesday.\"") == true)
    }

    func testAnEmptyBoxSendsNothingAndReportsNothing() async {
        let rig = await SteerRig()

        await rig.handler.handleNotificationResponse(Self.payload(DeclineSteerNotification.typed, text: " \n "))
        await rig.handler.handleNotificationResponse(Self.payload(DeclineSteerNotification.typed))

        XCTAssertTrue(rig.log.all.isEmpty)
        XCTAssertTrue(rig.reporter.steerReports.isEmpty)
    }

    /// ⛔ A CALL THAT ENDED IS SAID AS MUCH, and the instruction comes back in the report.
    func testARefusalIsReportedWithTheText() async {
        let rig = await SteerRig(writeStatus: 404, writeBody: #"{"error":"Call not found","code":"call_not_found"}"#)

        await rig.handler.handleNotificationResponse(Self.payload(DeclineSteerNotification.askWhatAbout))

        XCTAssertEqual(rig.reporter.steerReports.count, 1)
        let report = rig.reporter.steerReports.first
        XCTAssertEqual(report?.text, "Ask what the call is about.")
        XCTAssertEqual(report?.failure.steerReason, WatchBridgeCopy.whisperCallEnded)
        XCTAssertTrue(rig.reporter.reports.isEmpty, "not a message failure")
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun)
    }

    func testASignedOutHandsetSendsNothingAndSaysSo() async {
        let rig = await SteerRig(signedIn: false)

        await rig.handler.handleNotificationResponse(Self.payload(DeclineSteerNotification.callBackToday))

        XCTAssertTrue(rig.log.all.isEmpty)
        XCTAssertEqual(rig.reporter.steerReports.first?.failure, .signedOut(.noSession))
        XCTAssertEqual(MessageActionFailure.signedOut(.noSession).steerReason, SessionCopy.sessionHasEndedPlease)
    }

    func testAPayloadWithNoCallIsReportedNotDropped() async {
        let rig = await SteerRig()
        var payload = Self.payload(DeclineSteerNotification.callBackToday)
        payload[PushPayload.keyCallId] = " "

        await rig.handler.handleNotificationResponse(payload)

        XCTAssertTrue(rig.log.all.isEmpty)
        XCTAssertEqual(rig.reporter.steerReports.first?.failure, .unreadablePayload)
        XCTAssertEqual(MessageActionFailure.unreadablePayload.steerReason, CallsCopy.callNotAvailable)
    }

    func testTheFailureNotificationSaysWhatWasNotSent() {
        XCTAssertEqual(IncomingCallCopy.steerNotSent, "Not sent to the assistant")
        XCTAssertEqual(
            IncomingCallCopy.steerFailureBody("The call has ended.", "Ask what the call is about."),
            "The call has ended.\n\nYour instruction: Ask what the call is about."
        )
    }

    // MARK: - Helpers

    private static func sender(steer: RecordingSteerPoster) -> IncomingCallDeclineSender {
        IncomingCallDeclineSender(send: { _, _ in .success(()) }, backgroundTasks: FakeBackgroundTasks(), steer: steer)
    }

    /// What ``IncomingCallModel`` does with the reducer's commands, for the one that matters.
    private func dispatch(_ commands: [IncomingCallCommand], to sender: IncomingCallDeclineSender) async {
        for command in commands {
            if case let .requestDecline(workspace, call) = command {
                _ = await sender.decline(workspace: workspace, call: call).value
            }
        }
    }

    private func ringing() -> IncomingCallController {
        var controller = IncomingCallController()
        controller.handle(.ringing(workspace: workspace, call: call, atMilliseconds: 1000))
        return controller
    }

    private static func payload(_ action: String, text: String? = nil) -> [String: String] {
        var payload = [
            PushPayload.keyType: PushPayload.typeIncomingCall,
            PushPayload.keyWorkspaceId: "ws_1",
            PushPayload.keyCallId: "call_1",
            MessageNotificationAction.identifierKey: action,
        ]
        payload[MessageNotificationAction.replyTextKey] = text
        return payload
    }
}

/// Counts the steer notifications a decline posts.
@MainActor
final class RecordingSteerPoster: DeclineSteerPosting {
    struct Post: Equatable {
        let workspaceId: String
        let callId: String
    }

    private(set) var posts: [Post] = []

    func post(workspaceId: String, callId: String) {
        posts.append(Post(workspaceId: workspaceId, callId: callId))
    }
}

/// The handler with real credential wiring and fake edges, as in `NotificationActionHandlerTests`.
@MainActor
private struct SteerRig {
    let log: ActionEventLog
    let reporter: RecordingFailureReporter
    let tasks: FakeBackgroundTasks
    let transport: InboxActionTransport
    let handler: NotificationActionHandler

    init(signedIn: Bool = true, writeStatus: Int = 200, writeBody: String? = nil) async {
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
        let transport = InboxActionTransport(log: log, writeStatus: writeStatus, writeBody: writeBody)
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
