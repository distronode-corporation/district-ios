@testable import DistrictCall
import DistrictModel
import XCTest

/// The half of an ending that reaches the CARRIER.
///
/// ⛔ THE DEFECT GUARDED: ending a direct softphone call with `Room.disconnect()`
/// and nothing else removes this device from the room and leaves the SIP
/// participant in it. The telephone at the far end goes on ringing or talking to an
/// empty room, and the carrier goes on billing — a call ended in under a second can
/// bill roughly 90 seconds. Nothing throws, nothing logs, and every screen says the
/// call is over.
///
/// ⛔ THE HARD CASE IS AN ORDERING AND IT IS THE COMMON ONE, WHICH IS WHY IT GETS
/// THE MOST TESTS HERE. `calls/dial` instructs the carrier BEFORE it answers, so a
/// response still in flight may already be ringing somebody; an operator who
/// mis-dials hangs up in well under a second (`CXEndCallAction` at +0.7s, the leg
/// placed at +3s is a realistic ordering). In that window the session is already
/// ended and the `callId` does not exist yet.
/// One ending, and the phase it is reached from.
///
/// ⚠️ A STRUCT RATHER THAN A TUPLE because SwiftLint caps a tuple at two members,
/// which is the same call `SoftphoneTransitionTableTests.swift` records for its own
/// row type.
private struct Ending {
    let label: String
    let event: SoftphoneEvent
    let session: SoftphoneSession

    init(_ label: String, _ event: SoftphoneEvent, _ session: SoftphoneSession) {
        self.label = label
        self.event = event
        self.session = session
    }
}

final class SoftphoneServerLegTests: XCTestCase {
    // MARK: - The ordering the defect lives in

    /// ⛔ A HANG-UP WHILE `dialing` CANNOT REACH THE CARRIER, AND MUST NOT PRETEND
    /// TO. There is no id yet. This asserts the honest half of the window; the test
    /// below asserts what closes it.
    func testAHangUpBeforeTheCredentialArrivesAsksTheServerForNothingYet() {
        var session = SoftphoneSession.inDialing()

        let commands = session.handle(.hangUpPressed)

        XCTAssertEqual([.engine(.disconnect)], commands)
        XCTAssertNil(session.state.callId)
        XCTAssertFalse(session.state.serverHangUpRequested)
    }

    /// 🔑 THE WHOLE POINT OF THE DESIGN. The credential lands after the call is
    /// over, carrying the only handle on a telephone that is already ringing, and
    /// the terminal phase absorbs it for every purpose but this one.
    func testACredentialArrivingAfterTheOperatorHungUpStillEndsTheCarrierLeg() {
        var session = SoftphoneSession.inDialing()
        session.handle(.hangUpPressed)

        let late = session.handle(
            .dialAccepted(url: testDialURL, token: testDialToken, callId: testDialCallId)
        )

        XCTAssertEqual([testServerHangUp], late)
        // ⛔ AND NOTHING ELSE. A `connect` here would join a room to hang it up,
        // which is slower and is a live microphone on a call nobody is on.
        XCTAssertFalse(late.contains(.engine(.connect(url: testDialURL, token: testDialToken))))
        // ⛔ THE PHASE DOES NOT MOVE. The operator is looking at a summary.
        XCTAssertEqual(.ended(.hungUpLocally), session.state.phase)
        XCTAssertEqual(testDialCallId, session.state.callId)
    }

    /// ⛔ EXACTLY ONCE ACROSS THE TWO EXITS. A redelivered credential is the cheap
    /// way to place a second request for a call that has one already.
    func testASecondLateCredentialAsksTheServerNothingFurther() {
        var session = SoftphoneSession.inDialing()
        session.handle(.hangUpPressed)
        let credential = SoftphoneEvent.dialAccepted(
            url: testDialURL,
            token: testDialToken,
            callId: testDialCallId
        )
        XCTAssertEqual([testServerHangUp], session.handle(credential))

        XCTAssertEqual([], session.handle(credential))
        XCTAssertTrue(session.state.serverHangUpRequested)
    }

    /// ⛔ THE MIRROR ORDERING: the ending already knew the id, so it spent it, and a
    /// credential redelivered afterwards must not spend it again.
    func testAnEndingThatAlreadySpentTheIdIgnoresALaterCredential() {
        var session = SoftphoneSession.inConnecting()
        XCTAssertEqual([.engine(.disconnect), testServerHangUp], session.handle(.hangUpPressed))

        let late = session.handle(
            .dialAccepted(url: testDialURL, token: testDialToken, callId: testDialCallId)
        )

        XCTAssertEqual([], late)
    }

