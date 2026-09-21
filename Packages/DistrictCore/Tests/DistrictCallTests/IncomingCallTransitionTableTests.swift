@testable import DistrictCall
import XCTest

/// One inbound phase, one event, and what it must produce. ⚠️ A struct rather
/// than a tuple; see ``SoftphoneRow``.
private struct IncomingRow {
    let event: IncomingCallEvent
    let phase: IncomingCallPhase
    let commands: [IncomingCallCommand]

    init(_ event: IncomingCallEvent, _ phase: IncomingCallPhase, _ commands: [IncomingCallCommand] = []) {
        self.event = event
        self.phase = phase
        self.commands = commands
    }
}

/// Every inbound phase against every event, legal and illegal.
///
/// ⚠️ EACH ROW RUNS AGAINST A FRESH COPY OF THE PHASE, because the controller is
/// a value.
final class IncomingCallTransitionTableTests: XCTestCase {
    private func assertTable(_ controller: IncomingCallController, _ rows: [IncomingRow]) {
        for row in rows {
            var subject = controller
            let produced = subject.handle(row.event)
            XCTAssertEqual(row.phase, subject.state.phase, "phase after \(row.event)")
            XCTAssertEqual(row.commands, produced, "commands after \(row.event)")
        }
    }

    /// The engine events that decide nothing on this side.
    ///
    /// ⛔ INCLUDING THE PARTICIPANT ONES, WHICH IS THE WHOLE REASON THIS IS NOT
    /// THE SOFTPHONE. An inbound call joins a room that ALREADY contains the
    /// caller and the AI, so participants are present from the first frame and a
    /// machine that latched on them would report "answered" before it had
    /// connected to anything.
    private static let inertEngineEvents: [IncomingCallEvent] = [
        .engine(.reconnecting),
        .engine(.participantJoined(testCallee)),
        .engine(.participantLeft(testCallee)),
        .engine(.audioRouteChanged(.bluetooth)),
        .engine(.microphoneChanged(enabled: false)),
    ]

    private static let secondCall = CallID("CA2")

    private static let secondPush = IncomingCallEvent.ringing(
        workspace: testWorkspace,
        call: secondCall,
        atMilliseconds: testRingStart + 1
    )

    private static let credential = IncomingCallEvent.answerJoinable(
        url: testAnswerURL,
        token: testAnswerToken
    )

    private static let quiet: [IncomingCallCommand] = [.stopRinging, .reportCallEnded]

    private static let loud: [IncomingCallCommand] = [.stopRinging, .reportCallEnded, .engine(.disconnect)]

    private static let live: [IncomingCallCommand] = [.engine(.setMuted(false)), .reportCallActive]

    func testIdleAnswersOnlyToAPush() {
        var rows: [IncomingRow] = [
            IncomingRow(Self.secondPush, .ringing, [.startRinging(workspace: testWorkspace, call: Self.secondCall)]),
            IncomingRow(.answerPressed, .idle),
            IncomingRow(Self.credential, .idle),
            IncomingRow(.answerRejected(.callerGone), .idle),
            IncomingRow(.declinePressed, .idle),
            IncomingRow(.ringTimedOut, .idle),
            IncomingRow(.hangUpPressed, .idle),
            IncomingRow(.dismissed, .idle),
            IncomingRow(.engine(.connected), .idle),
            IncomingRow(.engine(.failed(message: "x")), .idle),
            IncomingRow(.engine(.disconnected(reason: "x")), .idle),
            IncomingRow(.muteToggled, .idle),
            IncomingRow(.speakerToggled, .idle),
            IncomingRow(.tick, .idle),
        ]
        rows += Self.inertEngineEvents.map { IncomingRow($0, .idle) }
        assertTable(IncomingCallController(), rows)
    }

    func testRingingTakesAnswerDeclineOrTheBound() {
        let answering: [IncomingCallCommand] = [
            .stopRinging,
            .requestAnswer(workspace: testWorkspace, call: testCall),
        ]
        var rows: [IncomingRow] = [
            // ⛔ A second push is DROPPED, not queued and not a replacement.
            IncomingRow(Self.secondPush, .ringing),
            IncomingRow(.answerPressed, .answering, answering),
            IncomingRow(Self.credential, .ringing),
            IncomingRow(.answerRejected(.callerGone), .ringing),
            IncomingRow(.declinePressed, .ended(.declined), Self.quiet),
            IncomingRow(.ringTimedOut, .ended(.ringTimedOut), Self.quiet),
            IncomingRow(.hangUpPressed, .ended(.hungUpLocally), Self.quiet),
            // ⛔ A ringing call is not dismissible.
            IncomingRow(.dismissed, .ringing),
            IncomingRow(.engine(.connected), .ringing),
            IncomingRow(.engine(.failed(message: "x")), .ringing),
            IncomingRow(.engine(.disconnected(reason: "x")), .ringing),
            IncomingRow(.muteToggled, .ringing),
            IncomingRow(.speakerToggled, .ringing),
            IncomingRow(.tick, .ringing),
        ]
        rows += Self.inertEngineEvents.map { IncomingRow($0, .ringing) }
        assertTable(.inRinging(), rows)
    }

