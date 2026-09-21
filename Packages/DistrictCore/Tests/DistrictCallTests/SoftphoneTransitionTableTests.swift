@testable import DistrictCall
import XCTest

/// One phase, one event, and what it must produce.
///
/// ⚠️ A STRUCT RATHER THAN A TUPLE because SwiftLint caps a tuple at two members
/// and the row is genuinely three facts.
private struct SoftphoneRow {
    let event: SoftphoneEvent
    let phase: SoftphonePhase
    let commands: [SoftphoneCommand]

    init(_ event: SoftphoneEvent, _ phase: SoftphonePhase, _ commands: [SoftphoneCommand] = []) {
        self.event = event
        self.phase = phase
        self.commands = commands
    }
}

/// Every phase against every event, legal and illegal.
///
/// ⛔ THE ILLEGAL ONES ARE THE POINT. A recomposition can fire a handler against
/// a call that has already gone, the OS can deliver an end-call callback twice,
/// and a late engine event can arrive after a hang-up — so "does nothing" has to
/// be asserted rather than assumed. None of this needs a media server, a carrier
/// or a device, which is the whole reason the machine is a reducer.
///
/// ⚠️ EACH ROW RUNS AGAINST A FRESH COPY OF THE PHASE. The session is a value, so
/// a table entry cannot contaminate the next one.
final class SoftphoneTransitionTableTests: XCTestCase {
    private func assertTable(_ session: SoftphoneSession, _ rows: [SoftphoneRow]) {
        for row in rows {
            var subject = session
            let produced = subject.handle(row.event)
            XCTAssertEqual(row.phase, subject.state.phase, "phase after \(row.event)")
            XCTAssertEqual(row.commands, produced, "commands after \(row.event)")
        }
    }

    /// The engine events that only fold into the media state.
    private static let inertEngineEvents: [SoftphoneEvent] = [
        .engine(.reconnecting),
        .engine(.audioRouteChanged(.speaker)),
        .engine(.microphoneChanged(enabled: false)),
    ]

    private static let credential = SoftphoneEvent.dialAccepted(
        url: testDialURL,
        token: testDialToken,
        callId: testDialCallId
    )

    /// The exit for an ending the OS PERFORMED ITSELF.
    ///
    /// ⛔ NO ``SoftphoneCommand/reportCallEnded``, AND THAT IS THE ASSERTION. Both
    /// producers of ``SoftphoneEvent/hangUpPressed`` put a `CXEndCallAction`
    /// through CallKit first, so reporting would tell the system about an ending
    /// it carried out.
    private static let systemKnows: [SoftphoneCommand] = [.engine(.disconnect)]

    /// The exit for an ending only the media layer or the dial route saw.
    ///
    /// ⛔ THE REPORT IS THE ONLY THING THAT ENDS THE SYSTEM'S CALL HERE, and its
    /// absence is what left CallKit believing every finished outbound call was
    /// still live — which with `maximumCallGroups = 1` refuses every later call in
    /// both directions.
    private static let systemMustBeTold: [SoftphoneCommand] = [.reportCallEnded, .engine(.disconnect)]

    /// The same two exits once the `callId` is known, i.e. from ``connecting`` on.
    ///
    /// ⛔ THE CARRIER REQUEST IS ON **BOTH**, WHICH IS THE ONE PLACE THIS TABLE'S
    /// TWO EXITS STOP DIVERGING. The report is split on whether CallKit performed
    /// the ending itself; the SERVER performed none of them, so it is told every
    /// time. An exit that carried the report and not this is exactly the shape of
    /// the billing defect.
    ///
    /// ⛔ AND IT IS LAST. The two commands before it are local and instant; this one
    /// is a network round trip, and the App tier performs the list IN ORDER.
    private static let systemKnowsWithLeg: [SoftphoneCommand] = systemKnows + [testServerHangUp]

    private static let systemMustBeToldWithLeg: [SoftphoneCommand] = systemMustBeTold + [testServerHangUp]

