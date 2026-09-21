@testable import DistrictCall
import DistrictModel
import Foundation
import XCTest

/// The outbound state machine, walked the way a call walks it.
final class SoftphoneSessionTests: XCTestCase {
    func testAFreshSessionIsIdleAndRemembersTheNumberAsTyped() {
        let session = SoftphoneSession(number: testNumber)
        XCTAssertEqual(.idle, session.state.phase)
        XCTAssertEqual(testNumber, session.state.number)
        XCTAssertFalse(session.state.answered)
    }

    func testTheHappyPathWalksIdleToConnectedAndConnectsExactlyOnce() {
        var session = SoftphoneSession(number: testNumber)

        XCTAssertEqual([], session.handle(.dialRequested))
        XCTAssertEqual(.dialing, session.state.phase)

        let joining = session.handle(
            .dialAccepted(url: testDialURL, token: testDialToken, callId: testDialCallId)
        )
        // ⛔ BOTH HALVES VERBATIM. The room exists only on the TRUNK's
        // deployment, so a derived URL joins a bus that has never heard of it.
        XCTAssertEqual([.engine(.connect(url: testDialURL, token: testDialToken))], joining)
        XCTAssertEqual(.connecting, session.state.phase)
        // ⛔ THE ID IS RECORDED HERE AND NOWHERE EARLIER, which is the whole
        // asymmetry: every exit from this point on can reach the carrier, and no
        // exit before it can. See `SoftphoneServerLeg.swift`.
        XCTAssertEqual(testDialCallId, session.state.callId)
        XCTAssertFalse(session.state.serverHangUpRequested)

        // ⛔ IN THE ROOM IS NOT ON THE PHONE. The dial route returns as soon as
        // the carrier accepts, so this is ring-back, not conversation.
        let inRoom = session.handle(.engine(.connected))
        XCTAssertEqual([.engine(.setMuted(false))], inRoom)
        XCTAssertEqual(.ringing, session.state.phase)
        XCTAssertFalse(session.state.answered)

        XCTAssertEqual([], session.handle(.engine(.participantJoined(testCallee))))
        XCTAssertEqual(.connected, session.state.phase)
        XCTAssertTrue(session.state.answered)
    }

    func testTheDurationCountsFromTheAnswerAndNotFromTheDial() {
        // ⛔ THE OPERATOR WILL COMPARE THIS TO AN INVOICE. The platform bills
        // answered time; counting the ring would overstate every call.
        var session = SoftphoneSession.inRinging()
        session.handle(.tick)
        session.handle(.tick)
        XCTAssertEqual(0, session.state.media.elapsedSeconds, "a tick while ringing counts nothing")

        session.handle(.engine(.participantJoined(testCallee)))
        session.handle(.tick)
        session.handle(.tick)
        session.handle(.tick)
        XCTAssertEqual(3, session.state.media.elapsedSeconds)
    }

    func testAnEmptyingRoomAfterTheAnswerIsTheCalleeHangingUp() {
        var session = SoftphoneSession.inConnected()
        session.handle(.tick)

        let hangUp = session.handle(.engine(.participantLeft(testCallee)))
        // ⛔ THE CARRIER REQUEST IS ON THIS ENDING TOO, EVEN THOUGH THE FAR END IS
        // WHAT LEFT. "The room emptied" is a statement about the SFU, not about the
        // telephone: the route answers `{ended: false}` for free if the leg really
        // is down, and guessing wrongly the other way is a bill.
        XCTAssertEqual([.reportCallEnded, .engine(.disconnect), testServerHangUp], hangUp)
        XCTAssertEqual(.ended(.remoteHungUp), session.state.phase)
        // ⛔ THE LATCH SURVIVES THE END. It is what says the frozen duration is a
        // billed length rather than a zero.
        XCTAssertTrue(session.state.answered)
        XCTAssertEqual(1, session.state.media.elapsedSeconds)
    }

