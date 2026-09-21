@testable import DistrictCall
import XCTest

/// The ring bound, on an injected clock and with no sleeping task anywhere.
final class IncomingCallRingTimeoutTests: XCTestCase {
    func testTheLocalBoundIsLongerThanTheServersRendezvous() {
        // ⛔ The rendezvous expires at 25s and this waits 30. Timing out FIRST
        // would take the Answer button away while the server was still willing to
        // accept one, which is the ordering that turns a slow thumb into a missed
        // call.
        XCTAssertGreaterThan(IncomingCallController.ringTimeoutMilliseconds, 25000)
        XCTAssertEqual(30000, IncomingCallController.ringTimeoutMilliseconds)
    }

    func testTheRingExpiresOnTheBoundAndNotOneMillisecondEarlier() {
        let state = IncomingCallController.inRinging().state
        let bound = IncomingCallController.ringTimeoutMilliseconds

        XCTAssertFalse(state.ringHasExpired(atMilliseconds: testRingStart))
        XCTAssertFalse(state.ringHasExpired(atMilliseconds: testRingStart + bound - 1))
        XCTAssertTrue(state.ringHasExpired(atMilliseconds: testRingStart + bound))
        XCTAssertTrue(state.ringHasExpired(atMilliseconds: testRingStart + bound * 10))
    }

    func testTheTimeoutCannotFireOnceTheCallWasAnswered() {
        // ⛔ Left live it would tear down a conversation thirty seconds in, for no
        // reason the user could observe. The driver cancels its timer; this is the
        // second half, because a cancelled timer is a promise and this is a fact.
        let answering = IncomingCallController.inAnswering().state
        let live = IncomingCallController.inCall().state
        let ended = IncomingCallController.inEnded().state
        let far = testRingStart + IncomingCallController.ringTimeoutMilliseconds * 2

        XCTAssertFalse(answering.ringHasExpired(atMilliseconds: far))
        XCTAssertFalse(live.ringHasExpired(atMilliseconds: far))
        XCTAssertFalse(ended.ringHasExpired(atMilliseconds: far))
        XCTAssertFalse(IncomingCallState().ringHasExpired(atMilliseconds: far))
    }

    func testARingWithNoRecordedStartNeverExpires() {
        // ⚠️ UNREACHABLE THROUGH ANY EVENT — the phase and the timestamp are set
        // by the same transition — so this drives the state directly. Failing
        // OPEN here is the deliberate direction: a missing timestamp must leave
        // the Answer button live rather than cancel a call that is ringing.
        var state = IncomingCallController.inRinging().state
        state.ringStartedAtMilliseconds = nil

        XCTAssertFalse(state.ringHasExpired(atMilliseconds: testRingStart + 10 * 60 * 1000))
    }
}

/// The defensive guards, driven directly because no event sequence can reach
/// them.
///
/// ⛔ THEY ARE PROOFS RATHER THAN COMMENTS. Each one asserts a state the machine
/// cannot produce today, so that a future transition which produces it fails
/// safe instead of crashing or issuing a command against something that is not
/// there.
final class IncomingCallGuardTests: XCTestCase {
    func testAnsweringACallWithNoIdsIssuesNoRequest() {
        var state = IncomingCallController.inRinging().state
        state.workspaceID = nil

        let outcome = IncomingCallController.reduce(state, .answerPressed)
        XCTAssertEqual([], outcome.commands)
        XCTAssertEqual(.ringing, outcome.state.phase, "no request went out, so nothing was answered")

        state = IncomingCallController.inRinging().state
        state.callID = nil
        XCTAssertEqual([], IncomingCallController.reduce(state, .answerPressed).commands)
    }

    func testTheTogglesAreNoOpsWhenNoMediaExists() {
        // ⚠️ Reachable in spirit if not in fact: the controls belong to the
        // in-call surface, but a recomposition can invoke a handler against a
        // call that has since ended. Doing nothing is correct; throwing would
        // crash the process over a stale tap.
        var state = IncomingCallController.inCall().state
        state.media = nil

        XCTAssertEqual([], IncomingCallController.reduce(state, .muteToggled).commands)
        XCTAssertEqual([], IncomingCallController.reduce(state, .speakerToggled).commands)
        XCTAssertEqual(state, IncomingCallController.reduce(state, .speakerToggled).state)
    }

    func testTogglesReachTheEngineOnceACallIsConnected() {
        var controller = IncomingCallController.inCall()
        XCTAssertEqual([.engine(.setMuted(true))], controller.handle(.muteToggled))
        XCTAssertEqual([.engine(.setSpeakerphone(true))], controller.handle(.speakerToggled))
        XCTAssertEqual(true, controller.state.media?.speakerRequested)

        controller.handle(.engine(.microphoneChanged(enabled: false)))
        XCTAssertEqual([.engine(.setMuted(false))], controller.handle(.muteToggled))
    }
}
