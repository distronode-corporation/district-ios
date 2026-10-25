@testable import DistrictAI
import DistrictCall
import DistrictModel
import Foundation
import XCTest

/// A person's decline is sent, once, and nothing else is (3.2, round 2's W2).
///
/// ⚠️ THE CHOICES RUN THROUGH THE REAL REDUCER (`IncomingCallController`, district-core-swift),
/// so these tests fail if the app feeds a ring that nobody saw into the event that reports a
/// decline, which would tell the caller a person refused them.
@MainActor
final class IncomingCallDeclineTests: XCTestCase {
    private let workspace = WorkspaceID("ws_1")
    private let call = CallID("call_1")

    // MARK: - Which event each ending feeds

    /// ⛔ THE OS'S END ACTION WHILE RINGING IS A PERSON'S DECLINE (lock screen, watch, headset,
    /// car), and it is sent exactly once.
    func testTheSystemEndWhileRingingIsADeclineThatIsSent() {
        var controller = ringing()
        let commands = controller.handle(IncomingCallEnding.systemEnd(in: controller.state.phase))
        XCTAssertEqual(declines(in: commands), [.requestDecline(workspace: workspace, call: call)])
        XCTAssertEqual(commands.last, .requestDecline(workspace: workspace, call: call), "the request goes last")
        XCTAssertEqual(controller.state.phase, .ended(.declined))
        // A second end on an ended call sends nothing more.
        XCTAssertEqual(declines(in: controller.handle(IncomingCallEnding.systemEnd(in: controller.state.phase))), [])
    }

    func testTheSystemEndAfterTheAnswerIsAHangUp() {
        XCTAssertEqual(IncomingCallEnding.systemEnd(in: .ringing), .declinePressed)
        XCTAssertEqual(IncomingCallEnding.systemEnd(in: .answering), .hangUpPressed)
        XCTAssertEqual(IncomingCallEnding.systemEnd(in: .idle), .hangUpPressed)
    }

    /// ⛔ NO SESSION IS A WITHDRAWAL: the ring ends as a decline would, and nothing is sent.
    func testARingEndedForNoSessionSendsNothing() {
        XCTAssertEqual(IncomingCallEnding.noSession, .withdrawnLocally)
        var controller = ringing()
        let commands = controller.handle(IncomingCallEnding.noSession)
        XCTAssertEqual(declines(in: commands), [])
        XCTAssertTrue(commands.contains(.reportCallEnded), "the ring still ends")
        XCTAssertEqual(controller.state.phase, .ended(.declined))
    }

    func testATimeoutSendsNothing() {
        var controller = ringing()
        XCTAssertEqual(declines(in: controller.handle(.ringTimedOut)), [])
    }

    // MARK: - The send

    func testADeclineIsSentOnceInsideABackgroundTask() async {
        let tasks = FakeBackgroundTasks()
        let route = DeclineRoute(answer: .success(()))
        let sender = IncomingCallDeclineSender(send: route.send, backgroundTasks: tasks, steer: RecordingSteerPoster())

        let sending = sender.decline(workspace: workspace, call: call)
        XCTAssertEqual(tasks.begun.count, 1, "the lease is held before the request starts")
        XCTAssertEqual(tasks.ended, [])
        let outcome = await sending.value

        XCTAssertNoThrow(try outcome.get())
        XCTAssertEqual(route.asked, [DeclineRoute.Ask(callId: "call_1", workspaceId: "ws_1")])
        XCTAssertEqual(tasks.ended, tasks.begun)
    }

    /// ⛔ NEVER RETRIED: a refusal or an offline handset is one request, and the lease still ends.
    func testAFailedDeclineIsNotRetried() async {
        for failure in [ApiError.transport("offline"), .http(status: 404, message: nil, code: "call_not_found")] {
            let tasks = FakeBackgroundTasks()
            let route = DeclineRoute(answer: .failure(failure))
            let sender = IncomingCallDeclineSender(
                send: route.send,
                backgroundTasks: tasks,
                steer: RecordingSteerPoster()
            )

            let outcome = await sender.decline(workspace: workspace, call: call).value

            guard case let .failure(error) = outcome else { return XCTFail("\(failure) must stay a failure") }
            XCTAssertEqual(error, failure)
            XCTAssertEqual(route.asked.count, 1, "\(failure)")
            XCTAssertEqual(tasks.ended, tasks.begun, "\(failure)")
        }
    }

    /// The system taking the time back ends the lease once; the request still finishes.
    func testAnExpiredLeaseEndsOnce() async {
        let tasks = FakeBackgroundTasks()
        let route = DeclineRoute(answer: .success(()))
        let sender = IncomingCallDeclineSender(send: route.send, backgroundTasks: tasks, steer: RecordingSteerPoster())

        let sending = sender.decline(workspace: workspace, call: call)
        tasks.expireAll()
        _ = await sending.value

        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertEqual(route.asked.count, 1)
    }

    // MARK: - Helpers

    private func ringing() -> IncomingCallController {
        var controller = IncomingCallController()
        controller.handle(.ringing(workspace: workspace, call: call, atMilliseconds: 1000))
        XCTAssertEqual(controller.state.phase, .ringing)
        return controller
    }

    private func declines(in commands: [IncomingCallCommand]) -> [IncomingCallCommand] {
        commands.filter {
            if case .requestDecline = $0 {
                return true
            }
            return false
        }
    }
}

/// Records every decline and answers one canned result.
private final class DeclineRoute: @unchecked Sendable {
    struct Ask: Equatable {
        let callId: String
        let workspaceId: String
    }

    private let lock = NSLock()
    private let answer: Result<Void, ApiError>
    private var log: [Ask] = []

    init(answer: Result<Void, ApiError>) {
        self.answer = answer
    }

    var asked: [Ask] {
        lock.withLock { log }
    }

    var send: IncomingCallDeclineSender.Send {
        { [self] callId, workspaceId in
            lock.withLock { log.append(Ask(callId: callId, workspaceId: workspaceId)) }
            return answer
        }
    }
}