    func testIdleAnswersOnlyToADialRequest() {
        var rows: [SoftphoneRow] = [
            SoftphoneRow(.dialRequested, .dialing),
            SoftphoneRow(.dialRefused, .idle),
            SoftphoneRow(Self.credential, .idle),
            SoftphoneRow(.engine(.connected), .idle),
            SoftphoneRow(.engine(.failed(message: "x")), .idle),
            SoftphoneRow(.engine(.disconnected(reason: "x")), .idle),
            SoftphoneRow(.engine(.participantJoined(testCallee)), .idle),
            SoftphoneRow(.engine(.participantLeft(testCallee)), .idle),
            // ⚠️ NOT AN ENDED CALL. There is no call: a hang-up on an idle keypad
            // has nothing to disconnect, and an `ended` phase here would draw a
            // summary for a call that never happened.
            SoftphoneRow(.hangUpPressed, .idle),
            SoftphoneRow(.muteToggled, .idle),
            SoftphoneRow(.speakerToggled, .idle),
            SoftphoneRow(.tick, .idle),
        ]
        rows += Self.inertEngineEvents.map { SoftphoneRow($0, .idle) }
        assertTable(SoftphoneSession(number: testNumber), rows)
    }

    func testDialingTakesTheCredentialTheRefusalOrAHangUp() {
        var rows: [SoftphoneRow] = [
            SoftphoneRow(.dialRequested, .dialing),
            // ⛔ Back to the keypad: no call was placed at the CARRIER. CallKit is
            // a different question and the answer is the other way round — a
            // `CXStartCallAction` has already been performed, so the system is
            // holding a call that nothing else will ever end.
            SoftphoneRow(.dialRefused, .idle, [.reportCallEnded]),
            SoftphoneRow(Self.credential, .connecting, [.engine(.connect(url: testDialURL, token: testDialToken))]),
            SoftphoneRow(.engine(.connected), .dialing),
            SoftphoneRow(.engine(.failed(message: "x")), .dialing),
            SoftphoneRow(.engine(.disconnected(reason: "x")), .dialing),
            SoftphoneRow(.engine(.participantJoined(testCallee)), .dialing),
            SoftphoneRow(.engine(.participantLeft(testCallee)), .dialing),
            SoftphoneRow(.hangUpPressed, .ended(.hungUpLocally), Self.systemKnows),
            SoftphoneRow(.muteToggled, .dialing),
            SoftphoneRow(.speakerToggled, .dialing),
            SoftphoneRow(.tick, .dialing),
        ]
        rows += Self.inertEngineEvents.map { SoftphoneRow($0, .dialing) }
        assertTable(.inDialing(), rows)
    }

    func testConnectingEndsOnAFailureAndUnmutesOnTheJoin() {
        var rows: [SoftphoneRow] = [
            SoftphoneRow(.dialRequested, .connecting),
            SoftphoneRow(.dialRefused, .connecting),
            SoftphoneRow(Self.credential, .connecting),
            SoftphoneRow(.engine(.connected), .ringing, [.engine(.setMuted(false))]),
            SoftphoneRow(
                .engine(.failed(message: "no route")),
                .ended(.failed(message: "no route")),
                Self.systemMustBeToldWithLeg
            ),
            SoftphoneRow(
                .engine(.disconnected(reason: "busy")),
                .ended(.remoteEnded(reason: "busy")),
                Self.systemMustBeToldWithLeg
            ),
            SoftphoneRow(.engine(.participantJoined(testCallee)), .connecting),
            SoftphoneRow(.engine(.participantLeft(testCallee)), .connecting),
            SoftphoneRow(.hangUpPressed, .ended(.hungUpLocally), Self.systemKnowsWithLeg),
            SoftphoneRow(.muteToggled, .connecting, [.engine(.setMuted(true))]),
            SoftphoneRow(.speakerToggled, .connecting, [.engine(.setSpeakerphone(true))]),
            SoftphoneRow(.tick, .connecting),
        ]
        rows += Self.inertEngineEvents.map { SoftphoneRow($0, .connecting) }
        assertTable(.inConnecting(), rows)
    }