    func testALeaveThatStillLeavesSomeoneInTheRoomDoesNotEndTheCall() {
        var session = SoftphoneSession.inConnected()
        session.handle(.engine(.participantJoined(CallParticipant(identity: "user-2"))))

        XCTAssertEqual([], session.handle(.engine(.participantLeft(testCallee))))
        XCTAssertEqual(.connected, session.state.phase)
        XCTAssertEqual(1, session.state.media.remoteParticipants)
    }

    func testALeaveBeforeTheAnswerIsNotAnAnswerAndNotAnEnding() {
        // ⚠️ A leave for a join this client never saw. The count floors at zero
        // and the phase does not move: nobody has picked up.
        var session = SoftphoneSession.inRinging()
        XCTAssertEqual([], session.handle(.engine(.participantLeft(testCallee))))
        XCTAssertEqual(.ringing, session.state.phase)
        XCTAssertFalse(session.state.answered)
    }

    func testReconnectingIsABannerOverALiveCallAndNeverAPhase() {
        // ⚠️ A phone handing over between wifi and its radio reconnects
        // routinely, and the SDK resumes by itself. Treating it as a failure
        // would hang up calls that were about to survive.
        var session = SoftphoneSession.inConnected()
        session.handle(.engine(.reconnecting))
        XCTAssertEqual(.connected, session.state.phase)
        XCTAssertTrue(session.state.media.reconnecting)

        session.handle(.engine(.connected))
        XCTAssertEqual(.connected, session.state.phase)
        XCTAssertFalse(session.state.media.reconnecting)
    }

    func testARefusedDialProducedNoCallSoItReturnsToTheKeypad() {
        // ⛔ NOT AN ENDED CALL. A refusal is shown on the keypad because there is
        // no call to show it over, and an ended phase here would draw a summary
        // for a call that never happened.
        var session = SoftphoneSession.inDialing()
        XCTAssertEqual([.reportCallEnded], session.handle(.dialRefused))
        XCTAssertEqual(.idle, session.state.phase)
    }

    func testARefusedDialStillTellsTheOSTheCallIsOver() {
        // ⛔ THE TWO HALVES OF "no call was placed" DISAGREE, AND ONLY ONE OF THEM
        // IS ABOUT THE CARRIER. A refusal is only reachable AFTER CallKit has
        // performed the `CXStartCallAction` that the dial request hangs off, so a
        // DNC hit, a 402, a dormant workspace and a handset that is simply offline
        // each leave the system holding a call. Nothing else on this path ever
        // ends it: the phase returns to `idle`, so there is no ``end(_:_:)`` to
        // carry the report, which is exactly how this went unnoticed.
        var session = SoftphoneSession.inDialing()
        XCTAssertEqual([.reportCallEnded], session.handle(.dialRefused))
        // ⚠️ AND NO DISCONNECT. No engine was ever built, so a disconnect here
        // would be a command ``CallStack/perform(_:)`` drops anyway.
        XCTAssertFalse(session.handle(.dialRefused).contains(.engine(.disconnect)))
    }

    func testAHangUpIsNotReportedBecauseTheOSPerformedItAlready() {
        // ⛔ REPORTING AN ENDING THE OS CARRIED OUT IS API MISUSE. Both producers
        // of `hangUpPressed` have put a `CXEndCallAction` through CallKit before
        // the reducer sees the event: the in-app button asks for one, and the lock
        // screen, CarPlay and a headset ARE one.
        for session in [SoftphoneSession.inConnecting(), .inRinging(), .inConnected()] {
            var subject = session
            let commands = subject.handle(.hangUpPressed)
            // ⚠️ THE CARRIER REQUEST IS PRESENT AND IS NOT WHAT THIS ASSERTS. The
            // property under test is the ABSENCE of ``SoftphoneCommand/reportCallEnded``;
            // the server saw none of these endings either way.
            XCTAssertEqual(
                [.engine(.disconnect), testServerHangUp],
                commands,
                "hang-up from \(session.state.phase)"
            )
        }
    }