    /// ⚠️ THE ID IS RECORDED EVEN WHEN THE LATCH IS SHUT. Nothing reads it on that
    /// path today; a state that knows the call's id is strictly more truthful than
    /// one whose value depends on which of two orderings happened.
    func testALatchedLateCredentialStillRecordsTheId() {
        var session = SoftphoneSession.inDialing()
        session.handle(.hangUpPressed)
        session.handle(.dialAccepted(url: testDialURL, token: testDialToken, callId: "CA1"))

        session.handle(.dialAccepted(url: testDialURL, token: testDialToken, callId: "CA2"))

        XCTAssertEqual("CA2", session.state.callId)
    }

    // MARK: - Which endings spend it

    /// ⛔ EVERY ENDING, NOT ONLY THE LOCAL ONES, AND THE SPLIT THAT GOVERNS
    /// ``SoftphoneCommand/reportCallEnded`` DOES NOT APPLY HERE. That one is split
    /// on whether CallKit performed the ending itself; the SERVER performed none of
    /// them. `remoteHungUp` is the one case where the leg may genuinely be down
    /// already, and the route answers `{ended: false}` for that at no cost —
    /// whereas `failed` and `remoteEnded` mean OUR socket died, which says nothing
    /// at all about the telephone.
    func testEveryEndingWithAKnownIdAsksTheServerToEndTheLeg() {
        let endings: [Ending] = [
            Ending("operator hang-up", .hangUpPressed, .inConnected()),
            Ending("callee left the room", .engine(.participantLeft(testCallee)), .inConnected()),
            Ending("media failed", .engine(.failed(message: "no route")), .inConnecting()),
            Ending("socket dropped", .engine(.disconnected(reason: "sfu")), .inRinging()),
        ]

        for ending in endings {
            var subject = ending.session
            let commands = subject.handle(ending.event)
            XCTAssertEqual(testServerHangUp, commands.last, "carrier request missing after \(ending.label)")
            XCTAssertTrue(subject.state.serverHangUpRequested, ending.label)
        }
    }

    /// ⛔ LAST IN THE LIST, ALWAYS. The two commands before it are local and
    /// instant — the OS is told, the socket is closed — and this one is a network
    /// round trip that the App tier performs from the same ordered list. Emitting it
    /// first would let an implementation that awaited it hold the system's call UI
    /// open for the length of a timeout on a call the operator has finished with.
    func testTheCarrierRequestIsTheLastCommandAnEndingProduces() {
        var session = SoftphoneSession.inConnected()

        let commands = session.handle(.engine(.failed(message: "lost")))

        XCTAssertEqual([.reportCallEnded, .engine(.disconnect), testServerHangUp], commands)
    }

    /// ⛔ A REFUSED DIAL PLACED NOTHING AT THE CARRIER, so there is nothing to end
    /// and no id to end it with. It still tells the OS, which is a different
    /// question.
    func testARefusedDialAsksTheServerNothing() {
        var session = SoftphoneSession.inDialing()

        let commands = session.handle(.dialRefused)

        XCTAssertEqual([.reportCallEnded], commands)
        XCTAssertFalse(session.state.serverHangUpRequested)
    }

    // MARK: - The terminal phase is still terminal

    /// ⛔ ONE EVENT IS ANSWERED IN `ended` AND THE REST ARE STILL ABSORBED. The
    /// exception exists for the `callId` and for nothing else; widening it would
    /// take back "the disconnect happens exactly once", which is the property the
    /// terminal phase was built for.
    func testTheEndedPhaseAnswersOnlyTheCredentialAndAbsorbsEverythingElse() {
        let ended = SoftphonePhase.ended(.hungUpLocally)
        let events: [SoftphoneEvent] = [
            .dialRequested,
            .dialRefused,
            .hangUpPressed,
            .muteToggled,
            .speakerToggled,
            .tick,
            .engine(.connected),
            .engine(.failed(message: "late")),
            .engine(.disconnected(reason: "late")),
            .engine(.participantJoined(testCallee)),
            .engine(.participantLeft(testCallee)),
            .engine(.reconnecting),
        ]

        // ⚠️ FROM A SESSION THAT NEVER LEARNED AN ID, so the latch is open and any
        // leak would show as a command rather than being masked by it.
        for event in events {
            var subject = SoftphoneSession.inDialing()
            subject.handle(.hangUpPressed)
            XCTAssertEqual([], subject.handle(event), "ended must absorb \(event)")
            XCTAssertEqual(ended, subject.state.phase, "phase after \(event)")
        }
    }

    /// ⚠️ A FRESH SESSION KNOWS NEITHER, which is what makes the two assertions
    /// above about `inDialing()` mean something.
    func testAFreshSessionHasNoIdAndAnOpenLatch() {
        let session = SoftphoneSession(number: testNumber)

        XCTAssertNil(session.state.callId)
        XCTAssertFalse(session.state.serverHangUpRequested)
    }
}