    func testRingingAnswersOnAParticipantAndOnNothingElse() {
        var rows: [SoftphoneRow] = [
            SoftphoneRow(.dialRequested, .ringing),
            SoftphoneRow(.dialRefused, .ringing),
            SoftphoneRow(Self.credential, .ringing),
            // ⚠️ A second `.connected` is a RECOVERY, not a second join: it must
            // not re-issue the unmute.
            SoftphoneRow(.engine(.connected), .ringing),
            SoftphoneRow(
                .engine(.failed(message: "lost")),
                .ended(.failed(message: "lost")),
                Self.systemMustBeToldWithLeg
            ),
            // ⚠️ Before the answer this is the callee declining or the dial
            // failing at the carrier. The zero duration says which.
            SoftphoneRow(
                .engine(.disconnected(reason: nil)),
                .ended(.remoteEnded(reason: nil)),
                Self.systemMustBeToldWithLeg
            ),
            SoftphoneRow(.engine(.participantJoined(testCallee)), .connected),
            SoftphoneRow(.engine(.participantLeft(testCallee)), .ringing),
            SoftphoneRow(.hangUpPressed, .ended(.hungUpLocally), Self.systemKnowsWithLeg),
            SoftphoneRow(.muteToggled, .ringing, [.engine(.setMuted(true))]),
            SoftphoneRow(.speakerToggled, .ringing, [.engine(.setSpeakerphone(true))]),
            // ⛔ NO TIMER HERE. See CallMediaState.elapsedSeconds.
            SoftphoneRow(.tick, .ringing),
        ]
        rows += Self.inertEngineEvents.map { SoftphoneRow($0, .ringing) }
        assertTable(.inRinging(), rows)
    }

    func testConnectedCountsTimeAndEndsWhenTheRoomEmpties() {
        let second = CallParticipant(identity: "user-2")
        var rows: [SoftphoneRow] = [
            SoftphoneRow(.dialRequested, .connected),
            SoftphoneRow(.dialRefused, .connected),
            SoftphoneRow(Self.credential, .connected),
            SoftphoneRow(.engine(.connected), .connected),
            SoftphoneRow(
                .engine(.failed(message: "lost")),
                .ended(.failed(message: "lost")),
                Self.systemMustBeToldWithLeg
            ),
            SoftphoneRow(
                .engine(.disconnected(reason: "hangup")),
                .ended(.remoteEnded(reason: "hangup")),
                Self.systemMustBeToldWithLeg
            ),
            SoftphoneRow(.engine(.participantJoined(second)), .connected),
            SoftphoneRow(.engine(.participantLeft(testCallee)), .ended(.remoteHungUp), Self.systemMustBeToldWithLeg),
            SoftphoneRow(.hangUpPressed, .ended(.hungUpLocally), Self.systemKnowsWithLeg),
            SoftphoneRow(.muteToggled, .connected, [.engine(.setMuted(true))]),
            SoftphoneRow(.speakerToggled, .connected, [.engine(.setSpeakerphone(true))]),
            SoftphoneRow(.tick, .connected),
        ]
        rows += Self.inertEngineEvents.map { SoftphoneRow($0, .connected) }
        assertTable(.inConnected(), rows)
    }

    func testEndedAbsorbsEverythingAndCostsNoSecondDisconnect() {
        // ⛔ THIS IS WHAT MAKES "HANG UP DISCONNECTS EXACTLY ONCE" TRUE. Three
        // paths reach the exit on an ordinary call and the OS can deliver its own
        // end twice; a second disconnect would race the first one's teardown.
        let ended = SoftphonePhase.ended(.hungUpLocally)
        var rows: [SoftphoneRow] = [
            SoftphoneRow(.dialRequested, ended),
            SoftphoneRow(.dialRefused, ended),
            SoftphoneRow(Self.credential, ended),
            SoftphoneRow(.engine(.connected), ended),
            SoftphoneRow(.engine(.failed(message: "late")), ended),
            SoftphoneRow(.engine(.disconnected(reason: "late")), ended),
            SoftphoneRow(.engine(.participantJoined(testCallee)), ended),
            SoftphoneRow(.engine(.participantLeft(testCallee)), ended),
            SoftphoneRow(.hangUpPressed, ended),
            SoftphoneRow(.muteToggled, ended),
            SoftphoneRow(.speakerToggled, ended),
            SoftphoneRow(.tick, ended),
        ]
        rows += Self.inertEngineEvents.map { SoftphoneRow($0, ended) }
        assertTable(.inEnded(), rows)
    }
}
