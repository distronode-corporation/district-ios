@testable import DistrictCall
import XCTest

/// The inbound state machine: ring, answer, decline, time out.
///
/// ⛔ THE MOST IMPORTANT ASSERTIONS IN THIS FILE ARE THAT **NOTHING IS SENT** ON A
/// DECLINE AND ON A TIMEOUT. `actions/ring-app` blocks on a Redis rendezvous for
/// about 25 seconds and falls back to PSTN when it expires, so the server already
/// has everything it needs from the ABSENCE of an answer. Reporting a decline
/// would make a deliberate refusal distinguishable from a phone in a pocket, and
/// there is no version of that distinction the product wants.
final class IncomingCallControllerTests: XCTestCase {
    func testAPushRingsTheOSAndTheNotificationShadeTogether() {
        var controller = IncomingCallController()
        let commands = controller.handle(
            .ringing(workspace: testWorkspace, call: testCall, atMilliseconds: testRingStart)
        )

        XCTAssertEqual([.startRinging(workspace: testWorkspace, call: testCall)], commands)
        XCTAssertEqual(.ringing, controller.state.phase)
        XCTAssertEqual(testWorkspace, controller.state.workspaceID)
        XCTAssertEqual(testCall, controller.state.callID)
        // ⚠️ NO DURATION YET. The media state stays nil until media is up, which
        // is what stops a ringing screen drawing a timer.
        XCTAssertNil(controller.state.media)
    }

    func testASecondPushWhileOneIsLiveIsDroppedNotQueuedAndNotAReplacement() {
        // ⛔ ONE ENGINE, ONE AUDIO FOCUS. A replacement would tear down a
        // conversation the user is having in order to ring them about another;
        // the dropped call still reaches the server's timeout and falls back to
        // PSTN, which is the right outcome for someone already on the phone.
        var controller = IncomingCallController.inRinging()
        let commands = controller.handle(
            .ringing(workspace: testWorkspace, call: CallID("CA2"), atMilliseconds: testRingStart + 1)
        )

        XCTAssertEqual([], commands)
        XCTAssertEqual(testCall, controller.state.callID)
        XCTAssertEqual(testRingStart, controller.state.ringStartedAtMilliseconds)
    }

    func testDecliningAndTimingOutEmitByteIdenticalCommandLists() {
        // ⛔ THE PRIVACY PROPERTY, ASSERTED RATHER THAN DESCRIBED. An unanswered
        // ring and a declined one must look identical from outside. The local
        // reason differs so the phone's own screen can be honest; nothing this
        // device transmits does.
        var declined = IncomingCallController.inRinging()
        var timedOut = IncomingCallController.inRinging()

        let declineCommands = declined.handle(.declinePressed)
        let timeoutCommands = timedOut.handle(.ringTimedOut)

        XCTAssertEqual(declineCommands, timeoutCommands)
        XCTAssertEqual([.stopRinging, .reportCallEnded], declineCommands)
        XCTAssertFalse(declineCommands.contains(.requestAnswer(workspace: testWorkspace, call: testCall)))
        XCTAssertEqual(.ended(.declined), declined.state.phase)
        XCTAssertEqual(.ended(.ringTimedOut), timedOut.state.phase)
    }

    func testTheRingNotificationGoesAwayAtThePressBeforeTheRoundTrip() {
        // ⛔ AT THE PRESS, NOT AT THE CONNECT. Leaving it up during the round trip
        // leaves an Answer/Decline pair on screen for a call that is already
        // being joined, and the notification is deliberately not swipeable.
        var controller = IncomingCallController.inRinging()
        let commands = controller.handle(.answerPressed)

        XCTAssertEqual([.stopRinging, .requestAnswer(workspace: testWorkspace, call: testCall)], commands)
        XCTAssertEqual(.answering, controller.state.phase)
    }