    func testEveryEndingTheOSCouldNotSeeIsReportedToIt() {
        // ⛔ THE MEDIA LAYER IS INVISIBLE TO CALLKIT. The callee hanging up, the
        // room dropping and a join that failed are all reported by the SDK to this
        // app and to nobody else, so the report is the only thing that ends the
        // system's call. Its absence left CallKit believing every finished
        // outbound call was still live, and `maximumCallGroups = 1` then refuses
        // every later call in BOTH directions for the life of the process.
        var callee = SoftphoneSession.inConnected()
        XCTAssertEqual(
            [.reportCallEnded, .engine(.disconnect), testServerHangUp],
            callee.handle(.engine(.participantLeft(testCallee)))
        )

        var dropped = SoftphoneSession.inConnected()
        XCTAssertEqual(
            [.reportCallEnded, .engine(.disconnect), testServerHangUp],
            dropped.handle(.engine(.disconnected(reason: "sfu")))
        )

        var broken = SoftphoneSession.inConnecting()
        XCTAssertEqual(
            [.reportCallEnded, .engine(.disconnect), testServerHangUp],
            broken.handle(.engine(.failed(message: "no route")))
        )
    }

    func testHungUpLocallyIsTheONLYReasonThatSkipsTheReport() {
        // ⛔ THE DIVIDING LINE, ASSERTED OVER THE WHOLE VOCABULARY RATHER THAN OVER
        // THE REACHABLE HALF OF IT. Four of these belong to the inbound machine and
        // cannot occur on an outbound call today; they are answered anyway so that
        // a NEW ``CallEndReason`` is a compile error in `exitCommands(for:)` rather
        // than an ending that is silently never reported.
        //
        // ⛔ AND THE ORDER IS PART OF IT. The report goes BEFORE the disconnect, so
        // the system's own call UI comes down as the call ends rather than after a
        // socket has finished closing, which is what ``IncomingCallController``
        // already does.
        //
        // ⚠️ AND ``SoftphoneCommand/requestServerHangUp(callId:)`` IS ABSENT FROM
        // ALL OF THEM, WHICH IS THE SHAPE RATHER THAN AN OMISSION. This helper
        // decides from the REASON alone, and whether the carrier leg is still ours
        // to end is a question about the STATE — the id, and whether it has already
        // been spent. ``SoftphoneSession/end(_:_:)`` appends it afterwards; see
        // `SoftphoneServerLegTests.swift`.
        for reason in Self.everyEndReason {
            var expected: [SoftphoneCommand] = [.reportCallEnded, .engine(.disconnect)]
            if reason == .hungUpLocally {
                expected = [.engine(.disconnect)]
            }
            XCTAssertEqual(expected, SoftphoneSession.exitCommands(for: reason), "exit for \(reason)")
        }
    }

    /// ⚠️ WRITTEN OUT RATHER THAN DERIVED. ``CallEndReason`` carries payloads, so
    /// it cannot be `CaseIterable`; this list is what makes the two assertions
    /// above total, and a case missing from it is the one thing they cannot catch.
    private static let everyEndReason: [CallEndReason] = [
        .hungUpLocally,
        .remoteHungUp,
        .remoteEnded(reason: "sfu"),
        .remoteEnded(reason: nil),
        .failed(message: "no route"),
        .failed(message: nil),
        .declined,
        .ringTimedOut,
        .callerCancelled,
        .answerRefused(message: "viewer"),
        .answerRefused(message: nil),
    ]

    func testTheDialCredentialIsReadStraightFromTheRoutesOwnBody() throws {
        // ⛔ A CREDENTIAL PAIR, NOT A DATA SHAPE. The row is written and the
        // carrier is dialling by the time this body exists, so there is no retry:
        // retrying places a SECOND call.
        let body = Data(
            """
            {"success":true,"callId":"CA1","roomName":"direct_CA1","token":"t","url":"wss://x"}
            """.utf8
        )
        let response = try JSONDecoder().decode(DialResponse.self, from: body)

        // ⛔ THREE FIELDS, AND `callId` IS THE ONE THAT MATTERS MOST. It is the
        // only handle this client will ever have on the
        // carrier leg; `roomName` and `success` stay out, which is what the
        // "credential pair, not a data shape" rule was for.
        XCTAssertEqual(
            .dialAccepted(url: "wss://x", token: "t", callId: "CA1"),
            SoftphoneEvent.dialAccepted(response)
        )
    }
}