    func testAnsweringBeforeTheCredentialLandsClosesNothing() {
        // ⚠️ NO `.engine(.disconnect)` ANYWHERE HERE: no connect has been issued,
        // so there is no socket to close. That is `engineAttached` doing its job,
        // and it is also what keeps a decline and a timeout identical.
        var rows: [IncomingRow] = [
            IncomingRow(Self.secondPush, .answering),
            IncomingRow(.answerPressed, .answering),
            IncomingRow(Self.credential, .answering, [.engine(.connect(url: testAnswerURL, token: testAnswerToken))]),
            IncomingRow(.answerRejected(.callerGone), .ended(.callerCancelled), Self.quiet),
            IncomingRow(
                .answerRejected(.refused(message: "no")),
                .ended(.answerRefused(message: "no")),
                Self.quiet
            ),
            IncomingRow(.declinePressed, .ended(.hungUpLocally), Self.quiet),
            // ⛔ The bound does not fire after the press.
            IncomingRow(.ringTimedOut, .answering),
            IncomingRow(.hangUpPressed, .ended(.hungUpLocally), Self.quiet),
            IncomingRow(.dismissed, .answering),
            IncomingRow(.engine(.connected), .inCall, Self.live),
            IncomingRow(.engine(.failed(message: "x")), .ended(.failed(message: "x")), Self.quiet),
            IncomingRow(.engine(.disconnected(reason: "x")), .ended(.remoteEnded(reason: "x")), Self.quiet),
            IncomingRow(.muteToggled, .answering),
            IncomingRow(.speakerToggled, .answering),
            IncomingRow(.tick, .answering),
        ]
        rows += Self.inertEngineEvents.map { IncomingRow($0, .answering) }
        assertTable(.inAnswering(), rows)
    }

    func testAnsweringAfterTheJoinWasIssuedAlwaysClosesTheSocket() {
        let rows: [IncomingRow] = [
            IncomingRow(.answerRejected(.callerGone), .ended(.callerCancelled), Self.loud),
            IncomingRow(.declinePressed, .ended(.hungUpLocally), Self.loud),
            IncomingRow(.hangUpPressed, .ended(.hungUpLocally), Self.loud),
            IncomingRow(.engine(.failed(message: "x")), .ended(.failed(message: "x")), Self.loud),
            IncomingRow(.engine(.disconnected(reason: "x")), .ended(.remoteEnded(reason: "x")), Self.loud),
            IncomingRow(.engine(.connected), .inCall, Self.live),
            IncomingRow(.ringTimedOut, .answering),
            IncomingRow(.answerPressed, .answering),
        ]
        assertTable(.inJoining(), rows)
    }

    func testInCallCountsTimeAndEndsOnEveryTerminalPath() {
        var rows: [IncomingRow] = [
            IncomingRow(Self.secondPush, .inCall),
            IncomingRow(.answerPressed, .inCall),
            IncomingRow(Self.credential, .inCall),
            IncomingRow(.answerRejected(.callerGone), .inCall),
            IncomingRow(.declinePressed, .ended(.hungUpLocally), Self.loud),
            IncomingRow(.ringTimedOut, .inCall),
            IncomingRow(.hangUpPressed, .ended(.hungUpLocally), Self.loud),
            IncomingRow(.dismissed, .inCall),
            IncomingRow(.engine(.connected), .inCall),
            IncomingRow(.engine(.failed(message: "x")), .ended(.failed(message: "x")), Self.loud),
            IncomingRow(.engine(.disconnected(reason: "x")), .ended(.remoteEnded(reason: "x")), Self.loud),
            IncomingRow(.muteToggled, .inCall, [.engine(.setMuted(true))]),
            IncomingRow(.speakerToggled, .inCall, [.engine(.setSpeakerphone(true))]),
            IncomingRow(.tick, .inCall),
        ]
        rows += Self.inertEngineEvents.map { IncomingRow($0, .inCall) }
        assertTable(.inCall(), rows)
    }

    func testEndedAbsorbsEverythingExceptTheDismissal() {
        // ⛔ WHICH IS WHAT MAKES THE DISCONNECT EXACTLY ONCE. A late engine event,
        // a second hang-up and an OS end-call callback that arrives after the
        // fact all cost no command.
        let ended = IncomingCallPhase.ended(.hungUpLocally)
        var rows: [IncomingRow] = [
            IncomingRow(Self.secondPush, ended),
            IncomingRow(.answerPressed, ended),
            IncomingRow(Self.credential, ended),
            IncomingRow(.answerRejected(.callerGone), ended),
            IncomingRow(.declinePressed, ended),
            IncomingRow(.ringTimedOut, ended),
            IncomingRow(.hangUpPressed, ended),
            IncomingRow(.dismissed, .idle),
            IncomingRow(.engine(.connected), ended),
            IncomingRow(.engine(.failed(message: "x")), ended),
            IncomingRow(.engine(.disconnected(reason: "x")), ended),
            IncomingRow(.muteToggled, ended),
            IncomingRow(.speakerToggled, ended),
            IncomingRow(.tick, ended),
        ]
        rows += Self.inertEngineEvents.map { IncomingRow($0, ended) }
        assertTable(.inEnded(), rows)
    }
}