    func testASecondAnswerWhileTheFirstIsInFlightIsDropped() {
        // ⚠️ The notification's button, the on-screen button and a car head unit
        // can all fire, and the OS can deliver one twice. A second round trip
        // would write the server's rendezvous again for a call already joining.
        var controller = IncomingCallController.inRinging()
        controller.handle(.answerPressed)

        XCTAssertEqual([], controller.handle(.answerPressed))
        XCTAssertEqual(.answering, controller.state.phase)
    }

    func testTheOSIsToldTheCallIsActiveOnlyAfterMediaIsUp() {
        // ⛔ Marking it active on the press starts the OS's own duration counter
        // early and, on a failed join, leaves the user looking at a connected
        // call with no audio.
        var controller = IncomingCallController.inAnswering()

        let joining = controller.handle(.answerJoinable(url: testAnswerURL, token: testAnswerToken))
        XCTAssertEqual([.engine(.connect(url: testAnswerURL, token: testAnswerToken))], joining)
        XCTAssertEqual(.answering, controller.state.phase, "not connected until media says so")
        XCTAssertNil(controller.state.media)

        let live = controller.handle(.engine(.connected))
        XCTAssertEqual([.engine(.setMuted(false)), .reportCallActive], live)
        XCTAssertEqual(.inCall, controller.state.phase)
        XCTAssertNotNil(controller.state.media)
    }

    func testAFailedJoinEndsTheCallAndClosesTheSocketItOpened() {
        // ⛔ `engineAttached` IS WHY THE DISCONNECT IS HERE. `media` is still nil
        // at this point, so a check on that would leave the engine holding a
        // socket nobody told it to release.
        var controller = IncomingCallController.inJoining()
        let commands = controller.handle(.engine(.failed(message: "no route to host")))

        XCTAssertEqual([.stopRinging, .reportCallEnded, .engine(.disconnect)], commands)
        XCTAssertEqual(.ended(.failed(message: "no route to host")), controller.state.phase)
    }

    func testACallerWhoHungUpWhileThePhoneRangIsNotReportedAsAnError() {
        // ⚠️ The overwhelmingly common way to reach this is that the caller hung
        // up between the phone ringing and a thumb arriving.
        var controller = IncomingCallController.inAnswering()
        let commands = controller.handle(.answerRejected(.callerGone))

        XCTAssertEqual([.stopRinging, .reportCallEnded], commands, "no engine was ever attached")
        XCTAssertEqual(.ended(.callerCancelled), controller.state.phase)
    }

    func testAViewersRefusalEndsTheCallWithTheServersMessage() {
        // ⛔ A VIEWER'S PHONE GENUINELY RINGS: the ring is fanned out to every
        // registered device in the workspace without consulting roles.
        var controller = IncomingCallController.inAnswering()
        controller.handle(.answerRejected(.refused(message: "Forbidden")))

        XCTAssertEqual(.ended(.answerRefused(message: "Forbidden")), controller.state.phase)
    }

    func testTheDurationRunsFromMediaRatherThanFromThePress() {
        // ⛔ The platform bills answered time; counting from the press would
        // include the answer round trip and the join.
        var controller = IncomingCallController.inAnswering()
        controller.handle(.tick)
        XCTAssertNil(controller.state.media)

        controller.handle(.answerJoinable(url: testAnswerURL, token: testAnswerToken))
        controller.handle(.engine(.connected))
        controller.handle(.tick)
        controller.handle(.tick)
        XCTAssertEqual(2, controller.state.media?.elapsedSeconds)
    }

    func testEndedIsAStateTheUserLeavesRatherThanOneThatExpires() {
        // ⛔ A call that vanished on hang-up would answer "how long was that"
        // with nothing.
        var ringing = IncomingCallController.inRinging()
        XCTAssertEqual([], ringing.handle(.dismissed))
        XCTAssertEqual(.ringing, ringing.state.phase, "a ringing call is not dismissible")

        var controller = IncomingCallController.inEnded()
        XCTAssertEqual([], controller.handle(.dismissed))
        XCTAssertEqual(IncomingCallState(), controller.state)
    }
}
